#!/usr/bin/env bash
# Cree une VM Proxmox conforme aux tests omega-remote-paging.
# Version avec génération de certificats mTLS et installation des proxys GANDAL.
#
# Exemple:
#   ./create-omega-vm-proxy.sh \
#     --vmids 2004 \
#     --storage local-lvm \
#     --bridge vmbr1 \
#     --image /root/debian-12-genericcloud-amd64.qcow2 \
#     --ca-dir /etc/gandal/ca \
#     --ipconfig0 "ip=10.50.30.15/24,gw=10.50.30.1" \
#     --sshkey ~/.ssh/id_rsa.pub \
#     --bootstrap-guest \
#     --start

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  create-omega-vm-proxy.sh --vmid 9001 --storage ceph-vms --bridge vmbr0 --image IMAGE.qcow2 [options]
  create-omega-vm-proxy.sh --vmids 9001,9002,9003 --storage ceph-vms --bridge vmbr0 --image IMAGE.qcow2 [options]

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
  --cpu TYPE            Type CPU QEMU. Defaut: x86-64-v2-AES.
  --ipconfig0 VALUE     Config IP cloud-init (ex: ip=10.50.30.15/24,gw=10.50.30.1). Defaut: ip=dhcp.
  --nameserver VALUE    DNS cloud-init. Defaut: 8.8.8.8.
  --vlan-tag N          Tag VLAN 802.1q sur net0 (1-4094).
  --root-password PASS  Mot de passe root cloud-init. Defaut: root.
  --bootstrap-guest     Installe qemu-guest-agent + stress-ng + SSH + proxys GANDAL via cloud-init.
  --template-prepared   Le template contient deja qemu-guest-agent + stress-ng + SSH.
  --snippet-storage S   Storage snippets Proxmox pour bootstrap. Defaut: local.
  --ca-dir PATH         Dossier contenant ca.crt, ca.key, ca.srl (obligatoire si --bootstrap-guest).
  --deb-server-url URL  Serveur HTTP pour les .deb des proxys. Defaut: http://192.168.123.100:8000.
  --start               Demarre la VM apres creation.
  -h, --help            Affiche cette aide.
EOF
}

fail() { echo "ERREUR: $*" >&2; exit 1; }

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

# ------------------------------------------------------------
# Variables
# ------------------------------------------------------------
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
CPU_TYPE="${OMEGA_VM_CPU_TYPE:-x86-64-v2-AES}"
IPCONFIG0="ip=dhcp"
# IP fixe DÉTERMINISTE par VMID (évite la collision .15 en dur) : si ces 2 champs
# sont fournis ET --ipconfig0 reste au défaut, l'IP = PREFIX.(START + vmid - BASE).
VM_IP_PREFIX=""
VM_IP_START=101
VM_VMID_BASE=3000
VM_GATEWAY=""
VM_NETMASK=24
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

# Options proxys
CA_DIR=""
DEB_SERVER_URL="http://192.168.123.100:8000"
GENERATE_CERT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/generate-proxy-cert.sh"
# Config GANDAL — externalisée (NE PAS committer de secret). Le token Proxmox vient
# de l'environnement / --proxmox-token, JAMAIS codé en dur dans le dépôt.
ANALYSEUR_HOST="${OMEGA_GANDAL_CENTRAL_IP:-192.168.123.100}"
ANALYSEUR_PORT="${OMEGA_GANDAL_ANALYSEUR_PORT:-5002}"
AGENT_CENTRAL_URL="${OMEGA_GANDAL_AGENT_CENTRAL_URL:-http://${ANALYSEUR_HOST}:5014}"
PROXMOX_HOST="${OMEGA_GANDAL_PROXMOX_HOST:-192.168.123.1}"
PROXMOX_NODE="${OMEGA_GANDAL_PROXMOX_NODE:-pve1}"
PROXMOX_TOKEN="${OMEGA_GANDAL_PROXMOX_TOKEN:-}"   # secret — fourni via env ou --proxmox-token

# ------------------------------------------------------------
# Traitement des options
# ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)             VMIDS="$2"; shift 2 ;;
        --vmids)            VMIDS="$2"; shift 2 ;;
        --name)             NAME_PREFIX="$2"; shift 2 ;;
        --storage)          STORAGE="$2"; shift 2 ;;
        --bridge)           BRIDGE="$2"; shift 2 ;;
        --image)            IMAGE="$2"; shift 2 ;;
        --template-id)      TEMPLATE_ID="$2"; shift 2 ;;
        --linked-clone)     LINKED_CLONE=true; shift ;;
        --adopt-existing)   ADOPT_EXISTING=true; shift ;;
        --sshkey)           SSHKEY="$2"; shift 2 ;;
        --ciuser)           CIUSER="$2"; shift 2 ;;
        --memory)           MEMORY="$2"; shift 2 ;;
        --balloon)          BALLOON="$2"; shift 2 ;;
        --cores)            CORES="$2"; shift 2 ;;
        --vcpus)            VCPUS="$2"; shift 2 ;;
        --sockets)          SOCKETS="$2"; shift 2 ;;
        --disk-max-gib)     DISK_MAX_GIB="$2"; shift 2 ;;
        --gpu-vram-mib)     GPU_VRAM_MIB="$2"; shift 2 ;;
        --cpu)              CPU_TYPE="$2"; shift 2 ;;
        --ipconfig0)        IPCONFIG0="$2"; shift 2 ;;
        --vm-ip-prefix)     VM_IP_PREFIX="$2"; shift 2 ;;
        --vm-ip-start)      VM_IP_START="$2"; shift 2 ;;
        --vm-vmid-base)     VM_VMID_BASE="$2"; shift 2 ;;
        --vm-gateway)       VM_GATEWAY="$2"; shift 2 ;;
        --vm-netmask)       VM_NETMASK="$2"; shift 2 ;;
        --nameserver)       NAMESERVER="$2"; shift 2 ;;
        --root-password)    ROOT_PASSWORD="$2"; shift 2 ;;
        --vlan-tag)         VLAN_TAG="$2"; shift 2 ;;
        --bootstrap-guest)  BOOTSTRAP_GUEST=true; shift ;;
        --template-prepared) TEMPLATE_PREPARED=true; shift ;;
        --snippet-storage)  SNIPPET_STORAGE="$2"; shift 2 ;;
        --start)            START=true; shift ;;
        --ca-dir)           CA_DIR="$2"; shift 2 ;;
        --deb-server-url)   DEB_SERVER_URL="$2"; shift 2 ;;
        --proxmox-token)    PROXMOX_TOKEN="$2"; shift 2 ;;
        --analyseur-host)   ANALYSEUR_HOST="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  fail "option inconnue: $1" ;;
    esac
done

# ------------------------------------------------------------
# Vérifications préalables
# ------------------------------------------------------------
command -v qm >/dev/null 2>&1 || fail "qm introuvable: lancer ce script sur un noeud Proxmox"
[[ -n "$VMIDS" ]]   || fail "--vmid ou --vmids requis"
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

[[ "$VCPUS" =~ ^[0-9]+$ && "$CORES" =~ ^[0-9]+$ && "$SOCKETS" =~ ^[0-9]+$ ]] \
    || fail "vcpus/cores/sockets doivent etre numeriques"
[[ "$MEMORY" =~ ^[0-9]+$ && "$BALLOON" =~ ^[0-9]+$ ]] \
    || fail "memory/balloon doivent etre numeriques"
[[ "$DISK_MAX_GIB" =~ ^[0-9]+$ && "$GPU_VRAM_MIB" =~ ^[0-9]+$ ]] \
    || fail "disk-max-gib/gpu-vram-mib doivent etre numeriques"
[[ "$VCPUS" -ge 1 ]]            || fail "--vcpus doit etre >= 1"
[[ "$BALLOON" -gt 0 ]]          || fail "--balloon doit etre > 0 pour la RAM initiale/minimale Omega"
[[ "$MEMORY" -gt "$BALLOON" ]]  || fail "--memory doit etre strictement superieur a --balloon"

MAX_VCPUS=$((CORES * SOCKETS))
[[ "$MAX_VCPUS" -ge 2 ]] || fail "--cores x --sockets doit etre >= 2 pour tester le vCPU elastique"

if [[ -n "$VLAN_TAG" ]]; then
    [[ "$VLAN_TAG" =~ ^[0-9]+$ && "$VLAN_TAG" -ge 1 && "$VLAN_TAG" -le 4094 ]] \
        || fail "--vlan-tag doit etre un entier entre 1 et 4094"
    NET0="virtio,bridge=${BRIDGE},firewall=${OMEGA_VM_NET_FIREWALL:-0},tag=${VLAN_TAG}"
else
    NET0="virtio,bridge=${BRIDGE},firewall=${OMEGA_VM_NET_FIREWALL:-0}"
fi

[[ "$VCPUS" -lt "$MAX_VCPUS" ]] || fail "--vcpus doit etre strictement inferieur a --cores x --sockets (${MAX_VCPUS})"

HOST_MAX_VCPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)"
if [[ "$HOST_MAX_VCPUS" =~ ^[0-9]+$ && "$HOST_MAX_VCPUS" -gt 0 && "$MAX_VCPUS" -gt "$HOST_MAX_VCPUS" ]]; then
    fail "--cores x --sockets = ${MAX_VCPUS}, mais ce noeud n'autorise que ${HOST_MAX_VCPUS} vCPU par VM."
fi

if $BOOTSTRAP_GUEST; then
    [[ -n "$CA_DIR" ]] || fail "--ca-dir requis avec --bootstrap-guest"
    [[ -d "$CA_DIR" && -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" && -f "$CA_DIR/ca.srl" ]] \
        || fail "CA introuvable ou incomplet dans $CA_DIR (ca.crt, ca.key, ca.srl requis)"
    [[ -f "$GENERATE_CERT_SCRIPT" ]] \
        || fail "generate-proxy-cert.sh introuvable à côté de ce script (cherché: $GENERATE_CERT_SCRIPT)"
    [[ -n "$PROXMOX_TOKEN" ]] \
        || echo "  ⚠️  PROXMOX_TOKEN vide — fournir --proxmox-token ou OMEGA_GANDAL_PROXMOX_TOKEN si le proxy-analyseur en a besoin (jamais en dur dans le dépôt)" >&2
fi

# ------------------------------------------------------------
# Extraction IP / GW depuis IPCONFIG0
# Formats supportés : ip=10.x.x.x/24,gw=10.x.x.x  ou  ip=dhcp
# ------------------------------------------------------------
parse_ipconfig() {
    # Retourne dans VM_IP (avec masque CIDR) et VM_GW
    VM_IP=""
    VM_GW=""
    if [[ "$IPCONFIG0" == *"ip=dhcp"* || "$IPCONFIG0" == "ip=dhcp" ]]; then
        return 0
    fi
    # Extraire ip=A.B.C.D/N
    VM_IP="$(echo "$IPCONFIG0" | grep -oP 'ip=\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')" || true
    # Extraire gw=A.B.C.D
    VM_GW="$(echo "$IPCONFIG0" | grep -oP 'gw=\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')" || true
    # Adresse seule sans masque (pour les certs)
    VM_IP_ADDR="$(echo "$VM_IP" | cut -d/ -f1)"
}

# ------------------------------------------------------------
# Boucle principale
# ------------------------------------------------------------
IFS=',' read -ra VMID_ARR <<< "$VMIDS"
IPCONFIG0_ORIG="$IPCONFIG0"   # valeur fournie par l'appelant (avant calcul par VMID)

for vmid in "${VMID_ARR[@]}"; do
    [[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID invalide: $vmid"

    if qm status "$vmid" >/dev/null 2>&1; then
        $ADOPT_EXISTING || fail "VM $vmid existe deja; supprimer ou choisir un autre VMID"
        echo "Adoption VM existante $vmid"
    fi

    # IP fixe PAR VMID si une base est fournie et --ipconfig0 reste au défaut.
    # Recalculé à CHAQUE itération depuis IPCONFIG0_ORIG (sinon la 2e VM hériterait
    # de l'IP de la 1re → collision).
    IPCONFIG0="$IPCONFIG0_ORIG"
    if [[ -n "$VM_IP_PREFIX" && -n "$VM_GATEWAY" && "$IPCONFIG0_ORIG" == "ip=dhcp" ]]; then
        ip_last=$(( VM_IP_START + vmid - VM_VMID_BASE ))
        if [[ "$ip_last" -ge 1 && "$ip_last" -le 254 ]]; then
            IPCONFIG0="ip=${VM_IP_PREFIX}.${ip_last}/${VM_NETMASK},gw=${VM_GATEWAY}"
        else
            echo "WARN: IP ${VM_IP_PREFIX}.${ip_last} hors plage pour VM $vmid — DHCP" >&2
        fi
    fi
    parse_ipconfig   # (re)calcule VM_IP / VM_GW / VM_IP_ADDR pour le cert de CETTE VM

    name="${NAME_PREFIX}-${vmid}"
    desc="omega_min_vcpus=${VCPUS} omega_max_vcpus=${MAX_VCPUS} omega_memory_min_mib=${BALLOON} omega_memory_max_mib=${MEMORY} omega_disk_max_gib=${DISK_MAX_GIB} omega_gpu_vram_mib=${GPU_VRAM_MIB}"

    # ----------------------------------------------------------
    # Création / clonage de la VM
    # ----------------------------------------------------------
    if $ADOPT_EXISTING; then
        :
    elif [[ -n "$TEMPLATE_ID" ]]; then
        echo "Clone VM $vmid ($name) depuis template $TEMPLATE_ID"
        prepare_template_for_clone
        cleanup_cloudinit_disk "$vmid"
        if $LINKED_CLONE; then
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

    # ----------------------------------------------------------
    # Application du profil Omega (cloud-init de base)
    # ----------------------------------------------------------
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

    if [[ -n "$SSHKEY" ]]; then
        [[ -f "$SSHKEY" ]] || fail "cle SSH introuvable: $SSHKEY"
        qm set "$vmid" --sshkeys "$SSHKEY"
    fi

    # ----------------------------------------------------------
    # Bootstrap guest : snippet cloud-init complet avec proxys
    # ----------------------------------------------------------
    if $BOOTSTRAP_GUEST; then
        snippet_dir="/var/lib/vz/snippets"
        snippet_name="omega-bootstrap-${vmid}.yaml"
        snippet_path="${snippet_dir}/${snippet_name}"
        mkdir -p "$snippet_dir"

        # --- 1. Certificats mTLS ---
        CERT_WRITE_FILES=""
        if [[ -n "$VM_IP_ADDR" ]]; then
            CERT_DIR="/tmp/proxy-certs-${vmid}"
            bash "$GENERATE_CERT_SCRIPT" \
                --vm-id "$name" \
                --vm-ip "$VM_IP_ADDR" \
                --ca-dir "$CA_DIR" \
                --out-dir "$CERT_DIR"

            B64_CA=$(base64 -w0 "${CERT_DIR}/ca.crt")
            B64_CRT=$(base64 -w0 "${CERT_DIR}/proxy.crt")
            B64_KEY=$(base64 -w0 "${CERT_DIR}/proxy.key")

            CERT_WRITE_FILES="  - path: /etc/gandal-proxy/pki/ca/ca.crt
    encoding: base64
    owner: root:root
    permissions: '0640'
    content: ${B64_CA}
  - path: /etc/gandal-proxy/pki/proxy/proxy.crt
    encoding: base64
    owner: root:root
    permissions: '0640'
    content: ${B64_CRT}
  - path: /etc/gandal-proxy/pki/proxy/proxy.key
    encoding: base64
    owner: root:root
    permissions: '0600'
    content: ${B64_KEY}"
        else
            echo "  ⚠️  IP statique non détectée dans IPCONFIG0 — certificats proxy non générés (mode DHCP)"
        fi

        # --- 2. Config réseau statique injectée dans le snippet ---
        # CORRECTIF: quand --cicustom remplace le datasource Proxmox NoCloud,
        # ipconfig0 n'est plus appliqué automatiquement. On écrit la config
        # netplan directement dans write_files pour garantir l'IP statique.
        NETPLAN_WRITE_FILE=""
        if [[ -n "$VM_IP" && -n "$VM_GW" ]]; then
            NETPLAN_WRITE_FILE="  - path: /etc/netplan/99-omega-static.yaml
    owner: root:root
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            addresses:
              - ${VM_IP}
            routes:
              - to: default
                via: ${VM_GW}
            nameservers:
              addresses: [${NAMESERVER}]"
        fi

        # --- 3. Fichiers de configuration des proxys ---
        # Indentés à 6 espaces pour correspondre à l'indentation YAML du bloc write_files
        PROXY_ENV_CONTENT="      ANALYSEUR_HOST=${ANALYSEUR_HOST}
      ANALYSEUR_PORT=${ANALYSEUR_PORT}
      VM_ID=${name}
      INTERVAL=5
      CERT_NAME=proxy
      PKI_DIR=/etc/gandal-proxy/pki
      CONTROLE_PORT=5007
      PROXMOX_HOST=${PROXMOX_HOST}
      PROXMOX_PORT=8006
      PROXMOX_TOKEN=${PROXMOX_TOKEN}
      PROXMOX_NODE=${PROXMOX_NODE}
      PROXMOX_VERIFY_SSL=false"

        PROXY_CHIFFREUR_ENV="      AGENT_CENTRAL_URL=${AGENT_CENTRAL_URL}
      VM_ID=${name}
      VM_IP=${VM_IP_ADDR}
      CA_CERT=/etc/gandal-proxy/pki/ca/ca.crt
      PROXY_CERT=/etc/gandal-proxy/pki/proxy/proxy.crt
      PROXY_KEY=/etc/gandal-proxy/pki/proxy/proxy.key"

        # --- 4. SSH keys yaml ---
        ssh_keys_yaml=""
        if [[ -n "$SSHKEY" && -f "$SSHKEY" ]]; then
            ssh_keys_yaml="ssh_authorized_keys:
  - $(cat "$SSHKEY")"
        fi

        # --- 5. Packages yaml ---
        package_yaml=""
        if ! $TEMPLATE_PREPARED; then
            package_yaml="package_update: true
packages:
  - qemu-guest-agent
  - stress-ng
  - openssh-server"
        fi

        # --- 6. Écriture du snippet ---
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
  - path: /etc/gandal-proxy/proxy.env
    owner: root:root
    permissions: '0640'
    content: |
${PROXY_ENV_CONTENT}
  - path: /etc/gandal-proxy/proxy-chiffreur.env
    owner: root:root
    permissions: '0640'
    content: |
${PROXY_CHIFFREUR_ENV}
  - path: /usr/local/sbin/gandal-proxy-install
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/sh
      # Installe les proxys GANDAL — IDÉMPOTENT et NON-BLOQUANT pour le boot.
      # Lancé par un timer (retry) : ne dépend PAS de la disponibilité réseau au
      # premier boot (VLAN omega isolée) → s'installe quand le réseau est ouvert.
      LOG=/var/log/gandal-proxy-install.log
      exec >>"\$LOG" 2>&1
      echo "=== gandal-proxy-install \$(date) ==="
      # Déjà installé et actif → on a fini : on désactive le timer.
      if systemctl is-active --quiet gandal-proxy 2>/dev/null; then
          systemctl disable --now gandal-proxy-install.timer 2>/dev/null || true
          echo "gandal-proxy déjà actif — timer désactivé"; exit 0
      fi
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y python3 python3-pip 2>/dev/null || true
      pip3 install grpcio grpcio-tools 2>/dev/null || true
      ok=1
      wget -q -O /tmp/proxy-analyseur.deb ${DEB_SERVER_URL}/proxy-analyseur.deb \\
          && dpkg -i /tmp/proxy-analyseur.deb 2>/dev/null || { apt-get install -f -y 2>/dev/null || true; ok=0; }
      wget -q -O /tmp/proxy-chiffreur.deb ${DEB_SERVER_URL}/proxy-chiffreur.deb \\
          && dpkg -i /tmp/proxy-chiffreur.deb 2>/dev/null || ok=0
      systemctl daemon-reload 2>/dev/null || true
      systemctl enable --now gandal-proxy 2>/dev/null || true
      if systemctl is-active --quiet gandal-proxy 2>/dev/null; then
          systemctl disable --now gandal-proxy-install.timer 2>/dev/null || true
          echo "gandal-proxy installé et actif — timer désactivé"
      else
          echo "réseau/deb indisponible (ok=\$ok) — nouvelle tentative au prochain tick"
      fi
  - path: /etc/systemd/system/gandal-proxy-install.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Installe les proxys GANDAL (best-effort, retry)
      After=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/gandal-proxy-install
  - path: /etc/systemd/system/gandal-proxy-install.timer
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Retry install proxys GANDAL jusqu'au succes
      [Timer]
      OnBootSec=30s
      OnUnitActiveSec=120s
      [Install]
      WantedBy=timers.target
  - path: /etc/cloud/cloud.cfg.d/99-omega-network-persist.cfg
    owner: root:root
    permissions: '0644'
    content: |
      # Empêche cloud-init de réécrire la config réseau aux boots suivants.
      network:
        config: disabled
${NETPLAN_WRITE_FILE}
${CERT_WRITE_FILES}
bootcmd:
  - [ bash, -lc, "if [ ! -e /var/lib/omega-firstboot-machine-id.done ]; then rm -f /etc/machine-id /var/lib/dbus/machine-id; systemd-machine-id-setup || true; touch /var/lib/omega-firstboot-machine-id.done; fi" ]
runcmd:
  - [ bash, -lc, "rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* 2>/dev/null || true" ]
  - [ bash, -lc, "test -s /etc/machine-id || systemd-machine-id-setup || true" ]
  - [ bash, -lc, "rm -f /var/lib/dbus/machine-id; ln -sf /etc/machine-id /var/lib/dbus/machine-id || true" ]
  - [ bash, -lc, "echo '${CIUSER}:${ROOT_PASSWORD}' | chpasswd" ]
  - [ bash, -lc, "export DEBIAN_FRONTEND=noninteractive; command -v qemu-ga >/dev/null 2>&1 && command -v stress-ng >/dev/null 2>&1 && test -x /usr/sbin/sshd || (apt-get update && apt-get install -y qemu-guest-agent stress-ng openssh-server)" ]
  - [ bash, -lc, "install -d -m 0755 /etc/ssh/sshd_config.d; printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' >/etc/ssh/sshd_config.d/99-omega-root-login.conf; systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true" ]
  - [ bash, -lc, "systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true; systemctl enable --now qemu-guest-agent.socket 2>/dev/null || true; systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true" ]
  - [ bash, -lc, "systemctl daemon-reload; systemctl enable --now omega-qga-ensure.service 2>/dev/null || true" ]
  - [ bash, -lc, "install -d -m 0750 /etc/gandal-proxy/pki/ca /etc/gandal-proxy/pki/proxy" ]
  - [ bash, -lc, "chmod 0640 /etc/gandal-proxy/pki/proxy/proxy.key 2>/dev/null || true" ]
  # Install proxys GANDAL = DÉCOUPLÉE du boot : on active seulement le timer (retry).
  # → le premier boot ne bloque JAMAIS sur apt/wget/pip (réseau isolé) ; QGA + IP
  #   remontent immédiatement. Le proxy s'installe dès que le réseau est ouvert.
  - [ bash, -lc, "systemctl daemon-reload; systemctl enable --now gandal-proxy-install.timer 2>/dev/null || true" ]
  - [ bash, -lc, "chmod 600 /etc/netplan/99-omega-static.yaml 2>/dev/null || true; netplan generate && netplan apply 2>/dev/null || true" ]
  - [ bash, -lc, "systemctl restart systemd-networkd 2>/dev/null || true" ]
EOF

        qm set "$vmid" --cicustom "user=${SNIPPET_STORAGE}:snippets/${snippet_name}"
    fi

    # ----------------------------------------------------------
    # Fichier firewall Proxmox par VM
    # ----------------------------------------------------------
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
        qm set "$vmid" --delete hookscript >/dev/null 2>&1 || true
        if ! qm start "$vmid"; then
            status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)"
            if [[ "$status" == "running" ]]; then
                echo "WARN: qm start $vmid a retourné une erreur, mais la VM est running; poursuite"
            else
                fail "qm start $vmid a échoué et la VM n'est pas running"
            fi
        fi
        qm set "$vmid" --hotplug cpu,disk,network >/dev/null
        echo "Verification profil Omega VM $vmid apres demarrage"
        verify_vm_profile "$vmid"
        echo "VM $vmid demarree"
    fi
done
