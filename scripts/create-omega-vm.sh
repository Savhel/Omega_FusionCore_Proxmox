#!/usr/bin/env bash
# Cree une VM Proxmox conforme aux tests omega-remote-paging.
#
# Exemple:
#   ./scripts/create-omega-vm.sh \
#     --vmids 9001,9002,9003 \
#     --storage ceph-vms \
#     --bridge vmbr0 \
#     --image /var/lib/vz/template/iso/debian-12-generic-amd64.qcow2 \
#     --sshkey /root/.ssh/id_rsa.pub \
#     --start

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/create-omega-vm.sh --vmid 9001 --storage ceph-vms --bridge vmbr0 --image IMAGE.qcow2 [options]
  scripts/create-omega-vm.sh --vmids 9001,9002,9003 --storage ceph-vms --bridge vmbr0 --image IMAGE.qcow2 [options]

Options:
  --vmid ID             VMID unique.
  --vmids A,B,C         Liste de VMIDs a creer.
  --name PREFIX         Prefixe de nom. Defaut: omega-test.
  --storage NAME        Stockage Proxmox cible, idealement Ceph RBD.
  --bridge NAME         Bridge reseau Proxmox. Defaut: vmbr0.
  --image PATH          Image cloud qcow2 a importer.
  --template-id ID      Template Proxmox a cloner au lieu d'importer l'image.
  --linked-clone        Clone lie depuis le template (rapide sur Ceph/RBD).
  --adopt-existing      Configure une VM existante au lieu de la creer.
  --sshkey PATH         Cle publique injectee par cloud-init.
  --ciuser USER         Utilisateur cloud-init. Defaut: root.
  --memory MIB          RAM max demandee par la VM. Defaut: 3072.
  --balloon MIB         RAM locale initiale/minimale. Defaut: 512.
  --cores N             Cores QEMU. Avec sockets, definit le max vCPU hotpluggable. Defaut: 4.
  --vcpus N             vCPU au boot. Defaut: 1.
  --sockets N           Sockets QEMU. max_vcpus = cores * sockets. Defaut: 1.
  --disk-max-gib N      Budget disque logique documente. Defaut: 20.
  --gpu-vram-mib N      Budget VRAM documente. Defaut: 0.
  --cpu TYPE            Type CPU QEMU. Defaut: x86-64-v2-AES (baseline v2, migrable).
  --ipconfig0 VALUE     Config IP cloud-init. Defaut: ip=dhcp.
  --nameserver VALUE    DNS cloud-init. Defaut: 8.8.8.8.
  --vlan-tag N          Tag VLAN 802.1q sur net0 (1-4094). Vide = pas de tag.
  --root-password PASS  Mot de passe root cloud-init. Defaut: root.
  --bootstrap-guest     Installe qemu-guest-agent + stress-ng + SSH via cloud-init.
  --template-prepared   Le template contient deja qemu-guest-agent + stress-ng + SSH.
  --snippet-storage S   Storage snippets Proxmox pour bootstrap. Defaut: local.
  --start               Demarre la VM apres creation.
  -h, --help            Affiche cette aide.

La VM creee est conforme au projet:
  - boot avec --vcpus <min> et --cores/--sockets <max>, donc showcmd expose maxcpus
  - hotplug CPU/disk/network actif
  - RAM elastique via balloon + backend Omega, pas via memory hotplug Proxmox
  - qemu-guest-agent active
  - disque virtio-scsi avec iothread/discard
  - net0 virtio sur bridge Proxmox
  - description contenant les quotas Omega lus par le controller
EOF
}

fail() {
    echo "ERREUR: $*" >&2
    exit 1
}

cfg_value() {
    local cfg="$1" key="$2"
    awk -F': ' -v k="$key" '$1 == k {print $2; exit}' <<< "$cfg"
}

require_cfg_value() {
    local cfg="$1" key="$2" expected="$3" vmid="$4"
    local actual
    actual="$(cfg_value "$cfg" "$key")"
    [[ "$actual" == "$expected" ]] || fail "VM $vmid non conforme: $key='$actual', attendu '$expected'"
}

qm_set_retry() {
    local vmid="$1"; shift
    local attempt max_attempts delay out rc
    max_attempts="${OMEGA_QM_SET_RETRY_MAX:-8}"
    delay="${OMEGA_QM_SET_RETRY_DELAY_SECS:-10}"

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        out="$(qm set "$vmid" "$@" 2>&1)" && {
            [[ -n "$out" ]] && printf '%s\n' "$out"
            return 0
        }
        rc=$?
        printf '%s\n' "$out" >&2
        if [[ "$out" == *locked* || "$out" == *"command timed out"* || "$out" == *"File exists"* || "$out" == *"rbd create"* ]]; then
            echo "WARN: qm set VM $vmid échoué (tentative ${attempt}/${max_attempts}) — attente ${delay}s puis retry" >&2
            qm set "$vmid" --delete scsi1 >/dev/null 2>&1 || true
            pvesm free "${STORAGE}:vm-${vmid}-cloudinit" >/dev/null 2>&1 || true
            sleep "$delay"
            continue
        fi
        return "$rc"
    done
    fail "qm set VM $vmid impossible après ${max_attempts} tentatives"
}

cleanup_cloudinit_disk() {
    local vmid="$1"
    qm set "$vmid" --delete scsi1 >/dev/null 2>&1 || true
    pvesm free "${STORAGE}:vm-${vmid}-cloudinit" >/dev/null 2>&1 || true
}

prepare_template_for_clone() {
    [[ -n "$TEMPLATE_ID" ]] || return 0
    # Le cloud-init de la template ne doit pas être cloné. Chaque VM Omega
    # recrée ensuite son propre disque cloud-init.
    cleanup_cloudinit_disk "$TEMPLATE_ID"
}

verify_vm_profile() {
    local vmid="$1"
    local cfg smp hotplug agent net0 scsihw description status cfg_cores cfg_sockets

    cfg="$(qm config "$vmid" 2>/dev/null)" || fail "impossible de relire la config de la VM $vmid"
    status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)"
    cfg_cores="$(cfg_value "$cfg" cores)"
    cfg_sockets="$(cfg_value "$cfg" sockets)"
    require_cfg_value "$cfg" vcpus "$VCPUS" "$vmid"
    require_cfg_value "$cfg" memory "$MEMORY" "$vmid"
    require_cfg_value "$cfg" balloon "$BALLOON" "$vmid"

    hotplug="$(cfg_value "$cfg" hotplug)"
    if [[ "$status" == "running" && ! ( "$hotplug" == *cpu* && "$hotplug" == *disk* && "$hotplug" == *network* ) ]]; then
        echo "WARN: VM $vmid running: hotplug expose '${hotplug}', réapplication cpu,disk,network"
        qm set "$vmid" --hotplug cpu,disk,network >/dev/null
        cfg="$(qm config "$vmid" 2>/dev/null)" || fail "impossible de relire la config de la VM $vmid"
        hotplug="$(cfg_value "$cfg" hotplug)"
    fi
    [[ "$hotplug" == *cpu* && "$hotplug" == *disk* && "$hotplug" == *network* ]] || fail "VM $vmid non conforme: hotplug='$hotplug', attendu cpu,disk,network"
    [[ "$hotplug" != *memory* ]] || fail "VM $vmid non conforme: hotplug memory interdit pour Omega"
    [[ "$(cfg_value "$cfg" numa)" != "1" ]] || fail "VM $vmid non conforme: numa=1 incompatible avec le backend mémoire Omega"

    agent="$(cfg_value "$cfg" agent)"
    [[ "$agent" == *enabled=1* || "$agent" == "1" ]] || fail "VM $vmid non conforme: qemu-guest-agent non active"

    net0="$(cfg_value "$cfg" net0)"
    [[ "$net0" == virtio=* && "$net0" == *"bridge=${BRIDGE}"* ]] || fail "VM $vmid non conforme: net0='$net0', attendu virtio sur ${BRIDGE}"
    if [[ -n "$VLAN_TAG" ]]; then
        [[ "$net0" == *"tag=${VLAN_TAG}"* ]] || fail "VM $vmid non conforme: net0='$net0', attendu tag=${VLAN_TAG}"
    fi

    scsihw="$(cfg_value "$cfg" scsihw)"
    [[ "$scsihw" == virtio-scsi* ]] || fail "VM $vmid non conforme: scsihw='$scsihw', attendu virtio-scsi-*"

    description="$(cfg_value "$cfg" description)"
    [[ "$description" == *"omega_min_vcpus=${VCPUS}"* ]] || fail "VM $vmid non conforme: description sans omega_min_vcpus=${VCPUS}"
    [[ "$description" == *"omega_max_vcpus=${MAX_VCPUS}"* ]] || fail "VM $vmid non conforme: description sans omega_max_vcpus=${MAX_VCPUS}"
    [[ "$description" == *"omega_memory_min_mib=${BALLOON}"* ]] || fail "VM $vmid non conforme: description sans omega_memory_min_mib=${BALLOON}"
    [[ "$description" == *"omega_memory_max_mib=${MEMORY}"* ]] || fail "VM $vmid non conforme: description sans omega_memory_max_mib=${MEMORY}"
    [[ "$description" == *"omega_disk_max_gib=${DISK_MAX_GIB}"* ]] || fail "VM $vmid non conforme: description sans omega_disk_max_gib=${DISK_MAX_GIB}"
    [[ "$description" == *"omega_gpu_vram_mib=${GPU_VRAM_MIB}"* ]] || fail "VM $vmid non conforme: description sans omega_gpu_vram_mib=${GPU_VRAM_MIB}"

    smp="$(qm showcmd "$vmid" --pretty 2>/dev/null | grep -- '-smp' || true)"
    [[ -n "$smp" ]] || fail "VM $vmid non conforme: qm showcmd ne retourne pas -smp"
    echo "$smp"
    [[ "$smp" == *"maxcpus=${MAX_VCPUS}"* ]] || fail "VM $vmid non conforme: -smp ne contient pas maxcpus=${MAX_VCPUS}"
    [[ "$smp" == *"-smp '${VCPUS},"* || "$smp" == *"-smp ${VCPUS},"* ]] || fail "VM $vmid non conforme: -smp ne demarre pas a ${VCPUS} vCPU"
    if [[ "$status" == "running" ]]; then
        if [[ "$cfg_cores" != "$CORES" || "$cfg_sockets" != "$SOCKETS" ]]; then
            echo "WARN: VM $vmid running: qm config expose cores=${cfg_cores}/sockets=${cfg_sockets}, mais showcmd confirme maxcpus=${MAX_VCPUS}"
        fi
    else
        [[ "$cfg_cores" == "$CORES" ]] || fail "VM $vmid non conforme: cores='${cfg_cores}', attendu '${CORES}'"
        [[ "$cfg_sockets" == "$SOCKETS" ]] || fail "VM $vmid non conforme: sockets='${cfg_sockets}', attendu '${SOCKETS}'"
    fi

    echo "Profil Omega VM $vmid valide: vcpus=${VCPUS}, maxcpus=${MAX_VCPUS}, memory=${MEMORY}, balloon=${BALLOON}, hotplug=cpu,disk,network"
}

VMIDS=""
NAME_PREFIX="omega-test"
STORAGE=""
BRIDGE="vmbr0"
IMAGE=""
TEMPLATE_ID=""
LINKED_CLONE=false
ADOPT_EXISTING=false
SSHKEY=""
CIUSER="root"
MEMORY=3072
BALLOON=512
CORES=4
VCPUS=1
SOCKETS=1
DISK_MAX_GIB=20
GPU_VRAM_MIB=0
CPU_TYPE="${OMEGA_VM_CPU_TYPE:-x86-64-v2-AES}"  # baseline x86-64-v2 (kafka, binaires modernes) ; modèle fixe → migrable. kvm64 (ancien défaut) n'expose pas v2.
IPCONFIG0="ip=dhcp"
NAMESERVER="8.8.8.8"
ROOT_PASSWORD="root"
VLAN_TAG=""
BOOTSTRAP_GUEST=false
TEMPLATE_PREPARED=false
SNIPPET_STORAGE="local"
START=false
OSTYPE="l26"
MACHINE="q35"
TAGS="omega,omega-test"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid) VMIDS="$2"; shift 2 ;;
        --vmids) VMIDS="$2"; shift 2 ;;
        --name) NAME_PREFIX="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --template-id) TEMPLATE_ID="$2"; shift 2 ;;
        --linked-clone) LINKED_CLONE=true; shift ;;
        --adopt-existing) ADOPT_EXISTING=true; shift ;;
        --sshkey) SSHKEY="$2"; shift 2 ;;
        --ciuser) CIUSER="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --balloon) BALLOON="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --vcpus) VCPUS="$2"; shift 2 ;;
        --sockets) SOCKETS="$2"; shift 2 ;;
        --disk-max-gib) DISK_MAX_GIB="$2"; shift 2 ;;
        --gpu-vram-mib) GPU_VRAM_MIB="$2"; shift 2 ;;
        --cpu) CPU_TYPE="$2"; shift 2 ;;
        --ipconfig0) IPCONFIG0="$2"; shift 2 ;;
        --nameserver) NAMESERVER="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --vlan-tag) VLAN_TAG="$2"; shift 2 ;;
        --bootstrap-guest) BOOTSTRAP_GUEST=true; shift ;;
        --template-prepared) TEMPLATE_PREPARED=true; shift ;;
        --snippet-storage) SNIPPET_STORAGE="$2"; shift 2 ;;
        --start) START=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

command -v qm >/dev/null 2>&1 || fail "qm introuvable: lancer ce script sur un noeud Proxmox"
[[ -n "$VMIDS" ]] || fail "--vmid ou --vmids requis"
[[ -n "$STORAGE" ]] || fail "--storage requis"
if [[ -n "$TEMPLATE_ID" ]]; then
    [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]] || fail "--template-id doit etre numerique"
    if ! $ADOPT_EXISTING; then
        qm status "$TEMPLATE_ID" >/dev/null 2>&1 || fail "template VM introuvable: $TEMPLATE_ID"
    fi
else
    [[ -n "$IMAGE" ]] || fail "--image requis sans --template-id"
    [[ -f "$IMAGE" ]] || fail "image introuvable: $IMAGE"
fi
[[ "$VCPUS" =~ ^[0-9]+$ && "$CORES" =~ ^[0-9]+$ && "$SOCKETS" =~ ^[0-9]+$ ]] || fail "vcpus/cores/sockets doivent etre numeriques"
[[ "$MEMORY" =~ ^[0-9]+$ && "$BALLOON" =~ ^[0-9]+$ ]] || fail "memory/balloon doivent etre numeriques"
[[ "$DISK_MAX_GIB" =~ ^[0-9]+$ && "$GPU_VRAM_MIB" =~ ^[0-9]+$ ]] || fail "disk-max-gib/gpu-vram-mib doivent etre numeriques"
[[ "$VCPUS" -ge 1 ]] || fail "--vcpus doit etre >= 1"
[[ "$BALLOON" -gt 0 ]] || fail "--balloon doit etre > 0 pour la RAM initiale/minimale Omega"
[[ "$MEMORY" -gt "$BALLOON" ]] || fail "--memory doit etre strictement superieur a --balloon pour tester le thin-provisioning RAM"

MAX_VCPUS=$((CORES * SOCKETS))
[[ "$MAX_VCPUS" -ge 2 ]] || fail "--cores x --sockets doit etre >= 2 pour tester le vCPU elastique"
# firewall=0 par défaut : l'isolation des VMs omega est assurée par les FLOWS OVS
# (vm-isolation.sh : drop intra-subnet, gateway-only) + pfSense, pas par le firewall
# Proxmox par-VM. firewall=1 s'est révélé CASSER l'egress (pont fwbr défaillant →
# la VM ne joint même pas sa gateway) de façon flaky sur ce cluster. Override possible
# via OMEGA_VM_NET_FIREWALL=1 si on veut réactiver le firewall Proxmox par-VM.
NET_FW="${OMEGA_VM_NET_FIREWALL:-0}"
if [[ -n "$VLAN_TAG" ]]; then
    [[ "$VLAN_TAG" =~ ^[0-9]+$ && "$VLAN_TAG" -ge 1 && "$VLAN_TAG" -le 4094 ]] || fail "--vlan-tag doit etre un entier entre 1 et 4094"
    NET0="virtio,bridge=${BRIDGE},firewall=${NET_FW},tag=${VLAN_TAG}"
else
    NET0="virtio,bridge=${BRIDGE},firewall=${NET_FW}"
fi
[[ "$VCPUS" -lt "$MAX_VCPUS" ]] || fail "--vcpus doit etre strictement inferieur a --cores x --sockets (${MAX_VCPUS}) pour permettre le scale-up"
HOST_MAX_VCPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)"
if [[ "$HOST_MAX_VCPUS" =~ ^[0-9]+$ && "$HOST_MAX_VCPUS" -gt 0 && "$MAX_VCPUS" -gt "$HOST_MAX_VCPUS" ]]; then
    fail "--cores x --sockets = ${MAX_VCPUS}, mais ce noeud Proxmox n'autorise que ${HOST_MAX_VCPUS} vCPU par VM. Reduire --cores ou choisir un noeud plus grand."
fi

IFS=',' read -ra VMID_ARR <<< "$VMIDS"

for vmid in "${VMID_ARR[@]}"; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID invalide: $vmid"
    if qm status "$vmid" >/dev/null 2>&1; then
        $ADOPT_EXISTING || fail "VM $vmid existe deja; supprimer ou choisir un autre VMID"
        echo "Adoption VM existante $vmid"
    fi

    name="${NAME_PREFIX}-${vmid}"
    desc="omega_min_vcpus=${VCPUS} omega_max_vcpus=${MAX_VCPUS} omega_memory_min_mib=${BALLOON} omega_memory_max_mib=${MEMORY} omega_disk_max_gib=${DISK_MAX_GIB} omega_gpu_vram_mib=${GPU_VRAM_MIB}"

    if $ADOPT_EXISTING; then
        :
    elif [[ -n "$TEMPLATE_ID" ]]; then
        echo "Clone VM $vmid ($name) depuis template $TEMPLATE_ID"
        prepare_template_for_clone
        cleanup_cloudinit_disk "$vmid"
        if $LINKED_CLONE; then
            # Proxmox refuse --storage pour les clones lies: ils restent sur le
            # meme stockage backing que la template.
            qm clone "$TEMPLATE_ID" "$vmid" --name "$name" --full 0
        else
            qm clone "$TEMPLATE_ID" "$vmid" --name "$name" --storage "$STORAGE" --full 1
        fi
    else
        echo "Creation VM $vmid ($name)"
        qm create "$vmid" \
            --name "$name" \
            --ostype "$OSTYPE" \
            --machine "$MACHINE" \
            --agent enabled=1 \
            --cpu "$CPU_TYPE" \
            --sockets "$SOCKETS" \
            --cores "$CORES" \
            --vcpus "$VCPUS" \
            --memory "$MEMORY" \
            --balloon "$BALLOON" \
            --hotplug cpu,disk,network \
            --numa 0 \
            --scsihw virtio-scsi-single \
            --net0 "${NET0}" \
            --serial0 socket \
            --vga serial0 \
            --tags "$TAGS" \
            --description "$desc"

        qm importdisk "$vmid" "$IMAGE" "$STORAGE"
        qm set "$vmid" \
            --scsi0 "${STORAGE}:vm-${vmid}-disk-0,discard=on,iothread=1,ssd=1"
    fi

    # Une tentative interrompue ou un clone de template peut laisser un disque
    # cloud-init vm-${vmid}-cloudinit. Proxmox refuse ensuite de le recreer.
    cleanup_cloudinit_disk "$vmid"

    qm_set_retry "$vmid" \
        --name "$name" \
        --ostype "$OSTYPE" \
        --machine "$MACHINE" \
        --agent enabled=1 \
        --cpu "$CPU_TYPE" \
        --sockets "$SOCKETS" \
        --cores "$CORES" \
        --vcpus "$VCPUS" \
        --memory "$MEMORY" \
        --balloon "$BALLOON" \
        --hotplug cpu,disk,network \
            --numa 0 \
        --scsihw virtio-scsi-single \
        --net0 "${NET0}" \
        --serial0 socket \
        --vga serial0 \
        --tags "$TAGS" \
        --description "$desc" \
        --boot order=scsi0 \
        --scsi1 "${STORAGE}:cloudinit" \
        --ipconfig0 "$IPCONFIG0" \
        --nameserver "$NAMESERVER" \
        --ciuser "$CIUSER" \
        --cipassword "$ROOT_PASSWORD"

    # Le clone/template fournit un disque a la taille de base (~3-4 Gio). On l'agrandit
    # a la taille demandee (DISK_MAX_GIB) AVANT le boot : cloud-init (growpart +
    # resize_rootfs ci-dessous) etend alors le FS racine sur tout le disque au premier
    # demarrage. qm resize n'accepte QUE l'agrandissement -> si deja >= cible, ignore.
    if [[ "${DISK_MAX_GIB:-0}" -gt 0 ]]; then
        if qm resize "$vmid" scsi0 "${DISK_MAX_GIB}G" >/dev/null 2>&1; then
            echo "Disque scsi0 redimensionne a ${DISK_MAX_GIB} Gio"
        else
            echo "  (resize disque ignore: deja >= ${DISK_MAX_GIB} Gio ou non applicable)"
        fi
    fi

    if [[ -n "$SSHKEY" ]]; then
        [[ -f "$SSHKEY" ]] || fail "cle SSH introuvable: $SSHKEY"
        qm set "$vmid" --sshkeys "$SSHKEY"
    fi

    if $BOOTSTRAP_GUEST; then
        snippet_dir="/var/lib/vz/snippets"
        snippet_name="omega-bootstrap-${vmid}.yaml"
        snippet_path="${snippet_dir}/${snippet_name}"
        mkdir -p "$snippet_dir"
        ssh_keys_yaml=""
        package_yaml=""
        if [[ -n "$SSHKEY" && -f "$SSHKEY" ]]; then
            ssh_keys_yaml="ssh_authorized_keys:
  - $(cat "$SSHKEY")"
        fi
        if ! $TEMPLATE_PREPARED; then
            package_yaml="package_update: true
packages:
  - qemu-guest-agent
  - stress-ng
  - openssh-server"
        fi
        cat > "$snippet_path" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
fqdn: ${name}
user: ${CIUSER}
disable_root: false
ssh_pwauth: true
password: ${ROOT_PASSWORD}
chpasswd:
  expire: false
package_update: false
package_upgrade: false
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
${ssh_keys_yaml}
${package_yaml}
write_files:
  - path: /usr/local/sbin/omega-qga-ensure
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/sh
      LOG=/var/log/omega-qga-ensure.log
      {
      echo "=== omega-qga-ensure \$(date) ==="
      if ! command -v qemu-ga >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update 2>/dev/null && apt-get install -y qemu-guest-agent 2>/dev/null || true
      fi
      systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
      systemctl enable qemu-guest-agent.service 2>/dev/null || true
      systemctl enable qemu-guest-agent.socket 2>/dev/null || true
      i=0
      while [ "\$i" -lt 20 ]; do
          if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
              systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
              systemctl start qemu-guest-agent.socket 2>/dev/null || true
              break
          fi
          i=\$((i+1))
          sleep 2
      done
      systemctl is-active qemu-guest-agent 2>/dev/null && echo "qemu-guest-agent ACTIF" || echo "qemu-guest-agent INACTIF"
      } >>"\$LOG" 2>&1
  - path: /etc/systemd/system/omega-qga-ensure.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Omega - garantit qemu-guest-agent actif a chaque boot
      After=sysinit.target
      Before=multi-user.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/omega-qga-ensure
      RemainAfterExit=yes
      TimeoutStartSec=60

      [Install]
      WantedBy=multi-user.target
  - path: /etc/cloud/cloud.cfg.d/99-omega-network-persist.cfg
    owner: root:root
    permissions: '0644'
    content: |
      # Empêche cloud-init de réécrire la config réseau aux boots suivants.
      # L'IP statique injectée au premier boot est conservée par netplan.
      network:
        config: disabled
bootcmd:
  - [ bash, -lc, "if [ ! -e /var/lib/omega-firstboot-machine-id.done ]; then rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup || true; touch /var/lib/omega-firstboot-machine-id.done; fi" ]
runcmd:
  - [ bash, -lc, "rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* 2>/dev/null || true" ]
  - [ bash, -lc, "test -s /etc/machine-id || systemd-machine-id-setup || true" ]
  - [ bash, -lc, "rm -f /var/lib/dbus/machine-id; ln -sf /etc/machine-id /var/lib/dbus/machine-id || true" ]
  - [ bash, -lc, "echo '${CIUSER}:${ROOT_PASSWORD}' | chpasswd" ]
  - [ bash, -lc, "export DEBIAN_FRONTEND=noninteractive; command -v qemu-ga >/dev/null 2>&1 && command -v stress-ng >/dev/null 2>&1 && test -x /usr/sbin/sshd || (apt-get update && apt-get install -y qemu-guest-agent stress-ng openssh-server)" ]
  - [ bash, -lc, "install -d -m 0755 /etc/ssh/sshd_config.d; printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' >/etc/ssh/sshd_config.d/00-omega-root-login.conf; systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true" ]
  - [ bash, -lc, "systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true; systemctl enable --now qemu-guest-agent.socket 2>/dev/null || true; systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true" ]
  - [ bash, -lc, "systemctl daemon-reload; systemctl enable --now omega-qga-ensure.service 2>/dev/null || true" ]
  - [ bash, -lc, "netplan apply 2>/dev/null || true; systemctl restart systemd-networkd 2>/dev/null || true" ]
EOF
        qm set "$vmid" --cicustom "user=${SNIPPET_STORAGE}:snippets/${snippet_name}"
    fi

    # Fichier firewall Proxmox par VM : isolation par défaut + accès admin
    FW_FILE="/etc/pve/firewall/${vmid}.fw"
    ADMIN_NET="${OMEGA_ADMIN_NET:-192.168.123.0/24}"
    OMEGA_GW="${OMEGA_NET_VM_GATEWAY:-10.50.30.1}"
    INFRA_NET="${OMEGA_NET_ZONE_INFRA_NET:-10.50.20.0/24}"
    cat > "$FW_FILE" <<FWEOF
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source ${ADMIN_NET} -log nolog
IN ACCEPT -source ${OMEGA_GW} -log nolog
IN ACCEPT -source ${INFRA_NET} -log nolog
FWEOF

    echo "Verification profil Omega VM $vmid"
    verify_vm_profile "$vmid"

    if $START; then
        # Le provisioning démarre les VMs hors hook Omega. Le hookscript peut
        # être réattaché plus tard par l'installation Omega une fois la VM saine.
        qm set "$vmid" --delete hookscript >/dev/null 2>&1 || true
        if ! qm start "$vmid"; then
            status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)"
            if [[ "$status" == "running" ]]; then
                echo "WARN: qm start $vmid a retourné une erreur, mais la VM est running; poursuite des vérifications"
            else
                fail "qm start $vmid a échoué et la VM n'est pas running"
            fi
        fi
        # Certains chemins clone+target Proxmox exposent temporairement
        # hotplug=cpu après le premier start; on réapplique le profil Omega.
        qm set "$vmid" --hotplug cpu,disk,network >/dev/null
        echo "Verification profil Omega VM $vmid apres demarrage"
        verify_vm_profile "$vmid"
        echo "VM $vmid demarree"
    fi
done
