#!/usr/bin/env bash
# setup-network.sh — Configure le réseau privé VMs sur tous les nœuds Proxmox.
#
# Ce script crée vmbr1 (bridge VLAN-aware, sans port physique) sur chaque nœud.
# Il ne touche PAS à vmbr0 (réseau physique de management Proxmox).
#
# Architecture finale :
#   vmbr0  → uplink physique 192.168.123.x  (gestion Proxmox + WAN pfSense)
#   vmbr1  → bridge VLAN-aware interne      (LAN pfSense + toutes les VMs)
#             ├── VLAN 10 → zone management  10.50.10.0/24
#             ├── VLAN 20 → zone infra       10.50.20.0/24  (DNS, DHCP)
#             └── VLAN 30 → zone omega       10.50.30.0/24  (VMs de test)
#
# Prérequis : SSH sans mot de passe vers tous les nœuds (omega-lab.sh action [c]).
# Sécurité  : ne modifie que vmbr1 ; vmbr0 et le cluster Proxmox sont intacts.
#
# Usage :
#   scripts/setup-network.sh [--dry-run] [--force]
#
# Options :
#   --nodes CSV     Nœuds cibles. Défaut: OMEGA_NODES depuis cluster.conf.
#   --ssh-key PATH  Clé SSH privée.
#   --user USER     Utilisateur SSH. Défaut: root.
#   --dry-run       Affiche les commandes sans les exécuter.
#   --force         Réapplique même si vmbr1 existe déjà.
#   -h, --help      Aide.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

fail()  { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

NODES_CSV="${OMEGA_NODES:-}"
SSH_KEY="${SSH_KEY:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)   NODES_CSV="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --user)    DEPLOY_USER="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$NODES_CSV" ]] || fail "OMEGA_NODES vide. Configurer cluster.conf ou passer --nodes."

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

ssh_node() {
    local node="$1"; shift
    if $DRY_RUN; then
        echo "  [DRY-RUN] ssh ${DEPLOY_USER}@${node} $*"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "$@"
}

# Strophe à ajouter dans /etc/network/interfaces sur chaque nœud
VMBR1_STROPHE="
# vmbr1 — réseau privé VMs (VLAN-aware, pas de port physique)
# Géré par omega-remote-paging/scripts/setup-network.sh
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
"

setup_node() {
    local node="$1"
    info "=== Nœud $node ==="

    # Vérifier si vmbr1 existe déjà
    if ssh_node "$node" "grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null"; then
        if $FORCE; then
            warn "vmbr1 déjà présent — réapplication forcée"
        else
            ok "vmbr1 déjà présent sur $node — ignorer (--force pour réappliquer)"
            return 0
        fi
    fi

    # Sauvegarder /etc/network/interfaces
    ssh_node "$node" "cp /etc/network/interfaces /etc/network/interfaces.omega-backup-\$(date +%Y%m%d%H%M%S)" || true

    # Ajouter la strophe vmbr1 à la fin du fichier
    if $DRY_RUN; then
        echo "  [DRY-RUN] Ajout strophe vmbr1 dans /etc/network/interfaces"
    else
        ssh_node "$node" "cat >> /etc/network/interfaces" <<EOF
${VMBR1_STROPHE}
EOF
    fi

    # Monter l'interface sans reboot
    ssh_node "$node" "ifup vmbr1 2>/dev/null || ip link add vmbr1 type bridge && ip link set vmbr1 up" || \
        warn "$node : ifup vmbr1 a retourné une erreur (peut nécessiter ifreload -a ou reboot)"

    # Vérifier
    if ! $DRY_RUN; then
        if ssh_node "$node" "ip link show vmbr1 2>/dev/null | grep -q 'state UP\|UNKNOWN'"; then
            ok "$node : vmbr1 UP"
        else
            warn "$node : vmbr1 créé mais état inconnu — vérifier avec: ip link show vmbr1"
        fi
    fi

    # Firewall Proxmox cluster.fw (allow admin + gateway inbound)
    local pve_fw_dir="/etc/pve/firewall"
    local cluster_fw="${pve_fw_dir}/cluster.fw"
    local admin_net="${OMEGA_NODES%%,*}"
    admin_net="${admin_net%.*}.0/24"
    local gw_omega="${OMEGA_NET_ZONE_OMEGA_GW:-10.50.30.1}"
    local infra_net="${OMEGA_NET_ZONE_INFRA_NET:-10.50.20.0/24}"
    if ! $DRY_RUN; then
        ssh_node "$node" "
            mkdir -p '${pve_fw_dir}'
            cat > '${cluster_fw}' <<'CLFW'
[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source ${admin_net} -log nolog
IN ACCEPT -source ${gw_omega} -log nolog
IN ACCEPT -source ${infra_net} -log nolog
CLFW
            systemctl reload pve-firewall 2>/dev/null || true
        " 2>/dev/null || true
        ok "$node : cluster.fw pve-firewall configuré"
    fi

    # Isolation iptables inter-VMs (chaîne OMEGA-ISOLATION)
    local omega_subnet="${OMEGA_NET_ZONE_OMEGA_NET:-10.50.30.0/24}"
    local isolation_script="/opt/omega-remote-paging/scripts/vm-isolation.sh"
    if $DRY_RUN; then
        echo "  [DRY-RUN] Isolation iptables $omega_subnet"
    else
        # Copier et initialiser vm-isolation.sh
        scp "${SSH_OPTS[@]/#-o/-o}" "${SCRIPT_DIR}/vm-isolation.sh" \
            "${DEPLOY_USER}@${node}:${isolation_script}" 2>/dev/null || \
        scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/vm-isolation.sh" \
            "${DEPLOY_USER}@${node}:${isolation_script}" 2>/dev/null || true
        ssh_node "$node" "
            chmod +x '${isolation_script}' 2>/dev/null || true
            dpkg -s iptables-persistent >/dev/null 2>&1 || \
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
            bash '${isolation_script}' --action init --subnet '${omega_subnet}' 2>/dev/null
            bash '${isolation_script}' --action save 2>/dev/null
        " 2>/dev/null || true
        ok "$node : isolation iptables initialisée ($omega_subnet)"
    fi

    # Route vers le réseau privé VMs via pfSense
    local pfsense_wan="${OMEGA_NET_PFSENSE_WAN_IP:-}"
    local private_net="10.50.0.0/16"
    if [[ -n "$pfsense_wan" ]]; then
        if $DRY_RUN; then
            echo "  [DRY-RUN] Route $private_net via $pfsense_wan"
        else
            # Route immédiate (runtime)
            ssh_node "$node" "ip route add ${private_net} via ${pfsense_wan} 2>/dev/null || true"
            # Route persistante dans /etc/network/interfaces (post-up)
            ssh_node "$node" "
                iface_line='post-up ip route add ${private_net} via ${pfsense_wan} || true'
                pre_line='pre-down ip route del ${private_net} via ${pfsense_wan} || true'
                if ! grep -q '${private_net}' /etc/network/interfaces 2>/dev/null; then
                    # Trouver l'interface avec l'IP du nœud et y ajouter le post-up
                    node_iface=\$(ip route get ${pfsense_wan} 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if(\$i==\"dev\") print \$(i+1)}' | head -1)
                    if [[ -n \"\$node_iface\" ]]; then
                        sed -i \"/^iface \${node_iface} inet/a\\\\    \${iface_line}\\n    \${pre_line}\" /etc/network/interfaces 2>/dev/null || true
                    fi
                fi
            " 2>/dev/null || true
            ok "$node : route $private_net via $pfsense_wan ajoutée"
        fi
    fi
}

IFS=',' read -ra NODE_ARR <<< "$NODES_CSV"

info "Configuration vmbr1 sur ${#NODE_ARR[@]} nœud(s) : ${NODES_CSV}"
$DRY_RUN && warn "Mode DRY-RUN : aucune modification ne sera appliquée"
echo ""

for node in "${NODE_ARR[@]}"; do
    setup_node "$node" || warn "Erreur sur $node — poursuite des autres nœuds"
done

echo ""
info "Résumé vmbr1 :"
for node in "${NODE_ARR[@]}"; do
    state="$(ssh_node "$node" "ip link show vmbr1 2>/dev/null | awk '{print \$9}' | head -1" 2>/dev/null || echo "?")"
    printf "  %-22s  vmbr1=%s\n" "$node" "${state:-?}"
done

echo ""
info "Étapes suivantes :"
echo "  1) Créer la VM pfSense (VMID ${OMEGA_NET_PFSENSE_VMID:-2290}) :"
echo "       bash scripts/create-infra-vms.sh --pfsense"
echo "  2) Configurer pfSense : WAN=vmbr0 (${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}), LAN=vmbr1 (10.50.0.1)"
echo "  3) Créer la VM DNS (VMID ${OMEGA_NET_DNS_VMID:-2291}) :"
echo "       bash scripts/create-infra-vms.sh --dns"
echo "  4) Mettre à jour cluster.conf :"
echo "       OMEGA_NET_VM_BRIDGE=\"vmbr1\""
echo "       OMEGA_NET_VM_VLAN_TAG=\"30\""
echo "       OMEGA_NET_VM_IP_PREFIX=\"10.50.30\""
echo "       OMEGA_NET_VM_GATEWAY=\"10.50.30.1\""
echo "       OMEGA_NET_VM_DNS_IP=\"10.50.20.10\""
echo "  5) Re-provisionner les VMs : bash scripts/omega-lab.sh → [p]"
