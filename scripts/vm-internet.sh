#!/usr/bin/env bash
# vm-internet.sh — Active ou désactive l'accès internet pour une VM Omega.
#
# La VM reste isolée par défaut. Ce script ajoute une règle pfSense PASS + NAT
# pour l'IP de la VM et recharge le filtre. Réversible.
#
# Usage :
#   scripts/vm-internet.sh --vmid 2300 --enable
#   scripts/vm-internet.sh --vmid 2300 --disable
#   scripts/vm-internet.sh --ip 10.50.30.101 --enable
#
# Options :
#   --vmid N        VMID Omega (calcule l'IP depuis cluster.conf).
#   --ip IP         IP directe (si pas de VMID).
#   --enable        Autoriser l'accès internet.
#   --disable       Supprimer l'autorisation.
#   --list          Lister les VMs avec accès internet.
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)    VMID="$2"; shift 2 ;;
        --ip)      VM_IP="$2"; shift 2 ;;
        --enable)  ACTION="enable"; shift ;;
        --disable) ACTION="disable"; shift ;;
        --list)    ACTION="list"; shift ;;
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

# Résoudre l'IP depuis le VMID : QGA d'abord, sinon calcul positionnel
if [[ -n "$VMID" && -z "$VM_IP" ]]; then
    [[ "$VMID" =~ ^[0-9]+$ ]] || fail "--vmid doit être numérique"
    # Essayer QGA sur tous les nœuds
    CTRL_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
    [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && CTRL_SSH_OPTS+=(-i "$SSH_KEY")
    _CONTROLLER="${OMEGA_CONTROLLER:-${PFSENSE_IP}}"
    VM_IP="$(ssh "${CTRL_SSH_OPTS[@]}" "${DEPLOY_USER:-root}@${_CONTROLLER}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | python3 -c \"import json,sys,subprocess
vms=json.load(sys.stdin)
vm=[v for v in vms if str(v.get('vmid'))==str(${VMID})]
if vm:
    node=vm[0].get('node','')
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
        # Fallback : calcul positionnel (VMs test uniquement)
        ip_last=$(( IP_START + VMID - VMID_BASE ))
        if [[ "$ip_last" -gt 0 && "$ip_last" -lt 255 ]]; then
            VM_IP="${IP_PREFIX}.${ip_last}"
        else
            fail "Impossible de résoudre l'IP pour VMID ${VMID}. Utilisez --ip directement."
        fi
    fi
    info "VMID ${VMID} → IP ${VM_IP}"
fi

RULE_TAG="omega-internet-${VM_IP//\./-}"

# ── PHP qui tourne sur pfSense ────────────────────────────────────────────────
# pfSense stocke tout dans /cf/conf/config.xml et expose une API PHP interne.
# On manipule directement le tableau de règles et on appelle filter_configure().

ENABLE_PHP=$(cat <<PHPEOF
require_once('config.inc');
require_once('functions.inc');
require_once('filter.inc');
require_once('shaper.inc');
global \\\$config;

// Vérifier si la règle existe déjà
\\\$exists = false;
foreach (\\\$config['filter']['rule'] ?? [] as \\\$r) {
    if ((\\\$r['descr'] ?? '') === '${RULE_TAG}') { \\\$exists = true; break; }
}
if (\\\$exists) { echo 'EXISTS'; exit(0); }

// Règle PASS sur l'interface OMEGA pour cette IP vers WAN
\\\$rule = [
    'type'       => 'pass',
    'interface'  => '${PF_IF_OMEGA}',
    'ipprotocol' => 'inet',
    'protocol'   => 'any',
    'source'     => ['address' => '${VM_IP}'],
    'destination'=> ['any' => true],
    'descr'      => '${RULE_TAG}',
    'tracker'    => (string)(time() * 1000 + rand(0,999)),
];
if (!isset(\\\$config['filter']['rule'])) \\\$config['filter']['rule'] = [];
array_unshift(\\\$config['filter']['rule'], \\\$rule);

// Règle NAT outbound pour cette IP
if (!isset(\\\$config['nat']['outbound'])) \\\$config['nat']['outbound'] = [];
\\\$config['nat']['outbound']['mode'] = 'hybrid';
\\\$config['nat']['outbound']['rule'][] = [
    'interface'   => '${PF_IF_WAN}',
    'source'      => ['network' => '${VM_IP}/32'],
    'destination' => ['any' => true],
    'descr'       => '${RULE_TAG}-nat',
    'target'      => '',
    'natport'     => '',
];

write_config('omega: internet enable ${VM_IP}');
filter_configure();
echo 'OK';
PHPEOF
)

DISABLE_PHP=$(cat <<PHPEOF
require_once('config.inc');
require_once('functions.inc');
require_once('filter.inc');
global \\\$config;

\\\$removed = 0;
// Supprimer règle firewall
\\\$config['filter']['rule'] = array_values(array_filter(
    \\\$config['filter']['rule'] ?? [],
    function(\\\$r) { return (\\\$r['descr'] ?? '') !== '${RULE_TAG}'; }
));
// Supprimer règle NAT
\\\$config['nat']['outbound']['rule'] = array_values(array_filter(
    \\\$config['nat']['outbound']['rule'] ?? [],
    function(\\\$r) { return (\\\$r['descr'] ?? '') !== '${RULE_TAG}-nat'; }
));

write_config('omega: internet disable ${VM_IP}');
filter_configure();
echo 'OK';
PHPEOF
)

LIST_PHP=$(cat <<PHPEOF
require_once('config.inc');
global \\\$config;
foreach (\\\$config['filter']['rule'] ?? [] as \\\$r) {
    if (strpos(\\\$r['descr'] ?? '', 'omega-internet-') === 0) {
        echo \\\$r['source']['address'] . "\n";
    }
}
PHPEOF
)

case "$ACTION" in
    enable)
        [[ -n "$VM_IP" ]] || fail "--vmid ou --ip requis pour --enable"
        result="$(pfsense_php "$ENABLE_PHP")"
        if [[ "$result" == "EXISTS" ]]; then
            info "VM ${VM_IP} a déjà l'accès internet"
        else
            ok "Internet activé pour ${VM_IP}"
        fi
        ;;
    disable)
        [[ -n "$VM_IP" ]] || fail "--vmid ou --ip requis pour --disable"
        pfsense_php "$DISABLE_PHP" >/dev/null
        ok "Internet désactivé pour ${VM_IP}"
        ;;
    list)
        info "VMs avec accès internet :"
        result="$(pfsense_php "$LIST_PHP")"
        if [[ -z "$result" ]]; then
            echo "  (aucune)"
        else
            echo "$result" | while read -r ip; do echo "  → ${ip}"; done
        fi
        ;;
esac
