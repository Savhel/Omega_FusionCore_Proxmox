#!/usr/bin/env bash
# gandal-central-access.sh — Ouvre un accès LEAST-PRIVILEGE depuis le réseau OMEGA
# (VLAN 30) vers le serveur central GANDAL, et UNIQUEMENT vers ses ports. Les VMs
# restent isolées d'internet et entre elles ; seul le flux vers le central passe.
#
# Pose, côté pfSense :
#   - règles PASS sur l'interface OMEGA : 10.50.30.0/24 -> <central> tcp <ports>
#   - NAT outbound sur WAN : 10.50.30.0/24 -> <central> masqué derrière l'IP WAN
# Idempotent (supprime ses anciennes règles taguées avant de réappliquer).
#
# Usage :
#   gandal-central-access.sh --apply
#   gandal-central-access.sh --remove
#
# Variables (défauts depuis cluster.conf si présent) :
#   --central IP      Serveur central GANDAL. Défaut: 192.168.123.100
#   --ports CSV       Ports tcp autorisés. Défaut: 5002,5014,8000,8010
#   --omega-net CIDR  Sous-réseau OMEGA. Défaut: 10.50.30.0/24
#   --pfsense IP      Gestion pfSense. Défaut: cluster.conf OMEGA_NET_PFSENSE_WAN_IP

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/cluster.conf" ]] && source "${SCRIPT_DIR}/cluster.conf" 2>/dev/null || true

fail() { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "\033[32m[OK]\033[0m    $*"; }
info() { echo -e "\033[36m[INF]\033[0m  $*"; }

ACTION=""
CENTRAL="${OMEGA_GANDAL_CENTRAL_IP:-192.168.123.100}"
PORTS="${OMEGA_GANDAL_CENTRAL_PORTS:-5002,5014,8000,8010}"
OMEGA_NET="${OMEGA_NET_ZONE_OMEGA_NET:-10.50.30.0/24}"
PFSENSE_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
PFSENSE_USER="${OMEGA_NET_PFSENSE_SSH_USER:-root}"
PF_IF_OMEGA="${OMEGA_NET_PF_IF_OMEGA:-opt3}"
PF_IF_WAN="${OMEGA_NET_PF_IF_WAN:-wan}"
SSH_KEY="${SSH_KEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)    ACTION="apply"; shift ;;
        --remove)   ACTION="remove"; shift ;;
        --central)  CENTRAL="$2"; shift 2 ;;
        --ports)    PORTS="$2"; shift 2 ;;
        --omega-net) OMEGA_NET="$2"; shift 2 ;;
        --pfsense)  PFSENSE_IP="$2"; shift 2 ;;
        -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done
[[ -n "$ACTION" ]] || fail "--apply ou --remove requis"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

TAG="gandal-central"

# Construit les entrées PHP des règles filter (une par port) + la règle NAT.
build_rules_php() {
    local php_ports="" p
    IFS=',' read -ra _ports <<< "$PORTS"
    for p in "${_ports[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        php_ports+="  \$config['filter']['rule'][] = ['type'=>'pass','interface'=>'${PF_IF_OMEGA}','ipprotocol'=>'inet','protocol'=>'tcp','source'=>['address'=>'${OMEGA_NET}'],'destination'=>['address'=>'${CENTRAL}','port'=>'${p}'],'descr'=>'${TAG}','tracker'=>(string)(time()*1000+rand(0,999))];\n"
    done
    printf '%s' "$php_ports"
}

run_php_on_pfsense() {  # <php_body>
    local body="$1" pf; pf="$(mktemp)"
    {
        echo "<?php"
        echo "require_once('globals.inc'); require_once('config.inc'); require_once('functions.inc');"
        echo "require_once('util.inc'); require_once('shaper.inc'); require_once('filter.inc');"
        printf '%b\n' "$body"
        echo "write_config('omega: ${TAG} ${ACTION}');"
        echo "filter_configure_sync();"
        echo "echo \"done\\n\";"
    } > "$pf"
    scp "${SSH_OPTS[@]}" "$pf" "${PFSENSE_USER}@${PFSENSE_IP}:/tmp/${TAG}.php" >/dev/null 2>&1 \
        && ssh "${SSH_OPTS[@]}" "${PFSENSE_USER}@${PFSENSE_IP}" "php /tmp/${TAG}.php && rm -f /tmp/${TAG}.php"
    local rc=$?; rm -f "$pf"; return $rc
}

# Toujours purger les anciennes règles taguées (idempotence), puis (ré)appliquer si apply.
PURGE="\$config['filter']['rule'] = array_values(array_filter(\$config['filter']['rule']??[], function(\$r){ return (\$r['descr']??'') !== '${TAG}'; }));\n"
PURGE+="\$config['nat']['outbound']['rule'] = array_values(array_filter(\$config['nat']['outbound']['rule']??[], function(\$r){ return (\$r['descr']??'') !== '${TAG}-nat'; }));\n"

if [[ "$ACTION" == "remove" ]]; then
    info "Suppression accès ${TAG} (VLAN OMEGA → ${CENTRAL})..."
    run_php_on_pfsense "$PURGE" && ok "règles ${TAG} supprimées" || fail "échec suppression pfSense"
    exit 0
fi

info "Ouverture least-privilege : ${OMEGA_NET} → ${CENTRAL} tcp/${PORTS} (le reste reste isolé)"
BODY="$PURGE"
BODY+="$(build_rules_php)"
# NAT outbound : tout le trafic OMEGA vers le central est masqué derrière l'IP WAN.
BODY+="if(!isset(\$config['nat']['outbound'])) \$config['nat']['outbound']=[];\n"
BODY+="\$config['nat']['outbound']['mode']='hybrid';\n"
BODY+="\$config['nat']['outbound']['rule'][] = ['interface'=>'${PF_IF_WAN}','source'=>['network'=>'${OMEGA_NET}'],'destination'=>['address'=>'${CENTRAL}'],'descr'=>'${TAG}-nat','target'=>'','natport'=>''];\n"

if run_php_on_pfsense "$BODY"; then
    ok "accès ${TAG} appliqué (PASS opt3 + NAT WAN). Vérifie : pfctl -sr | grep ${TAG}"
else
    fail "échec application pfSense (${PFSENSE_USER}@${PFSENSE_IP})"
fi
