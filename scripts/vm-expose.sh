#!/usr/bin/env bash
# vm-expose.sh — Publie un service d'une VM Omega vers le LAN via pfSense (port-forward).
#
# Le LAN (192.168.123.x) n'a PAS de route vers le VLAN 30 (10.50.30.x). Ce script crée
# sur pfSense une redirection NAT : WAN(192.168.123.200):EXT_PORT → VM_IP:SVC_PORT, plus
# la règle firewall associée. Optionnellement enregistre un nom DNS → 192.168.123.200.
# L'utilisateur accède alors à  http://<nom-ou-.200>:EXT_PORT  depuis son PC.
#
# Usage :
#   vm-expose.sh --ip 10.50.30.4 --service-port 8080 [--ext-port 18080] [--name monapp] [--proto tcp] --enable
#   vm-expose.sh --ip 10.50.30.4 --service-port 8080 --disable
#   vm-expose.sh --list
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"
fail() { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "\033[32m[OK]\033[0m    $*"; }
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

VM_IP=""; SVC_PORT=""; EXT_PORT=""; NAME=""; PROTO="tcp"; ACTION=""
PFSENSE_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
PFSENSE_USER="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
PFSENSE_PORT="${OMEGA_NET_PFSENSE_SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
PF_IF_WAN="${OMEGA_NET_PF_IF_WAN:-wan}"
PF_WAN_ADDR="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)           VM_IP="$2"; shift 2 ;;
        --service-port) SVC_PORT="$2"; shift 2 ;;
        --ext-port)     EXT_PORT="$2"; shift 2 ;;
        --name)         NAME="$2"; shift 2 ;;
        --proto)        PROTO="$2"; shift 2 ;;
        --enable)       ACTION="enable"; shift ;;
        --disable)      ACTION="disable"; shift ;;
        --list)         ACTION="list"; shift ;;
        -h|--help)      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$ACTION" ]] || fail "Spécifier --enable, --disable ou --list"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$PFSENSE_PORT")
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
pfsense_php() { ssh "${SSH_OPTS[@]}" "${PFSENSE_USER}@${PFSENSE_IP}" "php -r \"$1\"" 2>/dev/null; }

if [[ "$ACTION" != "list" ]]; then
    [[ -n "$VM_IP" && -n "$SVC_PORT" ]] || fail "--ip et --service-port requis"
    [[ "$SVC_PORT" =~ ^[0-9]+$ ]] || fail "--service-port numérique"
    # Port externe par défaut = service-port (si libre), sinon l'appelant en fournit un.
    EXT_PORT="${EXT_PORT:-$SVC_PORT}"
    [[ "$EXT_PORT" =~ ^[0-9]+$ ]] || fail "--ext-port numérique"
fi
TAG="omega-expose-${VM_IP//./-}-${EXT_PORT}"

reload_php='require_once("config.inc");require_once("functions.inc");require_once("filter.inc");require_once("shaper.inc");require_once("util.inc");filter_configure_sync();'

case "$ACTION" in
enable)
    ENABLE_PHP=$(cat <<PHPEOF
require_once('config.inc'); require_once('functions.inc'); require_once('filter.inc');
require_once('shaper.inc'); require_once('util.inc');
global \\\$config;
// idempotent : retirer NAT + règle filtre liée du même tag
foreach (\\\$config['nat']['rule'] ?? [] as \\\$k => \\\$r) { if ((\\\$r['descr'] ?? '')==='${TAG}') unset(\\\$config['nat']['rule'][\\\$k]); }
if (isset(\\\$config['nat']['rule'])) \\\$config['nat']['rule']=array_values(\\\$config['nat']['rule']);
foreach (\\\$config['filter']['rule'] ?? [] as \\\$k => \\\$r) { if ((\\\$r['descr'] ?? '')==='${TAG}' || strpos(\\\$r['descr']??'','NAT ${TAG}')===0) unset(\\\$config['filter']['rule'][\\\$k]); }
if (isset(\\\$config['filter']['rule'])) \\\$config['filter']['rule']=array_values(\\\$config['filter']['rule']);
// Règle NAT port-forward (rdr) WAN:extport -> VM:svcport, firewall PASS auto-générée
\\\$nr=['interface'=>'${PF_IF_WAN}','protocol'=>'${PROTO}','ipprotocol'=>'inet',
  'source'=>['any'=>''],'destination'=>['network'=>'wanip','port'=>'${EXT_PORT}'],
  'target'=>'${VM_IP}','local-port'=>'${SVC_PORT}','descr'=>'${TAG}',
  'associated-rule-id'=>'pass'];
if(!isset(\\\$config['nat']['rule']))\\\$config['nat']['rule']=[];
\\\$config['nat']['rule'][]=\\\$nr;
write_config('omega: expose ${VM_IP}:${SVC_PORT} -> :${EXT_PORT}');
filter_configure_sync();
echo 'OK';
PHPEOF
)
    [[ "$(pfsense_php "$ENABLE_PHP")" == *OK* ]] || fail "échec création NAT pfSense"
    # DNS optionnel : nom → pfSense (.200), joignable depuis le LAN
    if [[ -n "$NAME" ]]; then
        bash "${SCRIPT_DIR}/dns-register.sh" --name "$NAME" --ip "$PF_WAN_ADDR" >/dev/null 2>&1 \
            && ok "DNS ${NAME} → ${PF_WAN_ADDR}" || echo "  (DNS non enregistré)"
    fi
    ok "Service exposé : ${PF_WAN_ADDR}:${EXT_PORT} → ${VM_IP}:${SVC_PORT} (${PROTO})"
    [[ -n "$NAME" ]] && echo "  Accès LAN : http://${NAME}.${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}:${EXT_PORT}"
    ;;
disable)
    DISABLE_PHP=$(cat <<PHPEOF
require_once('config.inc');
global \\\$config;
foreach (\\\$config['nat']['rule'] ?? [] as \\\$k => \\\$r){if((\\\$r['descr']??'')==='${TAG}')unset(\\\$config['nat']['rule'][\\\$k]);}
if(isset(\\\$config['nat']['rule']))\\\$config['nat']['rule']=array_values(\\\$config['nat']['rule']);
foreach (\\\$config['filter']['rule'] ?? [] as \\\$k => \\\$r){if((\\\$r['descr']??'')==='${TAG}')unset(\\\$config['filter']['rule'][\\\$k]);}
if(isset(\\\$config['filter']['rule']))\\\$config['filter']['rule']=array_values(\\\$config['filter']['rule']);
write_config('omega: unexpose ${TAG}'); echo 'OK';
PHPEOF
)
    pfsense_php "$DISABLE_PHP" >/dev/null
    pfsense_php "$reload_php" >/dev/null || true
    ok "Exposition retirée (${TAG})"
    ;;
list)
    LIST_PHP=$(cat <<PHPEOF
require_once('config.inc'); global \\\$config;
foreach (\\\$config['nat']['rule'] ?? [] as \\\$r) {
    if (strpos(\\\$r['descr'] ?? '', 'omega-expose-') === 0) {
        echo (\\\$r['descr']).' '.(\\\$r['target'] ?? '').':'.(\\\$r['local-port'] ?? '').' ext='.(\\\$r['destination']['port'] ?? '')."\n";
    }
}
PHPEOF
)
    pfsense_php "$LIST_PHP"
    ;;
esac
