#!/usr/bin/env bash
# proxy-domain.sh — Publie un service VM sous un NOM de domaine SANS port (port 80).
#
# S'exécute sur la VM console (où tourne Caddy + accès pfSense). Crée un bloc Caddy
# `nom.enspy-gi.gandal → VM_IP:port`, enregistre le DNS nom→pfSense, recharge Caddy.
# (Le chemin console→VM doit être ouvert séparément par un lien réseau — fait par le backend.)
#
# Usage :
#   proxy-domain.sh --name monapp --ip 10.50.30.4 --port 8080 --enable
#   proxy-domain.sh --name monapp --disable
#   proxy-domain.sh --list
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"
fail() { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "\033[32m[OK]\033[0m    $*"; }
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

DOMAIN_SUFFIX="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
PF_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
# Hôte Caddy = CETTE machine (la console, où tourne Caddy:80). Le DNS doit pointer
# le nom ICI : le LAN route bien vers le VLAN30 (10.50.30.x via pfSense). Surtout PAS
# vers pfSense, dont le port 80 est occupé par son interface d'admin (redirige en 301).
CADDY_IP="${OMEGA_PROXY_HOST_IP:-$(ip -4 -o addr show 2>/dev/null | grep -oE '10\.50\.30\.[0-9]+' | head -1)}"
CADDY_IP="${CADDY_IP:-$PF_IP}"
SITES_DIR="/etc/caddy/sites"
NAME=""; VM_IP=""; PORT=""; ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --ip)   VM_IP="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --enable) ACTION="enable"; shift ;;
        --disable) ACTION="disable"; shift ;;
        --list) ACTION="list"; shift ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done
[[ -n "$ACTION" ]] || fail "Spécifier --enable, --disable ou --list"

# Label DNS normalisé (minuscules, sans le suffixe s'il est fourni).
norm() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed "s/\.${DOMAIN_SUFFIX}\$//" | tr -cd 'a-z0-9-'; }

case "$ACTION" in
enable)
    [[ -n "$NAME" && -n "$VM_IP" && -n "$PORT" ]] || fail "--name, --ip et --port requis"
    label="$(norm "$NAME")"; fqdn="${label}.${DOMAIN_SUFFIX}"
    mkdir -p "$SITES_DIR"
    cat > "${SITES_DIR}/${label}.caddy" <<CADDY
http://${fqdn} {
	reverse_proxy ${VM_IP}:${PORT} {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Port 80
		header_up X-Forwarded-Proto http
	}
}
CADDY
    /usr/local/bin/caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
        || systemctl reload gandal-proxy 2>/dev/null || fail "reload Caddy échoué"
    # DNS : nom → hôte Caddy (cette console), où le reverse-proxy port 80 répond.
    bash "${SCRIPT_DIR}/dns-register.sh" --name "$label" --ip "$CADDY_IP" >/dev/null 2>&1 \
        && ok "DNS ${fqdn} → ${CADDY_IP}" || echo "  (DNS non enregistré)"
    ok "Domaine actif : http://${fqdn} → ${VM_IP}:${PORT}"
    ;;
disable)
    [[ -n "$NAME" ]] || fail "--name requis"
    label="$(norm "$NAME")"
    rm -f "${SITES_DIR}/${label}.caddy"
    /usr/local/bin/caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
        || systemctl reload gandal-proxy 2>/dev/null || true
    bash "${SCRIPT_DIR}/dns-register.sh" --name "$label" --delete >/dev/null 2>&1 || true
    ok "Domaine retiré : ${label}.${DOMAIN_SUFFIX}"
    ;;
list)
    for f in "${SITES_DIR}"/*.caddy; do
        [[ -e "$f" ]] || { echo "(aucun domaine)"; break; }
        host=$(grep -oE 'http://[^ ]+' "$f" | head -1 | sed 's#http://##')
        up=$(grep -oE 'reverse_proxy [^ ]+' "$f" | awk '{print $2}')
        echo "${host} -> ${up}"
    done
    ;;
esac
