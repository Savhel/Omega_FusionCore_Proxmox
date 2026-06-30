#!/usr/bin/env bash
# Provisionne des VMs Omega sur un cluster Proxmox depuis la machine de dev.
#
# Le script copie le createur de VM sur le noeud controleur, verifie l'image
# cloud distante, la copie si demande, puis lance la creation Proxmox.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/provision-omega-vms-remote.sh --controller HOST --vmids 9001,9002,9003 --storage ceph-vm --image-remote PATH [options]

Options:
  --controller HOST       Noeud Proxmox principal joignable en SSH.
  --user USER             Utilisateur SSH. Defaut: root.
  --ssh-key PATH          Cle SSH privee optionnelle.
  --vmids A,B,C           Liste de VMIDs a creer.
  --storage NAME          Stockage Proxmox cible. Exemple: ceph-vm.
  --bridge NAME           Bridge Proxmox. Defaut: vmbr0.
  --image-remote PATH     Chemin qcow2 sur le noeud Proxmox.
  --image-local PATH      Si l'image distante manque, copie ce qcow2 local.
  --template-id ID        Template Proxmox cloud a utiliser/creer.
  --linked-clone          Clone lie rapide depuis le template. Defaut si template-id.
  --sshkey-remote PATH    Cle publique a injecter dans les VMs. Defaut: /root/.ssh/id_rsa.pub.
  --name PREFIX           Prefixe nom VM. Defaut: omega-test.
  --memory MIB            RAM max VM. Defaut: 3072.
  --balloon MIB           RAM initiale/minimale. Defaut: 512.
  --cores N               Max vCPU hotpluggable. Defaut: 4.
  --sockets N             Sockets QEMU. Defaut: 1.
  --vcpus N               vCPU au boot. Defaut: 1.
  --disk-max-gib N        Budget disque logique declare. Defaut: 20.
  --gpu-vram-mib N        Budget VRAM declare. Defaut: 0.
  --nodes A,B,C           Nœuds Proxmox autorisés. Défaut: découverte cluster.
  --root-password PASS    Mot de passe root cloud-init. Défaut: root.
  --vm-ip-prefix PREFIX   Préfixe IP fixe. Ex: 10.50.30. Vide = DHCP.
  --vm-ip-start N         Dernier octet IP pour le VMID de base. Défaut: 101.
  --vm-vmid-base N        VMID correspondant à --vm-ip-start. Défaut: 2300.
  --vm-gateway GW         Passerelle injectée via cloud-init. Ex: 10.50.30.1.
  --vm-netmask N          Masque CIDR. Défaut: 24.
  --vm-dns-ip IP          DNS injecté via cloud-init.
  --vm-vlan-tag N         Tag VLAN 802.1q (1-4094). Vide = pas de tag.
  --randomize             Profils VM aléatoires mais conformes Omega.
  --bootstrap-wait SECS   Compatibilité ancienne option; la validation invité se fait au deuxième tour.
  --recreate-bad          Supprime/recrée toute VM non conforme une fois, même si elle existait déjà.
  --resource-only        Valide seulement les ressources Omega; ignore QGA/ping/stress-ng/SSH.
  --image-prepared       Image qcow2 déjà préparée; ne lance pas virt-customize.
  --no-start              Ne demarre pas les VMs apres creation.
  -h, --help              Affiche cette aide.

Exemple:
  scripts/provision-omega-vms-remote.sh \
    --controller 192.168.123.100 \
    --vmids 9001,9002,9003 \
    --storage ceph-vm \
    --bridge vmbr0 \
    --image-local /home/me/images/debian-12-generic-amd64.qcow2 \
    --image-remote /var/lib/vz/template/iso/debian-12-generic-amd64.qcow2
EOF
}

fail() {
    echo "ERREUR: $*" >&2
    exit 1
}

quote_args() {
    printf ' %q' "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_SCRIPT="${SCRIPT_DIR}/create-omega-vm.sh"

CONTROLLER=""
DEPLOY_USER="root"
SSH_KEY=""
VMIDS=""
STORAGE=""
BRIDGE="vmbr0"
IMAGE_REMOTE=""
IMAGE_LOCAL=""
TEMPLATE_ID=""
LINKED_CLONE=false
SSHKEY_REMOTE="/root/.ssh/id_rsa.pub"
NAME_PREFIX="omega-test"
MEMORY=3072
BALLOON=512
CORES=4
SOCKETS=1
VCPUS=1
DISK_MAX_GIB=20
GPU_VRAM_MIB=0
NODES_CSV=""
ROOT_PASSWORD="root"
VM_IP_PREFIX=""
VM_IP_START=101
VM_VMID_BASE=3000
# Plage d'allocation dense : on utilise TOUTES les adresses libres de VM_IP_MIN à
# VM_IP_MAX (défaut .2 à .253 ; .1 = gateway réservée). L'IP n'est plus liée au VMID :
# chaque nouvelle VM prend la PLUS BASSE adresse libre du /24, donc aucune adresse gaspillée.
VM_IP_MIN=2
VM_IP_MAX=253
VM_GATEWAY=""
VM_NETMASK=24
VM_DNS_IP=""
VM_VLAN_TAG=""
RANDOMIZE=false
BOOTSTRAP_WAIT=180
RECREATE_BAD=false
RESOURCE_ONLY=false
IMAGE_PREPARED=false
START=true

# Proxys de sécurité GANDAL (chiffreur + analyseur) installés dans chaque VM après
# qu'elle ait son IP (additif, non bloquant). Désactivable via --no-security-proxies.
INSTALL_SECURITY_PROXIES="${OMEGA_INSTALL_SECURITY_PROXIES:-true}"
SECURITY_BUNDLE_URL="${OMEGA_SECURITY_BUNDLE_URL:-http://192.168.123.100:8010}"
SECURITY_ANALYSEUR_HOST="${OMEGA_SECURITY_ANALYSEUR_HOST:-192.168.123.100}"
SECURITY_ANALYSEUR_PORT="${OMEGA_SECURITY_ANALYSEUR_PORT:-5002}"
SECURITY_CHIFFREUR_URL="${OMEGA_SECURITY_CHIFFREUR_URL:-https://192.168.123.100:5014}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller) CONTROLLER="$2"; shift 2 ;;
        --user) DEPLOY_USER="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --vmids) VMIDS="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --image-remote) IMAGE_REMOTE="$2"; shift 2 ;;
        --image-local) IMAGE_LOCAL="$2"; shift 2 ;;
        --template-id) TEMPLATE_ID="$2"; shift 2 ;;
        --linked-clone) LINKED_CLONE=true; shift ;;
        --sshkey-remote) SSHKEY_REMOTE="$2"; shift 2 ;;
        --name) NAME_PREFIX="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --balloon) BALLOON="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --sockets) SOCKETS="$2"; shift 2 ;;
        --vcpus) VCPUS="$2"; shift 2 ;;
        --disk-max-gib) DISK_MAX_GIB="$2"; shift 2 ;;
        --gpu-vram-mib) GPU_VRAM_MIB="$2"; shift 2 ;;
        --nodes) NODES_CSV="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --vm-ip-prefix) VM_IP_PREFIX="$2"; shift 2 ;;
        --vm-ip-start) VM_IP_START="$2"; shift 2 ;;
        --vm-vmid-base) VM_VMID_BASE="$2"; shift 2 ;;
        --vm-ip-min) VM_IP_MIN="$2"; shift 2 ;;
        --vm-ip-max) VM_IP_MAX="$2"; shift 2 ;;
        --vm-gateway) VM_GATEWAY="$2"; shift 2 ;;
        --vm-netmask) VM_NETMASK="$2"; shift 2 ;;
        --vm-dns-ip) VM_DNS_IP="$2"; shift 2 ;;
        --vm-vlan-tag) VM_VLAN_TAG="$2"; shift 2 ;;
        --randomize) RANDOMIZE=true; shift ;;
        --bootstrap-wait) BOOTSTRAP_WAIT="$2"; shift 2 ;;
        --recreate-bad) RECREATE_BAD=true; shift ;;
        --resource-only) RESOURCE_ONLY=true; shift ;;
        --image-prepared) IMAGE_PREPARED=true; shift ;;
        --no-start) START=false; shift ;;
        --security-proxies) INSTALL_SECURITY_PROXIES=true; shift ;;
        --no-security-proxies) INSTALL_SECURITY_PROXIES=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -x "$CREATE_SCRIPT" ]] || fail "script introuvable ou non executable: $CREATE_SCRIPT"
[[ -n "$CONTROLLER" ]] || fail "--controller requis"
[[ -n "$VMIDS" ]] || fail "--vmids requis"
[[ -n "$STORAGE" ]] || fail "--storage requis"
[[ -n "$IMAGE_REMOTE" || -n "$TEMPLATE_ID" ]] || fail "--image-remote requis sans --template-id"
if [[ -n "$TEMPLATE_ID" ]]; then
    [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]] || fail "template-id doit etre numerique"
    LINKED_CLONE=true
fi
if $RESOURCE_ONLY; then
    IMAGE_PREPARED=true
fi
[[ "$CORES" =~ ^[0-9]+$ && "$SOCKETS" =~ ^[0-9]+$ && "$VCPUS" =~ ^[0-9]+$ ]] || fail "cores/sockets/vcpus doivent etre numeriques"
[[ "$MEMORY" =~ ^[0-9]+$ && "$BALLOON" =~ ^[0-9]+$ ]] || fail "memory/balloon doivent etre numeriques"
[[ "$BOOTSTRAP_WAIT" =~ ^[0-9]+$ ]] || fail "bootstrap-wait doit etre numerique"
MAX_VCPUS=$((CORES * SOCKETS))
[[ "$MAX_VCPUS" -ge 2 ]] || fail "cores*sockets doit etre >= 2"
[[ "$VCPUS" -lt "$MAX_VCPUS" ]] || fail "vcpus doit etre < cores*sockets (${MAX_VCPUS})"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || fail "cle SSH introuvable: $SSH_KEY"
    SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")
    SCP_OPTS=(-i "$SSH_KEY" "${SCP_OPTS[@]}")
fi

REMOTE="${DEPLOY_USER}@${CONTROLLER}"
REMOTE_DIR="/opt/omega-remote-paging/scripts"
REMOTE_CREATE="${REMOTE_DIR}/create-omega-vm.sh"

ssh_node() {
    local node="$1"; shift
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "$@"
}

scp_node() {
    local src="$1" node="$2" dst="$3"
    scp "${SCP_OPTS[@]}" "$src" "${DEPLOY_USER}@${node}:${dst}"
}

HOOK_WATCHERS_TO_RESTORE=()
KVM_WRAPPERS_TO_RESTORE=()

pause_kvm_wrapper() {
    local node="$1"
    if ssh_node "$node" "test -L /usr/bin/kvm && readlink -f /usr/bin/kvm | grep -Eq 'omega-qemu-launcher|kvm-omega|omega-qemu-wrapper' && test -x /usr/bin/kvm.real" 2>/dev/null; then
        echo "  -> $node : pause wrapper QEMU Omega"
        ssh_node "$node" "ln -sfn /usr/bin/kvm.real /usr/bin/kvm"
        KVM_WRAPPERS_TO_RESTORE+=("$node")
    fi
}

restore_kvm_wrappers() {
    local node
    for node in "${KVM_WRAPPERS_TO_RESTORE[@]:-}"; do
        echo "  -> $node : restauration wrapper QEMU Omega"
        ssh_node "$node" "if test -x /opt/omega-remote-paging/bin/kvm-omega; then ln -sfn /opt/omega-remote-paging/bin/kvm-omega /usr/bin/kvm; elif test -x /opt/omega-remote-paging/bin/omega-qemu-wrapper; then ln -sfn /opt/omega-remote-paging/bin/omega-qemu-wrapper /usr/bin/kvm; fi" >/dev/null 2>&1 || true
    done
}

pause_hookscript_watcher() {
    local node="$1"
    if ssh_node "$node" "systemctl is-active --quiet omega-hookscript-watcher.service" 2>/dev/null; then
        echo "  -> $node : pause omega-hookscript-watcher"
        ssh_node "$node" "systemctl stop omega-hookscript-watcher.service"
        HOOK_WATCHERS_TO_RESTORE+=("$node")
    fi
}

restore_hookscript_watchers() {
    local node
    for node in "${HOOK_WATCHERS_TO_RESTORE[@]:-}"; do
        echo "  -> $node : restauration omega-hookscript-watcher"
        ssh_node "$node" "systemctl start omega-hookscript-watcher.service" >/dev/null 2>&1 || true
    done
}

restore_provisioning_guards() {
    restore_kvm_wrappers
    restore_hookscript_watchers
}

discover_nodes() {
    if [[ -n "$NODES_CSV" ]]; then
        tr ',' '\n' <<< "$NODES_CSV" | awk 'NF'
        return
    fi
    ssh "${SSH_OPTS[@]}" "$REMOTE" "pvesh get /nodes --output-format json" | \
        python3 -c 'import json,sys
for n in json.load(sys.stdin):
    node=n.get("node")
    if node:
        print(node)'
}

random_between() {
    local min="$1" max="$2"
    [[ "$max" -le "$min" ]] && echo "$min" || echo $(( min + RANDOM % (max - min + 1) ))
}

profile_for_vmid() {
    local max_cores="$1" base_memory="$2" base_balloon="$3" base_gpu="$4"
    local p_cores p_memory p_balloon
    if $RANDOMIZE; then
        p_cores="$(random_between 2 "$max_cores")"
        case $((RANDOM % 4)) in
            0) p_memory=3072 ;;
            1) p_memory=4096 ;;
            2) p_memory="$base_memory" ;;
            *) p_memory="$base_memory" ;;
        esac
        [[ "$p_memory" -le "$base_memory" ]] || p_memory="$base_memory"
        [[ "$p_memory" -ge 3072 ]] || p_memory=3072
        case $((RANDOM % 4)) in
            0) p_balloon=512 ;;
            1) p_balloon=768 ;;
            *) p_balloon="$base_balloon" ;;
        esac
        [[ "$p_balloon" -lt "$p_memory" ]] || p_balloon=$((p_memory / 4))
        [[ "$p_balloon" -ge 512 ]] || p_balloon=512
    else
        p_cores="$max_cores"
        p_memory="$base_memory"
        p_balloon="$base_balloon"
    fi
    printf '%s,%s,%s,%s\n' "$p_cores" "$p_memory" "$p_balloon" "$base_gpu"
}

omega_create_sockets() {
    # Proxmox CPU hotplug est le plus fiable avec un seul socket et un plafond
    # exprimé par cores=max_vcpus. Les profils multi-sockets peuvent démarrer,
    # puis être normalisés différemment par Proxmox/QEMU après start.
    echo 1
}

node_max_vcpus() {
    local node="$1" n
    n="$(ssh_node "$node" "getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2" 2>/dev/null | awk 'NF{print $1; exit}')"
    [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]] || n=2
    echo "$n"
}

vm_cluster_node() {
    local vmid="$1"
    ssh "${SSH_OPTS[@]}" "$REMOTE" "pvesh get /cluster/resources --type vm --output-format json" | \
        python3 -c "import json,sys
for v in json.load(sys.stdin):
    if v.get('vmid') == int('$vmid'):
        print(v.get('node',''))
        break" 2>/dev/null
}

# alloc_free_ip <vmid> : renvoie PREFIX.<octet> = plus basse adresse LIBRE dans
# [VM_IP_MIN..VM_IP_MAX] du sous-réseau VM_IP_PREFIX/24. Utilise toutes les adresses
# disponibles (pas de gaspillage). Réserve .1 (gateway). Si la VM possède déjà une IP
# en plage, la conserve (idempotent / adoption). Échoue (rc1) si le /24 est saturé.
alloc_free_ip() {
    local vmid="$1"
    # NB : `|| true` après chaque grep — un grep sans correspondance sort en code 1,
    # ce qui, avec `set -o pipefail`, ferait échouer la fonction MÊME quand une IP
    # libre est trouvée (faux « plus aucune adresse libre »). On neutralise donc le
    # code de sortie des grep ; seul le code de python (libre/saturé) doit compter.
    ssh "${SSH_OPTS[@]}" "$REMOTE" "{ grep -rhoE '^ipconfig0:.*ip=${VM_IP_PREFIX//./\\.}\.[0-9]+/' /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null || true; echo '---SELF---'; grep -hoE '^ipconfig0:.*ip=${VM_IP_PREFIX//./\\.}\.[0-9]+/' /etc/pve/nodes/*/qemu-server/${vmid}.conf 2>/dev/null || true; }" \
      | PREFIX="$VM_IP_PREFIX" IPMIN="$VM_IP_MIN" IPMAX="$VM_IP_MAX" python3 -c '
import os, re, sys
prefix = os.environ["PREFIX"]; lo = int(os.environ["IPMIN"]); hi = int(os.environ["IPMAX"])
used = set([1])                      # .1 = gateway réservée
self_ip = None
section = "all"
pat = re.compile(r"ip=" + re.escape(prefix) + r"\.(\d+)/")
for line in sys.stdin:
    line = line.strip()
    if line == "---SELF---":
        section = "self"; continue
    m = pat.search(line)
    if not m: continue
    octet = int(m.group(1))
    if section == "self":
        self_ip = octet              # IP actuelle de CETTE vm (à conserver)
    else:
        used.add(octet)
# La VM garde son IP si elle en a déjà une dans la plage.
if self_ip is not None and lo <= self_ip <= hi:
    print(f"{prefix}.{self_ip}"); sys.exit(0)
for n in range(lo, hi + 1):
    if n not in used:
        print(f"{prefix}.{n}"); sys.exit(0)
sys.exit(1)
'
}

# Liste les VMs omega ACTUELLES du cluster, une par ligne : 'vmid<TAB>pve_node'.
# Identification = tag 'omega' autonome (même règle que le watchdog), ce qui exclut
# naturellement les templates (tag 'omega-template') et l'infra (pfSense/DNS non taggés).
# Sert à compter l'occupation réelle pour répartir les NOUVELLES VMs (1 Emilia/2 Ram/2 Rem).
list_omega_vms_by_node() {
    ssh "${SSH_OPTS[@]}" "$REMOTE" "pvesh get /cluster/resources --type vm --output-format json" | \
        python3 -c "import json,sys,re
pat=re.compile(r'(^|[;, ])omega([;, ]|\$)')
for v in json.load(sys.stdin):
    if v.get('template'): continue
    tags=v.get('tags') or ''
    if not pat.search(tags): continue
    vmid=v.get('vmid'); node=v.get('node') or ''
    if vmid is not None and node:
        print('%s\t%s' % (vmid, node))" 2>/dev/null
}

node_ssh_target() {
    local pve_node="$1" resolved
    for n in "${CLUSTER_NODES[@]:-}"; do
        [[ "$n" == "$pve_node" ]] && { echo "$n"; return; }
    done
    resolved="$(ssh "${SSH_OPTS[@]}" "$REMOTE" "getent hosts '$pve_node' | awk '{print \$1; exit}'" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
        for n in "${CLUSTER_NODES[@]:-}"; do
            [[ "$n" == "$resolved" ]] && { echo "$n"; return; }
        done
        echo "$resolved"
        return
    fi
    echo "$pve_node"
}

node_is_provision_eligible() {
    local node="$1"
    ssh_node "$node" "command -v qm >/dev/null 2>&1 && command -v pvesm >/dev/null 2>&1 && qm list >/dev/null 2>&1 && pvesm status >/dev/null 2>&1 && test -e /dev/kvm" >/dev/null 2>&1
}

filter_provision_nodes() {
    local node eligible=()
    for node in "${CLUSTER_NODES[@]}"; do
        if node_is_provision_eligible "$node"; then
            eligible+=("$node")
        else
            echo "WARN: nœud ignoré pour provisioning VM: $node (qm/pvesm inutilisable ou /dev/kvm absent)" >&2
        fi
    done
    CLUSTER_NODES=("${eligible[@]}")
}

proxmox_node_name() {
    local node="$1"
    ssh_node "$node" "hostname -s"
}

destroy_vm_remote() {
    local node="$1" vmid="$2"
    ssh_node "$node" "qm unlock '$vmid' >/dev/null 2>&1 || true
qm stop '$vmid' --skiplock 1 >/dev/null 2>&1 || qm stop '$vmid' >/dev/null 2>&1 || true
qm unlock '$vmid' >/dev/null 2>&1 || true
qm destroy '$vmid' --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
pvesm free '${STORAGE}:vm-${vmid}-cloudinit' >/dev/null 2>&1 || true
qm unlock '$vmid' >/dev/null 2>&1 || true
qm destroy '$vmid' --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true"
}

wait_vm_absent() {
    local vmid="$1" timeout="${2:-90}" end
    end=$((SECONDS + timeout))
    while [[ $SECONDS -lt $end ]]; do
        [[ -z "$(vm_cluster_node "$vmid" || true)" ]] && return 0
        sleep 3
    done
    return 1
}

cleanup_cloudinit_remote() {
    local node="$1" vmid="$2"
    ssh_node "$node" "
qm set '$vmid' --delete scsi1 >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6; do
    if ! pvesm list '${STORAGE}' 2>/dev/null | grep -q "vm-${vmid}-cloudinit"; then
        exit 0
    fi
    pvesm free '${STORAGE}:vm-${vmid}-cloudinit' >/dev/null 2>&1 || true
    if ! pvesm list '${STORAGE}' 2>/dev/null | grep -q "vm-${vmid}-cloudinit"; then
        exit 0
    fi
    qm stop '$vmid' --skiplock 1 >/dev/null 2>&1 || qm stop '$vmid' >/dev/null 2>&1 || true
    sleep 5
done
true"
}

cleanup_incomplete_template_remote() {
    local node="$1"
    [[ -n "$TEMPLATE_ID" ]] || return 0
    if ! ssh_node "$node" "qm status '$TEMPLATE_ID' >/dev/null 2>&1"; then
        return 0
    fi
    if ssh_node "$node" "qm config '$TEMPLATE_ID' 2>/dev/null | grep -q '^template: 1'"; then
        return 0
    fi
    if ssh_node "$node" "qm config '$TEMPLATE_ID' 2>/dev/null | grep -Eq 'omega_template_prepared=building|tags:.*omega-template'"; then
        echo "Template Omega incomplet $TEMPLATE_ID detecte sur $node; suppression avant recreation"
        destroy_vm_remote "$node" "$TEMPLATE_ID"
        wait_vm_absent "$TEMPLATE_ID" 120 || fail "template incomplet $TEMPLATE_ID toujours present apres suppression"
        return 0
    fi
    fail "VM $TEMPLATE_ID existe sur $node mais n'est pas un template Omega incomplet; suppression manuelle requise ou choisir un autre --template-id."
}

import_template_disk_remote() {
    local node="$1" prepared_image="$2"
    local attempt max_attempts=5 delay=20 output
    for attempt in $(seq 1 "$max_attempts"); do
        echo "Import disque template $TEMPLATE_ID vers stockage $STORAGE (tentative $attempt/$max_attempts)"
        if output="$(ssh_node "$node" "qm importdisk '$TEMPLATE_ID' '$prepared_image' '$STORAGE'" 2>&1)"; then
            [[ -n "$output" ]] && printf '%s\n' "$output"
            return 0
        fi
        printf '%s\n' "$output" >&2
        if printf '%s\n' "$output" | grep -Eqi "locked command timed out|rbd error:.*locked|got timeout|can't lock"; then
            if [[ "$attempt" -lt "$max_attempts" ]]; then
                echo "Lock Proxmox/Ceph detecte sur $STORAGE; attente ${delay}s puis nouvel essai" >&2
                ssh_node "$node" "pvesm status 2>/dev/null | grep -E '^(Name|${STORAGE}[[:space:]])'" >&2 || true
                sleep "$delay"
                continue
            fi
        fi
        return 1
    done
    return 1
}

prepare_template_for_clone() {
    local node="$1"
    [[ -n "$TEMPLATE_ID" ]] || return 0
    # Le disque cloud-init d'une template est inutile pour les clones Omega:
    # chaque VM reçoit son propre cloud-init après clone. Le garder force
    # Proxmox à cloner ide2 et peut échouer si vm-<vmid>-cloudinit existe déjà.
    cleanup_cloudinit_remote "$node" "$TEMPLATE_ID"
}

clone_template_to_node() {
    local template_node="$1" target_node="$2" vmid="$3" name="$4" target_pve_node
    target_pve_node="$(proxmox_node_name "$target_node")"
    echo "Clone template $TEMPLATE_ID -> VM $vmid sur nœud Proxmox ${target_pve_node}"
    prepare_template_for_clone "$template_node"
    cleanup_cloudinit_remote "$target_node" "$vmid"
    if $LINKED_CLONE; then
        ssh_node "$template_node" "qm clone '$TEMPLATE_ID' '$vmid' --name '$name' --target '$target_pve_node' --full 0"
    else
        ssh_node "$template_node" "qm clone '$TEMPLATE_ID' '$vmid' --name '$name' --target '$target_pve_node' --storage '$STORAGE' --full 1"
    fi
}

validate_vm_static_remote() {
    local node="$1" vmid="$2"
    ssh_node "$node" "vmid='$vmid'; cfg=\$(qm config \"\$vmid\" 2>/dev/null) || exit 10
cores=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"cores\"{print \$2;exit}'); cores=\${cores:-1}
sockets=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"sockets\"{print \$2;exit}'); sockets=\${sockets:-1}
vcpus=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"vcpus\"{print \$2;exit}')
memory=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"memory\"{print \$2;exit}')
balloon=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"balloon\"{print \$2;exit}')
hotplug=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"hotplug\"{print \$2;exit}')
agent=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"agent\"{print \$2;exit}')
net0=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"net0\"{print \$2;exit}')
scsihw=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"scsihw\"{print \$2;exit}')
desc=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1==\"description\"{print \$2;exit}')
smp=\$(qm showcmd \"\$vmid\" --pretty 2>/dev/null | grep -- '-smp' | head -1 || true)
smp_max=\$(printf '%s\n' \"\$smp\" | sed -n 's/.*maxcpus=\([0-9][0-9]*\).*/\1/p' | head -1)
desc_max=\$(printf '%s\n' \"\$desc\" | tr ' ' '\n' | awk -F= '\$1==\"omega_max_vcpus\"{print \$2;exit}')
max=\$((cores * sockets))
if printf '%s\n' \"\$smp_max\" | grep -Eq '^[0-9]+$' && test \"\$smp_max\" -gt \"\$max\"; then
    max=\"\$smp_max\"
fi
if printf '%s\n' \"\$desc_max\" | grep -Eq '^[0-9]+$' && test \"\$desc_max\" -gt \"\$max\"; then
    max=\"\$desc_max\"
fi
test -n \"\$vcpus\" && test \"\$max\" -gt 1 && test \"\$vcpus\" -lt \"\$max\" || { echo \"bad vcpu profile cores=\$cores sockets=\$sockets vcpus=\$vcpus smp_max=\${smp_max:-?} desc_max=\${desc_max:-?}\" >&2; exit 11; }
test -n \"\$memory\" && test -n \"\$balloon\" && test \"\$balloon\" -gt 0 && test \"\$balloon\" -lt \"\$memory\" || { echo \"bad memory profile memory=\$memory balloon=\$balloon\" >&2; exit 12; }
case \",\$hotplug,\" in *,cpu,*) ;; *) echo \"missing hotplug cpu\" >&2; exit 13;; esac
case \",\$hotplug,\" in *,memory,*) echo \"memory hotplug forbidden\" >&2; exit 14;; esac
numa=\$(printf '%s\n' \"\$cfg\" | awk -F': ' '\$1=="numa"{print \$2;exit}')
[ \"\${numa:-0}\" != \"1\" ] || { echo \"numa=1 incompatible with Omega memory backend\" >&2; exit 15; }
case \"\$agent\" in *enabled=1*|1) ;; *) echo \"agent disabled\" >&2; exit 15;; esac
case \"\$net0\" in virtio=*bridge=*) ;; *) echo \"bad net0=\$net0\" >&2; exit 16;; esac
case \"\$scsihw\" in virtio-scsi*) ;; *) echo \"bad scsihw=\$scsihw\" >&2; exit 17;; esac
case \"\$desc\" in *omega_min_vcpus=*omega_max_vcpus=*omega_memory_min_mib=*omega_memory_max_mib=*omega_disk_max_gib=*omega_gpu_vram_mib=*) ;; *) echo \"bad omega description\" >&2; exit 18;; esac
printf '%s\n' \"\$smp\" | grep -q \"maxcpus=\$max\" || { echo \"bad smp=\$smp expected maxcpus=\$max\" >&2; exit 19; }
echo \"static OK: cores=\$cores sockets=\$sockets vcpus=\$vcpus maxcpus=\$max memory=\$memory balloon=\$balloon\""
}

# Garantit l'accès SSH root/mot-de-passe sur une VM, de façon AUTONOME et idempotente.
# Indispensable au chemin --resource-only (gateway Web GANDAL) qui NE passe PAS par
# wait_qga_and_bootstrap_remote. Attend le QGA (borné), pose root:<pwd>, écrit le
# drop-in 00- (prioritaire sur 50-cloud-init=without-password) ET REDÉMARRE ssh pour
# que le démon EN COURS prenne la config (sinon il reste sur l'ancien without-password).
ensure_ssh_root_remote() {
    local node="$1" vmid="$2" password_q
    printf -v password_q '%q' "$ROOT_PASSWORD"
    ssh_node "$node" "vmid='$vmid'; root_password=$password_q
for _ in \$(seq 1 30); do
    qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1 && break
    sleep 4
done
qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1 || { echo \"ensure_ssh_root: QGA absent VM \$vmid\" >&2; exit 0; }
qm guest exec \"\$vmid\" -- bash -lc 'echo root:'\"\$root_password\"' | chpasswd; install -d -m 0755 /etc/ssh/sshd_config.d; printf \"PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n\" >/etc/ssh/sshd_config.d/00-omega-root-login.conf; systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true' >/dev/null 2>&1 \
    && echo \"    accès SSH root garanti (VM \$vmid)\" || echo \"    ⚠️  ensure_ssh_root échoué (VM \$vmid)\"" 2>/dev/null
}

wait_qga_and_bootstrap_remote() {
    local node="$1" vmid="$2" timeout="${3:-3}"
    local password_q
    printf -v password_q '%q' "$ROOT_PASSWORD"
    ssh_node "$node" "vmid='$vmid'; timeout='$timeout'; root_password=$password_q; end=\$((SECONDS + timeout))
while [ \$SECONDS -lt \$end ]; do
    if qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 && ! qm agent \"\$vmid\" ping >/dev/null 2>&1; then
    echo \"QGA not ready after \${timeout}s — tentative activation via SSH root/root\"
    mac=\$(qm config \"\$vmid\" 2>/dev/null | sed -n 's/^net0: virtio=\\([^,]*\\).*/\\1/p' | head -1 | tr 'A-F' 'a-f')
    ip=\"\"
    for _ in \$(seq 1 30); do
        if [ -n \"\$mac\" ]; then
            ip=\$(ip neigh | awk -v mac=\"\$mac\" 'tolower(\$0) ~ mac && \$1 !~ /^fe80/ {print \$1; exit}')
        fi
        [ -n \"\$ip\" ] && break
        sleep 1
    done
    if [ -n \"\$ip\" ] && command -v sshpass >/dev/null 2>&1; then
        for _ in \$(seq 1 20); do
            timeout 1 bash -lc \"</dev/tcp/\$ip/22\" >/dev/null 2>&1 && break
            sleep 1
        done
        sshpass -p \"\$root_password\" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \"root@\$ip\" 'export DEBIAN_FRONTEND=noninteractive; command -v qemu-ga >/dev/null 2>&1 && command -v stress-ng >/dev/null 2>&1 && test -x /usr/sbin/sshd || (apt-get update && apt-get install -y qemu-guest-agent stress-ng openssh-server); systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true; systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true; systemctl enable --now qemu-guest-agent.socket 2>/dev/null || true; systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true; systemctl is-active qemu-guest-agent; command -v stress-ng' || true
        for _ in \$(seq 1 30); do
            qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1 && break
            sleep 1
        done
    fi
fi
qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1 || { echo \"QGA not ready after activation attempt\" >&2; exit 21; }
pid_json=\$(qm guest exec \"\$vmid\" -- bash -lc 'echo root:root | chpasswd; install -d -m 0755 /etc/ssh/sshd_config.d; printf \"PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n\" >/etc/ssh/sshd_config.d/00-omega-root-login.conf; systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true; command -v stress-ng >/dev/null && systemctl is-active qemu-guest-agent >/dev/null') || exit 22
pid=\$(printf '%s' \"\$pid_json\" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"pid\", \"\"))' 2>/dev/null || true)
test -n \"\$pid\" || exit 22
guest_ok=0
for _ in \$(seq 1 5); do
    st=\$(qm guest exec-status \"\$vmid\" \"\$pid\" 2>/dev/null || true)
    printf '%s' \"\$st\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get(\"exited\") else 1)' 2>/dev/null || { sleep 1; continue; }
    code=\$(printf '%s' \"\$st\" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"exitcode\", 1))' 2>/dev/null || echo 1)
    test \"\$code\" = 0 || { printf '%s' \"\$st\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"out-data\", \"\") + d.get(\"err-data\", \"\"), end=\"\")' 2>/dev/null || true; exit 24; }
    echo \"guest OK: qemu-guest-agent + stress-ng + SSH + root password\"
    guest_ok=1
    break
done
if [ \"\$guest_ok\" != 1 ]; then
    echo \"guest check timed out after 5s\" >&2
    exit 23
fi
end_ip=\$((SECONDS + timeout))
while [ \$SECONDS -lt \$end_ip ]; do
    ifaces=\$(qm guest cmd \"\$vmid\" network-get-interfaces 2>/dev/null || qm agent \"\$vmid\" network-get-interfaces 2>/dev/null || true)
    ip=\$(printf '%s' \"\$ifaces\" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
for iface in data:
    for addr in iface.get(\"ip-addresses\", []):
        ip=addr.get(\"ip-address\", \"\")
        if addr.get(\"ip-address-type\") == \"ipv4\" and not ip.startswith(\"127.\") and not ip.startswith(\"169.254.\"):
            print(ip)
            raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null || true)
    if [ -n \"\$ip\" ]; then
        echo \"network OK: ipv4=\$ip\"
        exit 0
    fi
    sleep 1
done
echo \"guest network not ready after \${timeout}s: no non-loopback IPv4\" >&2
exit 25"
}

repair_guest_remote() {
    local node="$1" vmid="$2"
    local password_q
    printf -v password_q '%q' "$ROOT_PASSWORD"
    ssh_node "$node" "vmid='$vmid'; root_password=$password_q
repair_cmd='cloud-init status --long || true
journalctl -u cloud-init --no-pager -n 100 || true
systemctl status qemu-guest-agent --no-pager || true
echo root:'\"\$root_password\"' | chpasswd
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-guest-agent stress-ng openssh-server
install -d -m 0755 /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' >/etc/ssh/sshd_config.d/00-omega-root-login.conf
systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true; systemctl enable --now qemu-guest-agent.socket 2>/dev/null || true; systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
command -v stress-ng
systemctl is-active qemu-guest-agent'
if qm guest cmd \"\$vmid\" ping >/dev/null 2>&1 || qm agent \"\$vmid\" ping >/dev/null 2>&1; then
    pid_json=\$(qm guest exec \"\$vmid\" -- bash -lc \"\$repair_cmd\") || exit 22
else
    mac=\$(qm config \"\$vmid\" 2>/dev/null | sed -n 's/^net0: virtio=\\([^,]*\\).*/\\1/p' | head -1 | tr 'A-F' 'a-f')
    ip=\"\"
    if [ -n \"\$mac\" ]; then
        ip=\$(ip neigh | awk -v mac=\"\$mac\" 'tolower(\$0) ~ mac && \$1 !~ /^fe80/ {print \$1; exit}')
    fi
    if [ -n \"\$ip\" ] && command -v sshpass >/dev/null 2>&1; then
        echo \"QGA absent: tentative réparation via SSH root@\$ip\"
        sshpass -p \"\$root_password\" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \"root@\$ip\" \"\$repair_cmd\" || exit 22
        echo \"guest réparé via SSH: root/root + qemu-guest-agent + stress-ng + SSH\"
        exit 0
    fi
    echo \"QGA absent et réparation automatique impossible.\" >&2
    echo \"Si la VM est accessible par console, exécuter:\" >&2
    echo \"  qm terminal \$vmid\" >&2
    echo \"Puis dans la VM:\" >&2
    echo \"  cloud-init status --long\" >&2
    echo \"  journalctl -u cloud-init --no-pager -n 100\" >&2
    echo \"  systemctl status qemu-guest-agent\" >&2
    echo \"  apt-get update\" >&2
    echo \"  apt-get install -y qemu-guest-agent stress-ng openssh-server\" >&2
    echo \"  systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true; systemctl enable --now qemu-guest-agent.socket 2>/dev/null || true; systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null\" >&2
    echo \"Pour automatiser sans QGA, installer sshpass sur le nœud Proxmox ou fournir une image/template avec QGA préinstallé.\" >&2
    exit 21
fi
pid=\$(printf '%s' \"\$pid_json\" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"pid\", \"\"))' 2>/dev/null || true)
test -n \"\$pid\" || exit 22
for _ in \$(seq 1 180); do
    st=\$(qm guest exec-status \"\$vmid\" \"\$pid\" 2>/dev/null || true)
    printf '%s' \"\$st\" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get(\"exited\") else 1)' 2>/dev/null || { sleep 1; continue; }
    code=\$(printf '%s' \"\$st\" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"exitcode\", 1))' 2>/dev/null || echo 1)
    test \"\$code\" = 0 || { printf '%s' \"\$st\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"out-data\", \"\") + d.get(\"err-data\", \"\"), end=\"\")' 2>/dev/null || true; exit \"\$code\"; }
    echo \"guest réparé: root/root + qemu-guest-agent + stress-ng + SSH\"
    exit 0
done
echo \"réparation guest timeout after 180s\" >&2
exit 23"
}

ensure_template_remote() {
    local node="$1"
    local prepared_image candidate_prepared
    [[ -n "$TEMPLATE_ID" ]] || return 0
    if ssh_node "$node" "qm config '$TEMPLATE_ID' 2>/dev/null | grep -q '^template: 1'"; then
        if ! ssh_node "$node" "qm config '$TEMPLATE_ID' 2>/dev/null | grep -q 'omega_template_prepared=1'"; then
            fail "template $TEMPLATE_ID existe déjà mais n'est pas marqué préparé Omega. Supprimer/recréer le template ou choisir un autre --template-id."
        fi
        echo "Template $TEMPLATE_ID déjà disponible sur $node"
        prepare_template_for_clone "$node"
        return 0
    fi
    cleanup_incomplete_template_remote "$node"
    if ssh_node "$node" "qm status '$TEMPLATE_ID' >/dev/null 2>&1"; then
        fail "VM $TEMPLATE_ID existe sur $node mais n'est pas un template"
    fi
    [[ -n "$IMAGE_REMOTE" ]] || fail "--image-remote requis pour créer le template $TEMPLATE_ID"
    ssh_node "$node" "test -f '$IMAGE_REMOTE'" || fail "image absente sur $node pour créer le template: $IMAGE_REMOTE"
    if $IMAGE_PREPARED || [[ "$(basename "$IMAGE_REMOTE")" == *prepared* ]]; then
        prepared_image="$IMAGE_REMOTE"
        echo "Image distante déjà préparée détectée: $prepared_image"
    else
        candidate_prepared="$(dirname "$IMAGE_REMOTE")/omega-template-${TEMPLATE_ID}-prepared.qcow2"
        if ssh_node "$node" "test -f '$candidate_prepared'"; then
            prepared_image="$candidate_prepared"
            echo "Image préparée existante détectée: $prepared_image"
        else
            prepared_image="$candidate_prepared"
            echo "Préparation offline de l'image template Omega sur $node"
            ssh_node "$node" "set -e
if ! command -v virt-customize >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y libguestfs-tools || {
        echo 'ERREUR: libguestfs-tools/virt-customize impossible à installer sur ce nœud.' >&2
        echo 'Solution rapide: préparer omega-template-${TEMPLATE_ID}-prepared.qcow2 sur la machine dev puis la copier dans le dossier image du cluster.' >&2
        exit 31
    }
fi
rm -f '$prepared_image'
cp --reflink=auto '$IMAGE_REMOTE' '$prepared_image' 2>/dev/null || cp '$IMAGE_REMOTE' '$prepared_image'
virt-customize -a '$prepared_image' \
    --install qemu-guest-agent,stress-ng,openssh-server \
    --root-password password:'$ROOT_PASSWORD' \
    --run-command 'systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true' \
    --run-command 'systemctl enable qemu-guest-agent.socket 2>/dev/null || true' \
    --run-command 'systemctl enable qemu-guest-agent.service 2>/dev/null || true' \
    --run-command 'cloud-init clean --logs || true' \
    --run-command 'rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* /var/lib/systemd/network/* 2>/dev/null || true' \
    --run-command 'rm -f /var/lib/dbus/machine-id' \
    --run-command 'truncate -s 0 /etc/machine-id'"
        fi
    fi
    echo "Création template Omega préparé $TEMPLATE_ID sur $node depuis $prepared_image"
    ssh_node "$node" "qm create '$TEMPLATE_ID' \
        --name omega-cloud-template \
        --ostype l26 \
        --machine q35 \
        --agent enabled=1 \
        --cpu kvm64 \
        --sockets 1 \
        --cores 1 \
        --memory 1024 \
        --balloon 512 \
        --hotplug cpu,disk,network \
        --numa 0 \
        --scsihw virtio-scsi-single \
        --net0 virtio,bridge='${BRIDGE}',firewall=0 \
        --serial0 socket \
        --vga serial0 \
        --description omega_template_prepared=building \
        --tags omega-template"
    import_template_disk_remote "$node" "$prepared_image" || fail "import disque template $TEMPLATE_ID impossible sur $node vers $STORAGE"
    ssh_node "$node" "qm set '$TEMPLATE_ID' \
        --scsi0 '${STORAGE}:vm-${TEMPLATE_ID}-disk-0,discard=on,iothread=1,ssd=1' \
        --boot order=scsi0"
    if [[ -n "$EFFECTIVE_SSHKEY_REMOTE" ]]; then
        ssh_node "$node" "test -f '$EFFECTIVE_SSHKEY_REMOTE' && qm set '$TEMPLATE_ID' --sshkeys '$EFFECTIVE_SSHKEY_REMOTE' || true"
    fi
    ssh_node "$node" "qm set '$TEMPLATE_ID' --delete hookscript >/dev/null 2>&1 || true
qm set '$TEMPLATE_ID' --delete scsi1 >/dev/null 2>&1 || true
qm set '$TEMPLATE_ID' --tags omega-template >/dev/null
qm set '$TEMPLATE_ID' --description omega_template_prepared=1 >/dev/null"
    ssh_node "$node" "qm template '$TEMPLATE_ID'"
    prepare_template_for_clone "$node"
    echo "Template $TEMPLATE_ID prêt avec qemu-guest-agent, stress-ng et root/root"
}

select_template_node() {
    local node candidate_prepared can_install
    [[ -n "$TEMPLATE_ID" ]] || return 0
    candidate_prepared="$(dirname "$IMAGE_REMOTE")/omega-template-${TEMPLATE_ID}-prepared.qcow2"

    for node in "${CLUSTER_NODES[@]}"; do
        if ssh_node "$node" "test -f '$IMAGE_REMOTE' && case \"\$(basename '$IMAGE_REMOTE')\" in *prepared*) exit 0;; *) exit 1;; esac" 2>/dev/null; then
            echo "$node"
            return 0
        fi
        if ssh_node "$node" "test -f '$candidate_prepared'" 2>/dev/null; then
            echo "$node"
            return 0
        fi
    done

    if $IMAGE_PREPARED; then
        for node in "${CLUSTER_NODES[@]}"; do
            if ssh_node "$node" "test -f '$IMAGE_REMOTE'" 2>/dev/null; then
                echo "$node"
                return 0
            fi
        done
    fi

    if [[ -n "${source_image_node:-}" ]]; then
        echo "$source_image_node"
        return 0
    fi

    for node in "${CLUSTER_NODES[@]}"; do
        if ssh_node "$node" "command -v virt-customize >/dev/null 2>&1" 2>/dev/null; then
            echo "$node"
            return 0
        fi
    done

    for node in "${CLUSTER_NODES[@]}"; do
        can_install="$(ssh_node "$node" "apt-get -s install libguestfs-tools >/dev/null 2>&1 && echo yes || true" 2>/dev/null || true)"
        if [[ "$can_install" == "yes" ]]; then
            echo "$node"
            return 0
        fi
    done

    return 1
}

echo "[1/7] Verification SSH vers ${REMOTE}"
ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$REMOTE" "hostname; command -v qm >/dev/null; command -v pvesm >/dev/null"

mapfile -t CLUSTER_NODES < <(discover_nodes)
[[ "${#CLUSTER_NODES[@]}" -gt 0 ]] || fail "aucun nœud Proxmox découvert"
filter_provision_nodes
[[ "${#CLUSTER_NODES[@]}" -gt 0 ]] || fail "aucun nœud Proxmox éligible au provisioning VM (qm/pvesm fonctionnels + /dev/kvm)"
echo "Nœuds de provisioning: ${CLUSTER_NODES[*]}"

echo "[2/7] Verification stockage Proxmox: ${STORAGE}"
ssh "${SSH_OPTS[@]}" "$REMOTE" "pvesm status | awk 'NR==1 || \$1==\"${STORAGE}\" {print}'; pvesm status | awk 'NR>1 {print \$1}' | grep -qx '${STORAGE}'"

echo "[3/7] Synchronisation du script de creation sur tous les nœuds"
trap restore_provisioning_guards EXIT
EFFECTIVE_SSHKEY_REMOTE="$SSHKEY_REMOTE"
if [[ -n "$SSH_KEY" && -f "${SSH_KEY}.pub" ]]; then
    EFFECTIVE_SSHKEY_REMOTE="/root/.ssh/omega_lab_vm.pub"
fi
for node in "${CLUSTER_NODES[@]}"; do
    echo "  -> $node"
    ssh_node "$node" "mkdir -p '$REMOTE_DIR' /root/.ssh; command -v qm >/dev/null; command -v pvesm >/dev/null"
    ssh_node "$node" "command -v sshpass >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y sshpass) || echo 'WARN: sshpass absent; fallback SSH invité indisponible sur ce nœud' >&2"
    if [[ -n "$TEMPLATE_ID" ]] && ! $IMAGE_PREPARED; then
        ssh_node "$node" "command -v virt-customize >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y libguestfs-tools) || echo 'WARN: libguestfs-tools absent; ce nœud ne pourra pas préparer le template offline' >&2"
    fi
    scp_node "$CREATE_SCRIPT" "$node" "$REMOTE_CREATE"
    if [[ "$EFFECTIVE_SSHKEY_REMOTE" != "$SSHKEY_REMOTE" ]]; then
        scp_node "${SSH_KEY}.pub" "$node" "$EFFECTIVE_SSHKEY_REMOTE"
    fi
    ssh_node "$node" "chmod +x '$REMOTE_CREATE'"
done

echo "Pause auto-hook/wrapper Omega pendant le provisioning"
for node in "${CLUSTER_NODES[@]}"; do
    pause_hookscript_watcher "$node"
    pause_kvm_wrapper "$node"
done

echo "[4/7] Verification image/template"
remote_image_dir="$(dirname "$IMAGE_REMOTE")"
source_image_node=""
if [[ -n "$IMAGE_REMOTE" ]]; then
    for node in "${CLUSTER_NODES[@]}"; do
        if ssh_node "$node" "test -f '$IMAGE_REMOTE'"; then
            source_image_node="$node"
            break
        fi
    done
    if [[ -z "$source_image_node" && -z "$IMAGE_LOCAL" ]]; then
        fail "image distante absente sur tous les nœuds et --image-local non fourni: $IMAGE_REMOTE"
    fi
    if [[ -n "$IMAGE_LOCAL" ]]; then
        [[ -f "$IMAGE_LOCAL" ]] || fail "image locale introuvable: $IMAGE_LOCAL"
    fi
fi

if [[ -n "$TEMPLATE_ID" ]]; then
    template_node="$(select_template_node)" || fail "aucun nœud ne peut préparer le template: image préparée absente et virt-customize/libguestfs-tools indisponible sur tous les nœuds"
    echo "Nœud template retenu: $template_node"
    if ! ssh_node "$template_node" "qm status '$TEMPLATE_ID' >/dev/null 2>&1"; then
        template_has_image="$(ssh_node "$template_node" "test -f '$IMAGE_REMOTE' && echo yes" 2>/dev/null || true)"
        if [[ -n "$IMAGE_REMOTE" && "$template_has_image" != "yes" ]]; then
            echo "Image absente sur $template_node; copie nécessaire pour créer le template"
            ssh_node "$template_node" "mkdir -p '$remote_image_dir'"
            if [[ -n "$IMAGE_LOCAL" ]]; then
                scp_node "$IMAGE_LOCAL" "$template_node" "$IMAGE_REMOTE"
            else
                ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${source_image_node}" "cat '$IMAGE_REMOTE'" | \
                    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${template_node}" "cat > '$IMAGE_REMOTE'"
            fi
        fi
    fi
    ensure_template_remote "$template_node"
else
    for node in "${CLUSTER_NODES[@]}"; do
        if ssh_node "$node" "test -f '$IMAGE_REMOTE'"; then
            ssh_node "$node" "ls -lh '$IMAGE_REMOTE'"
            continue
        fi
        echo "Image absente sur $node; copie vers ${DEPLOY_USER}@${node}:${IMAGE_REMOTE}"
        ssh_node "$node" "mkdir -p '$remote_image_dir'"
        if [[ -n "$IMAGE_LOCAL" ]]; then
            scp_node "$IMAGE_LOCAL" "$node" "$IMAGE_REMOTE"
        else
            ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${source_image_node}" \
                "cat '$IMAGE_REMOTE'" | \
                ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" \
                "cat > '$IMAGE_REMOTE'"
        fi
        ssh_node "$node" "ls -lh '$IMAGE_REMOTE'"
    done
fi

IFS=',' read -ra VMID_ARR <<< "$VMIDS"
declare -A VM_TARGET_NODE=()
declare -A VM_PREEXISTING=()

create_one_vm() {
    local vmid="$1" node="$2" profile p_cores p_memory p_balloon p_gpu p_sockets existing_node existing_ssh_node
    local name node_cap profile_max_cores adopt_existing=false
    node_cap="$(node_max_vcpus "$node")"
    profile_max_cores="$CORES"
    if [[ "$profile_max_cores" -gt "$node_cap" ]]; then
        profile_max_cores="$node_cap"
    fi
    [[ "$profile_max_cores" -ge 2 ]] || profile_max_cores=2
    IFS=',' read -r p_cores p_memory p_balloon p_gpu < <(profile_for_vmid "$profile_max_cores" "$MEMORY" "$BALLOON" "$GPU_VRAM_MIB")
    p_sockets="$(omega_create_sockets)"
    name="${NAME_PREFIX}-${vmid}"
    existing_node="$(vm_cluster_node "$vmid" || true)"
    if [[ -n "$existing_node" ]]; then
        VM_TARGET_NODE[$vmid]="$existing_node"
        VM_PREEXISTING[$vmid]=1
        node="$(node_ssh_target "$existing_node")"
        adopt_existing=true
        echo "VM $vmid existe déjà sur $existing_node — adoption/réapplication du profil Omega"
        cleanup_cloudinit_remote "$node" "$vmid"
    else
        VM_TARGET_NODE[$vmid]="$node"
        if [[ -n "$TEMPLATE_ID" && "$node" != "$template_node" ]]; then
            clone_template_to_node "$template_node" "$node" "$vmid" "$name"
        else
            cleanup_cloudinit_remote "$node" "$vmid"
        fi
    fi

    # ALLOCATION DENSE : on utilise toutes les adresses libres de VM_IP_MIN..VM_IP_MAX
    # (.2 à .253). L'IP n'est PLUS dérivée du VMID — chaque VM prend la plus basse adresse
    # libre du /24. Si la VM possède déjà une IP en plage (adoption), on la conserve.
    local ipconfig0_arg="ip=dhcp"
    local nameserver_arg="8.8.8.8"
    if [[ -n "$VM_IP_PREFIX" && -n "$VM_GATEWAY" ]]; then
        local want_ip
        want_ip="$(alloc_free_ip "$vmid")" || fail "Plus aucune adresse libre dans ${VM_IP_PREFIX}.${VM_IP_MIN}-${VM_IP_MAX} pour VM $vmid"
        ipconfig0_arg="ip=${want_ip}/${VM_NETMASK},gw=${VM_GATEWAY}"
        [[ -n "$VM_DNS_IP" ]] && nameserver_arg="$VM_DNS_IP"
    fi

    local create_args=(
        --vmid "$vmid"
        --name "$NAME_PREFIX"
        --storage "$STORAGE"
        --bridge "$BRIDGE"
        --sshkey "$EFFECTIVE_SSHKEY_REMOTE"
        --memory "$p_memory"
        --balloon "$p_balloon"
        --cores "$p_cores"
        --sockets "$p_sockets"
        --vcpus "$VCPUS"
        --disk-max-gib "$DISK_MAX_GIB"
        --gpu-vram-mib "$p_gpu"
        --root-password "$ROOT_PASSWORD"
        --ipconfig0 "$ipconfig0_arg"
        --nameserver "$nameserver_arg"
        --bootstrap-guest
    )
    [[ -n "$VM_VLAN_TAG" ]] && create_args+=(--vlan-tag "$VM_VLAN_TAG")
    if [[ -n "$TEMPLATE_ID" ]]; then
        create_args+=(--template-id "$TEMPLATE_ID")
        create_args+=(--template-prepared)
        $LINKED_CLONE && create_args+=(--linked-clone)
        { [[ "$node" != "$template_node" ]] || $adopt_existing; } && create_args+=(--adopt-existing)
    else
        create_args+=(--image "$IMAGE_REMOTE")
    fi
    $START && create_args+=(--start)
    echo "VM $vmid -> nœud=$node profil: vcpus=${VCPUS}/$((p_cores * p_sockets)) RAM=${p_balloon}/${p_memory}MiB GPU=${p_gpu}MiB"
    ssh_node "$node" "cd /opt/omega-remote-paging && '$REMOTE_CREATE'$(quote_args "${create_args[@]}")"
}

# Installe les proxys de sécurité GANDAL DANS la VM, via QGA (la VM télécharge le
# bundle depuis le deb-server LAN puis installe — hors-ligne, certs mTLS, services
# auto). ADDITIF et NON BLOQUANT : tout échec est seulement journalisé.
install_security_proxies_remote() {
    local node="$1" vmid="$2" i
    $INSTALL_SECURITY_PROXIES || return 0
    echo "  → proxys de sécurité GANDAL (VM $vmid)…"
    # Attendre que le QGA réponde (boot + cloud-init réseau) — borné, best-effort.
    # Indispensable en mode --resource-only où aucun bootstrap QGA n'a précédé.
    for i in $(seq 1 "${OMEGA_SECPROXY_QGA_WAIT_TRIES:-30}"); do
        ssh_node "$node" "qm agent '$vmid' ping" >/dev/null 2>&1 && break
        sleep 4
    done
    # Déclenchement via systemd-run (unité transitoire PID 1) et NON nohup : l'install
    # sature le 1-vCPU et peut faire redémarrer qemu-ga ; un nohup, enfant du cgroup de
    # qemu-ga, mourrait avec lui. systemd-run survit. --collect nettoie l'unité ensuite.
    ssh_node "$node" "
        qm guest exec '$vmid' --timeout 30 -- bash -lc 'systemd-run --unit=secproxy-install --collect --no-block --setenv=VM_ID=${vmid} --setenv=DEB_SERVER=${SECURITY_BUNDLE_URL} --setenv=ANALYSEUR_HOST=${SECURITY_ANALYSEUR_HOST} --setenv=ANALYSEUR_PORT=${SECURITY_ANALYSEUR_PORT} --setenv=CHIFFREUR_URL=${SECURITY_CHIFFREUR_URL} bash -c \"curl -fsS ${SECURITY_BUNDLE_URL}/install-security-proxies.sh -o /tmp/sp.sh && bash /tmp/sp.sh >/var/log/sec-proxy-install.log 2>&1\"' >/dev/null 2>&1
    " 2>/dev/null \
        && echo "    proxys de sécurité : installation lancée (chiffreur :8400 + analyseur)" \
        || echo "    ⚠️  proxys de sécurité : déclenchement échoué (VM créée quand même)"
    return 0
}

validate_one_vm() {
    local vmid="$1" node
    node="$(vm_cluster_node "$vmid" || true)"
    [[ -n "$node" ]] || { echo "VM $vmid introuvable dans le cluster" >&2; return 1; }
    echo "=== VM $vmid sur $node ==="
    node="$(node_ssh_target "$node")"
    validate_vm_static_remote "$node" "$vmid" || return 1
    if $RESOURCE_ONLY; then
        echo "guest check ignoré: validation ressources uniquement"
        # Même en resource-only (chemin du gateway Web GANDAL), on GARANTIT l'accès
        # SSH root (pwd + drop-in + restart ssh) puis on installe les proxys. Best-effort.
        if $START; then
            ensure_ssh_root_remote "$node" "$vmid"
            install_security_proxies_remote "$node" "$vmid"
        fi
    elif $START; then
        wait_qga_and_bootstrap_remote "$node" "$vmid" "${OMEGA_PROVISION_QGA_WAIT_SECS:-20}"
        install_security_proxies_remote "$node" "$vmid"
    fi
}

recreate_one_vm() {
    local vmid="$1" node="$2" current_node
    current_node="$(vm_cluster_node "$vmid" || true)"
    if [[ -n "$current_node" ]]; then
        destroy_vm_remote "$(node_ssh_target "$current_node")" "$vmid"
        wait_vm_absent "$vmid" 180 || fail "VM $vmid toujours visible après destruction; arrêt pour éviter d'adopter une VM ancienne"
    fi
    unset 'VM_PREEXISTING[$vmid]'
    create_one_vm "$vmid" "$node"
}

ensure_vm_conform_now() {
    local vmid="$1" preferred_node="$2" node rc
    if validate_one_vm "$vmid"; then
        return 0
    fi
    rc=$?
    echo "VM $vmid: validation échouée rc=$rc"

    node="$(vm_cluster_node "$vmid" || true)"
    if [[ -n "$node" && "$rc" -ne 1 ]]; then
        echo "VM $vmid: tentative réparation invitée via QGA, puis SSH si QGA absent"
        if repair_guest_remote "$(node_ssh_target "$node")" "$vmid" && validate_one_vm "$vmid"; then
            return 0
        fi
    fi

    $RECREATE_BAD || return "$rc"
    echo "VM $vmid non conforme — suppression/recréation immédiate"
    recreate_one_vm "$vmid" "$preferred_node"
    validate_one_vm "$vmid"
}

echo "[5/7] Création distribuée des VMs Omega"
bad_vmids=()
declare -A VM_TARGET_NODE=()

# Distribution contrôlée : OMEGA_VM_NODE_DISTRIBUTION="IP:max,IP:max,..."
# Exemple : "192.168.123.100:1,192.168.123.101:2,192.168.123.102:2" (1 Emilia/2 Ram/2 Rem)
# Nœuds absents de la liste → OMEGA_VM_NODE_DEFAULT_MAX VMs chacun (défaut: 2)
#
# PLACEMENT CONVERGENT (corrigé) : on compte d'abord les VMs omega DÉJÀ présentes sur
# chaque nœud (occupation réelle du cluster), puis chaque NOUVELLE VM va sur le nœud le
# plus en-dessous de son quota. Ainsi la cible (1 Emilia/2 Ram/2 Rem) est respectée quel
# que soit le nombre de VMs créées d'un coup ou une par une. Avant, _node_count repartait
# de 0 → toute création unitaire tombait sur emilia (1er nœud à quota libre). Bug corrigé.
declare -A _node_max=()
declare -A _node_count=()
for node in "${CLUSTER_NODES[@]}"; do _node_count["$node"]=0; done

if [[ -n "${OMEGA_VM_NODE_DISTRIBUTION:-}" ]]; then
    IFS=',' read -ra _dist_entries <<< "$OMEGA_VM_NODE_DISTRIBUTION"
    for entry in "${_dist_entries[@]}"; do
        _n="${entry%%:*}"; _m="${entry##*:}"
        [[ "$_m" =~ ^[0-9]+$ ]] && _node_max["$_n"]="$_m"
    done
fi
_default_max="${OMEGA_VM_NODE_DEFAULT_MAX:-2}"

# 1) Occupation actuelle : compter les VMs omega vivantes par nœud éligible
#    (inclut celles du batch déjà créées → elles seront adoptées sur place, pas re-placées).
while IFS=$'\t' read -r _evmid _enode; do
    [[ -n "$_enode" ]] || continue
    _essh="$(node_ssh_target "$_enode")"
    [[ -n "${_node_count[$_essh]+x}" ]] || continue   # nœud hors cluster provisionnable → ignoré
    _node_count["$_essh"]=$(( ${_node_count[$_essh]} + 1 ))
done < <(list_omega_vms_by_node)

# 2) Assigner chaque VMID. Une VM déjà existante reste sur son nœud (déjà comptée en 1).
#    Une nouvelle VM va sur le nœud à plus forte capacité restante (max-count) ; à égalité,
#    le nœud au quota le plus élevé l'emporte → emilia (quota 1) est servi en DERNIER.
for vmid in "${VMID_ARR[@]}"; do
    [[ -n "$vmid" ]] || continue
    _existing="$(vm_cluster_node "$vmid" || true)"
    if [[ -n "$_existing" ]]; then
        VM_TARGET_NODE["$vmid"]="$(node_ssh_target "$_existing")"
        continue
    fi
    assigned=""; _best_slack=-2147483648; _best_max=-1
    for node in "${CLUSTER_NODES[@]}"; do
        _max="${_node_max[$node]:-$_default_max}"
        _slack=$(( _max - ${_node_count[$node]:-0} ))
        if [[ "$_slack" -gt "$_best_slack" ]] || \
           { [[ "$_slack" -eq "$_best_slack" ]] && [[ "$_max" -gt "$_best_max" ]]; }; then
            _best_slack="$_slack"; _best_max="$_max"; assigned="$node"
        fi
    done
    [[ -n "$assigned" ]] || assigned="${CLUSTER_NODES[0]}"
    VM_TARGET_NODE["$vmid"]="$assigned"
    _node_count["$assigned"]=$(( ${_node_count[$assigned]:-0} + 1 ))
done

# Récapitulatif d'occupation cible (existant + nouveau) par nœud vs quota.
echo "  Occupation cible par nœud (VMs omega vivantes, quota):"
for node in "${CLUSTER_NODES[@]}"; do
    echo "    $node : ${_node_count[$node]:-0}/${_node_max[$node]:-$_default_max}"
done

# Afficher la distribution choisie
echo "  Distribution VMs:"
for node in "${CLUSTER_NODES[@]}"; do
    vms_on_node=()
    for vmid in "${VMID_ARR[@]}"; do
        [[ "${VM_TARGET_NODE[$vmid]:-}" == "$node" ]] && vms_on_node+=("$vmid")
    done
    [[ "${#vms_on_node[@]}" -gt 0 ]] && echo "    $node : ${vms_on_node[*]}"
done

idx=0
for vmid in "${VMID_ARR[@]}"; do
    [[ -n "$vmid" ]] || continue
    node="${VM_TARGET_NODE[$vmid]}"
    if ! create_one_vm "$vmid" "$node"; then
        echo "VM $vmid: création/adoption initiale échouée — recréation immédiate"
        if ! recreate_one_vm "$vmid" "$node"; then
            bad_vmids+=("$vmid")
        fi
    fi
    idx=$((idx + 1))
done

if [[ "${#bad_vmids[@]}" -gt 0 ]]; then
    fail "VMs non créées après recréation: ${bad_vmids[*]}"
fi

if $RESOURCE_ONLY; then
    echo "[6/7] Validation conformité ressources uniquement"
else
    echo "[6/7] Validation conformité + bootstrap/réparation invité"
fi
bad_vmids=()
for vmid in "${VMID_ARR[@]}"; do
    [[ -n "$vmid" ]] || continue
    if ! ensure_vm_conform_now "$vmid" "${VM_TARGET_NODE[$vmid]}"; then
        bad_vmids+=("$vmid")
    fi
done

[[ "${#bad_vmids[@]}" -eq 0 ]] || fail "VMs toujours non conformes après réparation/recréation: ${bad_vmids[*]}"

echo "[7/7] Résumé"
if $RESOURCE_ONLY; then
    echo "Provisioning Omega terminé: toutes les VMs sont conformes côté ressources Omega."
else
    echo "Provisioning Omega terminé: toutes les VMs sont conformes, root/root, qemu-guest-agent et stress-ng OK."
fi
