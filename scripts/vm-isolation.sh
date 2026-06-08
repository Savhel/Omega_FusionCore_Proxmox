#!/usr/bin/env bash
# vm-isolation.sh — Gère l'isolation inter-VMs Omega sur le nœud Proxmox.
#
# Par défaut chaque VM est isolée : le trafic VLAN 30 entre VMs est bloqué,
# sauf vers/depuis la gateway (pfSense). Les liens VM↔VM s'ouvrent à la demande.
#
# DEUX BACKENDS, choisis AUTOMATIQUEMENT selon le type de bridge :
#   - OVS  (Open vSwitch) : règles OpenFlow sur le bridge (ovs-ofctl).
#                           iptables NE FONCTIONNE PAS sur OVS (trafic L2 commuté
#                           par OVS, jamais vu par FORWARD) → on isole en OpenFlow.
#   - Linux bridge        : chaîne iptables FORWARD OMEGA-ISOLATION.
#
# Modèle (identique sur les deux backends) :
#   - DROP tout trafic intra-subnet VM↔VM (IPv4 + ARP)
#   - ACCEPT vers/depuis la gateway (clients/nœuds atteignent les VMs via pfSense)
#   - ACCEPT par paire pour les liens explicites (priorité supérieure)
#
# Appelé par : create-omega-vm.sh, vm-link.sh, omega-lab.sh [n], provisioning.
#
# Usage :
#   vm-isolation.sh --action init  --subnet 10.50.30.0/24 [--bridge vmbr1] [--gateway 10.50.30.1]
#   vm-isolation.sh --action allow --ip-a 10.50.30.101 --ip-b 10.50.30.102 [--bridge vmbr1]
#   vm-isolation.sh --action deny  --ip-a 10.50.30.101 --ip-b 10.50.30.102 [--bridge vmbr1]
#   vm-isolation.sh --action list  [--bridge vmbr1]
#   vm-isolation.sh --action save  [--bridge vmbr1]   (persiste les règles)
#
# Doit être exécuté sur chaque nœud Proxmox (pas depuis la machine dev).

set -euo pipefail

CHAIN="OMEGA-ISOLATION"
ACTION=""
SUBNET=""
IP_A=""
IP_B=""
BRIDGE="${OMEGA_NET_VM_BRIDGE:-vmbr1}"
GATEWAY="${OMEGA_NET_VM_GATEWAY:-}"

# Priorités OpenFlow
PRIO_PAIR=100   # liens explicites VM↔VM (gagnent sur le drop)
PRIO_GW=60      # exemption gateway
PRIO_DROP=50    # drop intra-subnet par défaut

OVS_FLOW_DIR="/etc/omega"
OVS_FLOW_FILE="${OVS_FLOW_DIR}/ovs-isolation-${BRIDGE}.flows"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)  ACTION="$2"; shift 2 ;;
        --subnet)  SUBNET="$2"; shift 2 ;;
        --ip-a)    IP_A="$2"; shift 2 ;;
        --ip-b)    IP_B="$2"; shift 2 ;;
        --bridge)  BRIDGE="$2"; OVS_FLOW_FILE="${OVS_FLOW_DIR}/ovs-isolation-${BRIDGE}.flows"; shift 2 ;;
        --gateway) GATEWAY="$2"; shift 2 ;;
        *) echo "option inconnue: $1" >&2; exit 1 ;;
    esac
done

# Détection du backend : OVS si le bridge existe dans Open vSwitch, sinon Linux bridge.
is_ovs() { command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl br-exists "$BRIDGE" 2>/dev/null; }

derive_gw() {
    [[ -n "$GATEWAY" ]] && { echo "$GATEWAY"; return; }
    # Première IP du subnet (10.50.30.0/24 → 10.50.30.1)
    echo "$SUBNET" | sed 's|\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*/.*|\1.1|'
}

# ════════════════════════════════════════════════════════════════════════════
# Backend OVS (OpenFlow)
# ════════════════════════════════════════════════════════════════════════════
ovs_init() {
    [[ -n "$SUBNET" ]] || { echo "--subnet requis pour init" >&2; exit 1; }
    local gw; gw="$(derive_gw)"
    # Exemption gateway (IPv4 + ARP, deux sens) — clients/nœuds passent par là.
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_GW},ip,nw_dst=${gw},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_GW},ip,nw_src=${gw},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_GW},arp,arp_tpa=${gw},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_GW},arp,arp_spa=${gw},actions=NORMAL"
    # Drop intra-subnet VM↔VM (IPv4 + ARP)
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_DROP},ip,nw_src=${SUBNET},nw_dst=${SUBNET},actions=drop"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_DROP},arp,arp_spa=${SUBNET},arp_tpa=${SUBNET},actions=drop"
    echo "Isolation OVS initialisée sur ${BRIDGE} pour ${SUBNET} (gateway ${gw} exemptée)"
}

ovs_pair() {
    # $1 = NORMAL (allow) ou drop ; mais ici on ajoute toujours des ACCEPT @PRIO_PAIR
    local a="$1" b="$2"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_PAIR},ip,nw_src=${a},nw_dst=${b},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_PAIR},ip,nw_src=${b},nw_dst=${a},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_PAIR},arp,arp_spa=${a},arp_tpa=${b},actions=NORMAL"
    ovs-ofctl add-flow "$BRIDGE" "priority=${PRIO_PAIR},arp,arp_spa=${b},arp_tpa=${a},actions=NORMAL"
    echo "Lien OVS autorisé: ${a} ↔ ${b}"
}

ovs_unpair() {
    local a="$1" b="$2"
    # del-flows matche par champs (sans --strict) ; on retire les 4 flows de la paire.
    ovs-ofctl del-flows "$BRIDGE" "ip,nw_src=${a},nw_dst=${b}" 2>/dev/null || true
    ovs-ofctl del-flows "$BRIDGE" "ip,nw_src=${b},nw_dst=${a}" 2>/dev/null || true
    ovs-ofctl del-flows "$BRIDGE" "arp,arp_spa=${a},arp_tpa=${b}" 2>/dev/null || true
    ovs-ofctl del-flows "$BRIDGE" "arp,arp_spa=${b},arp_tpa=${a}" 2>/dev/null || true
    echo "Lien OVS supprimé: ${a} ↔ ${b}"
}

ovs_list() {
    echo "=== Flows isolation OMEGA (bridge ${BRIDGE}) ==="
    ovs-ofctl dump-flows "$BRIDGE" 2>/dev/null \
        | grep -E "priority=(${PRIO_DROP}|${PRIO_GW}|${PRIO_PAIR})" \
        | sed -E 's/cookie=[^,]*, //; s/duration=[^,]*, //; s/n_packets=[0-9]*, //; s/n_bytes=[0-9]*, //; s/idle_age=[0-9]*, //; s/hard_age=[0-9]*, //' \
        || echo "(aucun flow omega)"
}

ovs_save() {
    # OVS ne persiste pas les flows au reboot : on les sauvegarde + service oneshot.
    mkdir -p "$OVS_FLOW_DIR"
    ovs-ofctl dump-flows "$BRIDGE" 2>/dev/null \
        | grep -E "priority=(${PRIO_DROP}|${PRIO_GW}|${PRIO_PAIR})" \
        | sed -E 's/^ *cookie=[^,]*, duration=[^,]*, table=[0-9]*, //; s/n_packets=[0-9]*, //; s/n_bytes=[0-9]*, //; s/idle_age=[0-9]*, //; s/hard_age=[0-9]*, //' \
        > "$OVS_FLOW_FILE"
    echo "Flows persistés dans ${OVS_FLOW_FILE} ($(wc -l < "$OVS_FLOW_FILE") flow(s))"

    # Service systemd oneshot qui rejoue les flows après le démarrage d'OVS.
    local unit="/etc/systemd/system/omega-ovs-isolation@.service"
    if [[ ! -f "$unit" ]]; then
        cat > "$unit" <<'UNIT'
[Unit]
Description=Omega OVS isolation flows for bridge %i
After=ovs-vswitchd.service openvswitch-switch.service
Wants=ovs-vswitchd.service
ConditionPathExists=/etc/omega/ovs-isolation-%i.flows

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'while ! ovs-vsctl br-exists %i 2>/dev/null; do sleep 1; done; ovs-ofctl add-flows %i /etc/omega/ovs-isolation-%i.flows'

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload 2>/dev/null || true
    fi
    systemctl enable "omega-ovs-isolation@${BRIDGE}.service" 2>/dev/null || true
    echo "Persistance activée (omega-ovs-isolation@${BRIDGE}.service)"
}

# ════════════════════════════════════════════════════════════════════════════
# Backend iptables (Linux bridge)
# ════════════════════════════════════════════════════════════════════════════
ipt_ensure_chain() {
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -C FORWARD -j "$CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$CHAIN"
}

ipt_init() {
    [[ -n "$SUBNET" ]] || { echo "--subnet requis pour init" >&2; exit 1; }
    ipt_ensure_chain
    local gw; gw="$(derive_gw)"
    iptables -C "$CHAIN" -d "$gw" -j ACCEPT 2>/dev/null || iptables -I "$CHAIN" 1 -d "$gw" -j ACCEPT
    iptables -C "$CHAIN" -s "$gw" -j ACCEPT 2>/dev/null || iptables -I "$CHAIN" 1 -s "$gw" -j ACCEPT
    iptables -C "$CHAIN" -s "$SUBNET" -d "$SUBNET" -j DROP 2>/dev/null || iptables -A "$CHAIN" -s "$SUBNET" -d "$SUBNET" -j DROP
    echo "Isolation iptables initialisée pour ${SUBNET} (gateway ${gw} exemptée)"
}

ipt_pair() {
    local a="$1" b="$2"
    ipt_ensure_chain
    iptables -C "$CHAIN" -s "$a" -d "$b" -j ACCEPT 2>/dev/null || iptables -I "$CHAIN" 1 -s "$a" -d "$b" -j ACCEPT
    iptables -C "$CHAIN" -s "$b" -d "$a" -j ACCEPT 2>/dev/null || iptables -I "$CHAIN" 1 -s "$b" -d "$a" -j ACCEPT
    echo "Lien autorisé: ${a} ↔ ${b}"
}

ipt_unpair() {
    local a="$1" b="$2"
    iptables -D "$CHAIN" -s "$a" -d "$b" -j ACCEPT 2>/dev/null || true
    iptables -D "$CHAIN" -s "$b" -d "$a" -j ACCEPT 2>/dev/null || true
    echo "Lien supprimé: ${a} ↔ ${b}"
}

ipt_list() {
    echo "=== Règles isolation OMEGA (iptables) ==="
    iptables -L "$CHAIN" -n --line-numbers 2>/dev/null || echo "(chaîne absente)"
}

ipt_save() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    systemctl enable netfilter-persistent 2>/dev/null || true
    echo "Règles persistées dans /etc/iptables/rules.v4"
}

# ════════════════════════════════════════════════════════════════════════════
# Dispatch
# ════════════════════════════════════════════════════════════════════════════
if is_ovs; then
    BACKEND="ovs"
else
    BACKEND="iptables"
fi

case "$ACTION" in
    init)
        [[ "$BACKEND" == "ovs" ]] && ovs_init || ipt_init ;;
    allow)
        [[ -n "$IP_A" && -n "$IP_B" ]] || { echo "--ip-a et --ip-b requis" >&2; exit 1; }
        [[ "$IP_A" != "$IP_B" ]] || { echo "IPs identiques" >&2; exit 1; }
        [[ "$BACKEND" == "ovs" ]] && ovs_pair "$IP_A" "$IP_B" || ipt_pair "$IP_A" "$IP_B" ;;
    deny)
        [[ -n "$IP_A" && -n "$IP_B" ]] || { echo "--ip-a et --ip-b requis" >&2; exit 1; }
        [[ "$BACKEND" == "ovs" ]] && ovs_unpair "$IP_A" "$IP_B" || ipt_unpair "$IP_A" "$IP_B" ;;
    list)
        [[ "$BACKEND" == "ovs" ]] && ovs_list || ipt_list ;;
    save)
        [[ "$BACKEND" == "ovs" ]] && ovs_save || ipt_save ;;
    *)
        echo "Action inconnue: $ACTION (init|allow|deny|list|save)" >&2
        exit 1 ;;
esac
