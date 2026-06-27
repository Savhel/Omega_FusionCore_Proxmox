#!/usr/bin/env bash
# llm-access.sh — Ouvre (ou ferme) l'accès d'une VM Omega isolée à la gateway LLM.
#
# Les VMs Omega sont isolées par défaut. Ce script ajoute une règle pfSense PASS
# + NAT outbound ÉTROITE : la VM (ou tout le réseau OMEGA) ne peut joindre QUE
# l'hôte de la gateway LLM (port 4000 OpenAI + 11434 Ollama), rien d'autre du LAN.
# La VM reste donc coupée d'internet/du reste du LAN. Réversible.
#
# Usage :
#   scripts/llm-access.sh --vmid 3000 --enable
#   scripts/llm-access.sh --all --enable            # tout le réseau OMEGA
#   scripts/llm-access.sh --ip 10.50.30.101 --disable
#   scripts/llm-access.sh --list
#
# Options :
#   --vmid N        VMID Omega (résout l'IP via QGA, sinon calcul positionnel).
#   --ip IP         IP directe de la VM.
#   --all           Ouvre pour TOUT le réseau OMEGA (préfixe .0/24).
#   --enable        Autoriser l'accès à la gateway.
#   --disable       Retirer l'autorisation.
#   --list          Lister les accès LLM ouverts.
#   --gateway IP    Hôte de la gateway LLM (défaut 192.168.123.100).
#   --gw-port P     Port gateway OpenAI (défaut 4000).
#   --pfsense IP    IP WAN de pfSense (défaut 192.168.123.200).
#   -h, --help      Aide.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

fail()  { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

VMID=""
VM_IP=""
ALL=false
ACTION=""
PFSENSE_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
PFSENSE_USER="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
PFSENSE_PORT="${OMEGA_NET_PFSENSE_SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
IP_PREFIX="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}"
IP_START="${OMEGA_NET_VM_IP_START:-101}"
VMID_BASE="${OMEGA_NET_VM_VMID_BASE:-3000}"
PF_IF_OMEGA="${OMEGA_NET_PF_IF_OMEGA:-opt3}"
PF_IF_WAN="${OMEGA_NET_PF_IF_WAN:-wan}"
GATEWAY_IP="${OMEGA_LLM_GATEWAY_IP:-192.168.123.100}"
GW_PORT="${OMEGA_LLM_GATEWAY_PORT:-4000}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)    VMID="$2"; shift 2 ;;
        --ip)      VM_IP="$2"; shift 2 ;;
        --all)     ALL=true; shift ;;
        --enable)  ACTION="enable"; shift ;;
        --disable) ACTION="disable"; shift ;;
        --list)    ACTION="list"; shift ;;
        --gateway) GATEWAY_IP="$2"; shift 2 ;;
        --gw-port) GW_PORT="$2"; shift 2 ;;
        --pfsense) PFSENSE_IP="$2"; shift 2 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$ACTION" ]] || fail "Spécifier --enable, --disable ou --list"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$PFSENSE_PORT")
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

pfsense_php() {
    ssh "${SSH_OPTS[@]}" "${PFSENSE_USER}@${PFSENSE_IP}" "php -r \"$1\"" 2>/dev/null
}

# Résoudre la source (une VM, ou tout le réseau OMEGA)
SRC_CIDR=""
if $ALL; then
    SRC_CIDR="${IP_PREFIX}.0/24"
    VM_IP="${IP_PREFIX}.0"   # pour le tag uniquement
    info "Cible : tout le réseau OMEGA ${SRC_CIDR}"
elif [[ -n "$VMID" && -z "$VM_IP" ]]; then
    [[ "$VMID" =~ ^[0-9]+$ ]] || fail "--vmid doit être numérique"
    CTRL_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
    [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && CTRL_SSH_OPTS+=(-i "$SSH_KEY")
    _CONTROLLER="${OMEGA_CONTROLLER:-${PFSENSE_IP}}"
    VM_IP="$(ssh "${CTRL_SSH_OPTS[@]}" "${DEPLOY_USER:-root}@${_CONTROLLER}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | python3 -c \"import json,sys,subprocess
vms=json.load(sys.stdin)
vm=[v for v in vms if str(v.get('vmid'))==str(${VMID})]
if vm:
    r=subprocess.run(['qm','guest','cmd','${VMID}','network-get-interfaces'],
        capture_output=True,text=True,timeout=5)
    if r.returncode==0:
        import json as j2
        for iface in j2.loads(r.stdout):
            for addr in iface.get('ip-addresses',[]):
                ip=addr.get('ip-address','')
                if ip and not ip.startswith('127.') and ':' not in ip and not ip.startswith('fe80'):
                    print(ip); exit()
\"" 2>/dev/null || true)"
    if [[ -z "$VM_IP" ]]; then
        ip_last=$(( IP_START + VMID - VMID_BASE ))
        [[ "$ip_last" -gt 0 && "$ip_last" -lt 255 ]] && VM_IP="${IP_PREFIX}.${ip_last}" \
            || fail "Impossible de résoudre l'IP pour VMID ${VMID}. Utilisez --ip."
    fi
    SRC_CIDR="${VM_IP}/32"
    info "VMID ${VMID} → IP ${VM_IP}"
elif [[ -n "$VM_IP" ]]; then
    SRC_CIDR="${VM_IP}/32"
fi

RULE_TAG="omega-llm-${VM_IP//\./-}"

# ── PHP pfSense : règle PASS étroite (src → gateway uniquement) + NAT outbound ──
ENABLE_PHP=$(cat <<PHPEOF
require_once('config.inc');
require_once('functions.inc');
require_once('filter.inc');
require_once('shaper.inc');
global \\\$config;

\\\$exists = false;
foreach (\\\$config['filter']['rule'] ?? [] as \\\$r) {
    if ((\\\$r['descr'] ?? '') === '${RULE_TAG}') { \\\$exists = true; break; }
}
if (\\\$exists) { echo 'EXISTS'; exit(0); }

// PASS tcp depuis la source vers le SEUL hôte de la gateway
\\\$rule = [
    'type'       => 'pass',
    'interface'  => '${PF_IF_OMEGA}',
    'ipprotocol' => 'inet',
    'protocol'   => 'tcp',
    'source'     => ['address' => '${SRC_CIDR}'],
    'destination'=> ['address' => '${GATEWAY_IP}'],
    'descr'      => '${RULE_TAG}',
    'tracker'    => (string)(time() * 1000 + rand(0,999)),
];
if (!isset(\\\$config['filter']['rule'])) \\\$config['filter']['rule'] = [];
array_unshift(\\\$config['filter']['rule'], \\\$rule);

// NAT outbound : src → gateway, masqué derrière l'IP WAN de pfSense
if (!isset(\\\$config['nat']['outbound'])) \\\$config['nat']['outbound'] = [];
\\\$config['nat']['outbound']['mode'] = 'hybrid';
\\\$config['nat']['outbound']['rule'][] = [
    'interface'   => '${PF_IF_WAN}',
    'source'      => ['network' => '${SRC_CIDR}'],
    'destination' => ['address' => '${GATEWAY_IP}'],
    'descr'       => '${RULE_TAG}-nat',
    'target'      => '',
    'natport'     => '',
];

write_config('omega: llm-access enable ${VM_IP} -> ${GATEWAY_IP}');
filter_configure();
echo 'OK';
PHPEOF
)

DISABLE_PHP=$(cat <<PHPEOF
require_once('config.inc');
require_once('functions.inc');
require_once('filter.inc');
global \\\$config;
\\\$config['filter']['rule'] = array_values(array_filter(
    \\\$config['filter']['rule'] ?? [],
    function(\\\$r) { return (\\\$r['descr'] ?? '') !== '${RULE_TAG}'; }
));
\\\$config['nat']['outbound']['rule'] = array_values(array_filter(
    \\\$config['nat']['outbound']['rule'] ?? [],
    function(\\\$r) { return (\\\$r['descr'] ?? '') !== '${RULE_TAG}-nat'; }
));
write_config('omega: llm-access disable ${VM_IP}');
filter_configure();
echo 'OK';
PHPEOF
)

LIST_PHP=$(cat <<PHPEOF
require_once('config.inc');
global \\\$config;
foreach (\\\$config['filter']['rule'] ?? [] as \\\$r) {
    if (strpos(\\\$r['descr'] ?? '', 'omega-llm-') === 0) {
        echo (\\\$r['source']['address'] ?? '?') . ' -> ' . (\\\$r['destination']['address'] ?? '?') . "\n";
    }
}
PHPEOF
)

case "$ACTION" in
    enable)
        [[ -n "$SRC_CIDR" ]] || fail "--vmid, --ip ou --all requis pour --enable"
        result="$(pfsense_php "$ENABLE_PHP")"
        if [[ "$result" == "EXISTS" ]]; then
            info "Accès LLM déjà ouvert pour ${VM_IP} → ${GATEWAY_IP}"
        else
            ok "Accès LLM ouvert : ${SRC_CIDR} → ${GATEWAY_IP}:${GW_PORT} (gateway uniquement)"
        fi
        ;;
    disable)
        [[ -n "$SRC_CIDR" ]] || fail "--vmid, --ip ou --all requis pour --disable"
        pfsense_php "$DISABLE_PHP" >/dev/null
        ok "Accès LLM retiré pour ${VM_IP}"
        ;;
    list)
        info "Accès LLM ouverts :"
        result="$(pfsense_php "$LIST_PHP")"
        [[ -z "$result" ]] && echo "  (aucun)" || echo "$result" | while read -r l; do echo "  → ${l}"; done
        ;;
esac
