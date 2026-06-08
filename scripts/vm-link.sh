#!/usr/bin/env bash
# vm-link.sh — Relie ou isole des VMs Omega via iptables sur les nœuds Proxmox.
#
# L'isolation est gérée par iptables FORWARD (chaîne OMEGA-ISOLATION) sur chaque
# nœud, initialisée par vm-isolation.sh. Ce script ajoute/retire des règles ACCEPT
# pour des paires ou groupes de VMs spécifiques.
#
# Usage — paire :
#   scripts/vm-link.sh --vmid-a 3000 --vmid-b 3001 --enable
#   scripts/vm-link.sh --vmid-a 3000 --vmid-b 3001 --disable
#   scripts/vm-link.sh --ip-a 10.50.30.101 --ip-b 10.50.30.102 --enable
#
# Usage — groupe (maillage complet) :
#   scripts/vm-link.sh --group 3000,3001,3002 --enable
#   scripts/vm-link.sh --group 3000,3001,3002 --group-name backend --enable
#   scripts/vm-link.sh --group-name backend --disable
#
# Usage — listing :
#   scripts/vm-link.sh --list
#   scripts/vm-link.sh --list --vmid 3000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

fail()  { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

VMID_A=""; VMID_B=""; IP_A=""; IP_B=""
GROUP_CSV=""; GROUP_NAME=""; ACTION=""; FILTER_VMID=""
SSH_KEY="${SSH_KEY:-}"
CONTROLLER="${OMEGA_CONTROLLER:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
IP_PREFIX="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}"
IP_START="${OMEGA_NET_VM_IP_START:-101}"
NODES_CSV="${OMEGA_NODES:-}"
BRIDGE="${OMEGA_NET_VM_BRIDGE:-vmbr1}"
# Chemin prod (après déploiement) ou dev (répertoire source)
ISOLATION_SCRIPT="/opt/omega-remote-paging/scripts/vm-isolation.sh"
[[ -x "$ISOLATION_SCRIPT" ]] || ISOLATION_SCRIPT="${SCRIPT_DIR}/vm-isolation.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid-a)     VMID_A="$2"; shift 2 ;;
        --vmid-b)     VMID_B="$2"; shift 2 ;;
        --ip-a)       IP_A="$2"; shift 2 ;;
        --ip-b)       IP_B="$2"; shift 2 ;;
        --group)      GROUP_CSV="$2"; shift 2 ;;
        --group-name) GROUP_NAME="$2"; shift 2 ;;
        --enable)     ACTION="enable"; shift ;;
        --disable)    ACTION="disable"; shift ;;
        --list)       ACTION="list"; shift ;;
        --vmid)       FILTER_VMID="$2"; shift 2 ;;
        --nodes)      NODES_CSV="$2"; shift 2 ;;
        -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$ACTION" ]] || fail "Spécifier --enable, --disable ou --list"
[[ -n "$NODES_CSV" ]] || fail "OMEGA_NODES vide."

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

node_ssh() { ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${1}" "${@:2}"; }

# Résoudre IP depuis VMID via QGA ou calcul positionnel
resolve_ip() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$v"; return; }
    [[ "$v" =~ ^[0-9]+$ ]] || fail "VMID ou IP invalide: $v"
    # Essayer QGA d'abord
    local ip
    IFS=',' read -ra _nodes <<< "$NODES_CSV"
    for _n in "${_nodes[@]}"; do
        ip="$(node_ssh "$_n" "qm guest cmd $v network-get-interfaces 2>/dev/null \
            | python3 -c \"import json,sys
data=json.load(sys.stdin)
for iface in data:
    for addr in iface.get('ip-addresses',[]):
        ip=addr.get('ip-address','')
        if ip and not ip.startswith('127.') and not ip.startswith('fe80') and ':' not in ip:
            print(ip); exit()
\"" 2>/dev/null || true)"
        [[ -n "$ip" ]] && { echo "$ip"; return; }
    done
    # Fallback positionnel
    echo "${IP_PREFIX}.$((IP_START + v - ${OMEGA_NET_VM_VMID_BASE:-3000}))"
}

# Appliquer une action sur tous les nœuds
all_nodes_do() {
    local action="$1" ip_a="$2" ip_b="$3"
    IFS=',' read -ra _nodes <<< "$NODES_CSV"
    for _n in "${_nodes[@]}"; do
        node_ssh "$_n" "
            [[ -x '$ISOLATION_SCRIPT' ]] || { echo 'vm-isolation.sh absent sur $_n' >&2; exit 1; }
            bash '$ISOLATION_SCRIPT' --action $action --ip-a '$ip_a' --ip-b '$ip_b' --bridge '$BRIDGE'
            bash '$ISOLATION_SCRIPT' --action save --bridge '$BRIDGE'
        " 2>/dev/null || true
    done
}

all_pairs() {
    local -a ips=("$@"); local n="${#ips[@]}"
    for (( i=0; i<n-1; i++ )); do
        for (( j=i+1; j<n; j++ )); do echo "${ips[$i]} ${ips[$j]}"; done
    done
}

# Résolution
[[ -n "$VMID_A" && -z "$IP_A" ]] && { IP_A="$(resolve_ip "$VMID_A")"; info "VMID ${VMID_A} → ${IP_A}"; }
[[ -n "$VMID_B" && -z "$IP_B" ]] && { IP_B="$(resolve_ip "$VMID_B")"; info "VMID ${VMID_B} → ${IP_B}"; }

IS_GROUP=false; GROUP_IPS=(); GROUP_VMIDS=()
if [[ -n "$GROUP_CSV" ]]; then
    IS_GROUP=true
    IFS=',' read -ra members <<< "$GROUP_CSV"
    for m in "${members[@]}"; do
        m="$(echo "$m" | tr -d ' ')"
        GROUP_VMIDS+=("$m")
        GROUP_IPS+=("$(resolve_ip "$m")")
    done
    [[ ${#GROUP_IPS[@]} -ge 2 ]] || fail "--group requiert au moins 2 membres"
elif [[ -n "$GROUP_NAME" && "$ACTION" != "list" ]]; then
    IS_GROUP=true
fi

case "$ACTION" in
    enable)
        if $IS_GROUP && [[ ${#GROUP_IPS[@]} -ge 2 ]]; then
            local_n="${#GROUP_IPS[@]}"
            pairs_count=$(( local_n * (local_n - 1) / 2 ))
            info "Groupe '${GROUP_NAME:-anonyme}' — ${local_n} VMs → ${pairs_count} paires"
            while IFS=' ' read -r ip_a ip_b; do
                all_nodes_do allow "$ip_a" "$ip_b"
                echo "  créé : $ip_a ↔ $ip_b"
            done < <(all_pairs "${GROUP_IPS[@]}")
            ok "Groupe '${GROUP_NAME:-anonyme}' activé"
        elif [[ -n "$IP_A" && -n "$IP_B" ]]; then
            [[ "$IP_A" != "$IP_B" ]] || fail "IPs identiques"
            all_nodes_do allow "$IP_A" "$IP_B"
            ok "Lien ${IP_A} ↔ ${IP_B}"
        else
            fail "Fournir --vmid-a/b (paire) ou --group (groupe)"
        fi ;;

    disable)
        if $IS_GROUP && [[ ${#GROUP_IPS[@]} -ge 2 ]]; then
            while IFS=' ' read -r ip_a ip_b; do
                all_nodes_do deny "$ip_a" "$ip_b"
                echo "  supprimé : $ip_a ↔ $ip_b"
            done < <(all_pairs "${GROUP_IPS[@]}")
            ok "Groupe '${GROUP_NAME:-anonyme}' désactivé"
        elif [[ -n "$GROUP_NAME" ]]; then
            info "Suppression groupe '${GROUP_NAME}' par commentaire"
            IFS=',' read -ra _nodes <<< "$NODES_CSV"
            for _n in "${_nodes[@]}"; do
                node_ssh "$_n" "
                    iptables -L OMEGA-ISOLATION -n --line-numbers 2>/dev/null \
                        | grep '${GROUP_NAME}' \
                        | awk '{print \$1}' | sort -rn \
                        | xargs -I{} iptables -D OMEGA-ISOLATION {} 2>/dev/null || true
                    bash '$ISOLATION_SCRIPT' --action save
                " 2>/dev/null || true
            done
            ok "Groupe '${GROUP_NAME}' désactivé"
        elif [[ -n "$IP_A" && -n "$IP_B" ]]; then
            all_nodes_do deny "$IP_A" "$IP_B"
            ok "Lien ${IP_A} ↔ ${IP_B} supprimé"
        else
            fail "Fournir --vmid-a/b ou --group-name"
        fi ;;

    list)
        info "Liens / isolation actifs (backend auto OVS|iptables) :"
        IFS=',' read -ra _nodes <<< "$NODES_CSV"
        first_node="${_nodes[0]}"
        node_ssh "$first_node" "
            [[ -x '$ISOLATION_SCRIPT' ]] || { echo '  vm-isolation.sh absent'; exit 0; }
            bash '$ISOLATION_SCRIPT' --action list --bridge '$BRIDGE'
        " 2>/dev/null ;;
esac
