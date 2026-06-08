#!/usr/bin/env bash
# dns-register.sh — Enregistre/supprime un nom DNS interne Omega via pfSense Unbound.
#
# Source de vérité : les "host overrides" Unbound de pfSense (config.xml →
# /var/unbound/host_entries.conf). Chaque nom devient un enregistrement A dans la
# zone interne (par défaut enspy-gi.gandal), résolvable depuis les VMs OMEGA ET
# depuis le LAN (cf. ACL Unbound + règle firewall, voir reference-lan-dns-omega).
#
# En plus de pfSense, l'outil maintient un /etc/hosts + un registre JSON
# (/etc/omega/dns-registry.json) sur chaque nœud Proxmox, pour que les hôtes
# résolvent même si pfSense est momentanément indisponible.
#
# NB : remplace l'ancienne implémentation dnsmasq/omega.local (VM DNS dédiée),
# qui n'existe plus — le DNS passe désormais par pfSense Unbound.
#
# Usage :
#   dns-register.sh --vmid 3001                      # nom = nom de la VM, IP déduite
#   dns-register.sh --vmid 3001 --name omega-test-3001
#   dns-register.sh --name abelmachine --ip 10.50.30.101
#   dns-register.sh --name abelmachine --delete
#   dns-register.sh --list
#
# Options :
#   --name NAME   Nom (sans le domaine). Normalisé en label DNS (minuscules…).
#   --ip IP       Adresse IP cible (enregistrement A).
#   --vmid N      VMID Omega : déduit l'IP (formule cluster.conf) et, si --name
#                 est absent, lit le nom de la VM via `qm config`.
#   --delete      Supprimer l'entrée du nom donné.
#   --list        Lister les entrées de la zone (lues sur pfSense).
#   --pfsense IP  Adresse de gestion pfSense (défaut: cluster.conf).
#   -h, --help    Aide.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${OMEGA_CLUSTER_CONF:-${SCRIPT_DIR}/cluster.conf}"

fail()  { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*" >&2; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

NAME=""
VM_IP=""
VMID=""
ACTION="register"
SSH_KEY="${SSH_KEY:-}"

IP_PREFIX="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}"
IP_START="${OMEGA_NET_VM_IP_START:-101}"
VMID_BASE="${OMEGA_NET_VM_VMID_BASE:-3000}"
DOMAIN="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
PFSENSE_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
PFSENSE_USER="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
OMEGA_NODES="${OMEGA_NODES:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
REGISTRY="/etc/omega/dns-registry.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)     NAME="$2"; shift 2 ;;
        --ip)       VM_IP="$2"; shift 2 ;;
        --vmid)     VMID="$2"; shift 2 ;;
        --delete)   ACTION="delete"; shift ;;
        --list)     ACTION="list"; shift ;;
        --pfsense)  PFSENSE_IP="$2"; shift 2 ;;
        -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

# Normalise un nom en label DNS valide (minuscules, [a-z0-9-], pas de bord '-').
_dns_label() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
        | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'
}

# Localise le nœud hébergeant un VMID et renvoie "node\tname".
_vm_node_and_name() {
    local vmid="$1" node out
    IFS=',' read -ra _nodes <<< "$OMEGA_NODES"
    for node in "${_nodes[@]}"; do
        [[ -n "$node" ]] || continue
        out=$(ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" \
            "test -f /etc/pve/qemu-server/${vmid}.conf && qm config ${vmid} 2>/dev/null | sed -n 's/^name: //p'" 2>/dev/null) || true
        if [[ -n "$out" ]]; then printf '%s\t%s' "$node" "$out"; return 0; fi
    done
    return 1
}

# Met à jour /etc/hosts + le registre JSON sur tous les nœuds Proxmox.
_nodes_sync() {  # <add|del> <label> <ip>
    local op="$1" label="$2" ip="${3:-}" node
    IFS=',' read -ra _nodes <<< "$OMEGA_NODES"
    for node in "${_nodes[@]}"; do
        [[ -n "$node" ]] || continue
        if [[ "$op" == "add" ]]; then
            ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
                mkdir -p /etc/omega
                python3 -c \"
import json,os
f='${REGISTRY}'
reg=json.load(open(f)) if os.path.exists(f) else []
reg=[e for e in reg if e.get('name')!='${label}']
reg.append({'name':'${label}','ip':'${ip}','port':None,'proto':'tcp'})
json.dump(reg,open(f,'w'),indent=2)
\" 2>/dev/null || true
                sed -i '/ ${label}\$/d; /${label}\\.${DOMAIN}/d' /etc/hosts 2>/dev/null || true
                echo '${ip}  ${label}.${DOMAIN}  ${label}' >> /etc/hosts
            " 2>/dev/null || true
        else
            ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
                sed -i '/${label}\\.${DOMAIN}/d; / ${label}\$/d' /etc/hosts 2>/dev/null || true
                python3 -c \"
import json,os
f='${REGISTRY}'
if os.path.exists(f):
    reg=[e for e in json.load(open(f)) if e.get('name')!='${label}']
    json.dump(reg,open(f,'w'),indent=2)
\" 2>/dev/null || true
            " 2>/dev/null || true
        fi
    done
}

# Pousse un script PHP sur pfSense et l'exécute (les `php -r` inline cassent
# sur `->` ; on passe toujours par un fichier copié via scp).
_pf_run_php() {  # <local_php_file> <remote_name>
    local local_php="$1" remote="$2"
    scp "${SSH_OPTS[@]}" "$local_php" "${PFSENSE_USER}@${PFSENSE_IP}:/tmp/${remote}" >/dev/null 2>&1 \
        && ssh "${SSH_OPTS[@]}" "${PFSENSE_USER}@${PFSENSE_IP}" "php /tmp/${remote} && rm -f /tmp/${remote}"
}

pf_register() {  # <label> <ip>
    local label="$1" ip="$2" pf; pf=$(mktemp)
    cat > "$pf" <<PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
if (!isset(\$config['unbound']['hosts'])) \$config['unbound']['hosts'] = [];
\$domain='${DOMAIN}'; \$host='${label}'; \$ip='${ip}';
\$config['unbound']['hosts'] = array_values(array_filter(\$config['unbound']['hosts'],
    fn(\$h) => !(\$h['host']===\$host && \$h['domain']===\$domain)));
\$config['unbound']['hosts'][] = ['host'=>\$host,'domain'=>\$domain,'ip'=>\$ip,
    'descr'=>'Omega VM '.\$host,'aliases'=>''];
write_config("DNS sync \$host.\$domain");
services_unbound_configure();
echo "A: \$host.\$domain -> \$ip\n";
PHPEOF
    local rc=0
    _pf_run_php "$pf" "dns_sync.php" || rc=1
    rm -f "$pf"
    return $rc
}

pf_delete() {  # <label>
    local label="$1" pf; pf=$(mktemp)
    cat > "$pf" <<PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
\$domain='${DOMAIN}'; \$host='${label}';
\$config['unbound']['hosts'] = array_values(array_filter(\$config['unbound']['hosts']??[],
    fn(\$h) => !(\$h['host']===\$host && \$h['domain']===\$domain)));
write_config("DNS unsync \$host.\$domain");
services_unbound_configure();
echo "del A: \$host.\$domain\n";
PHPEOF
    local rc=0
    _pf_run_php "$pf" "dns_unsync.php" || rc=1
    rm -f "$pf"
    return $rc
}

# ── Résolution IP / nom depuis VMID ──────────────────────────────────────────
if [[ -n "$VMID" ]]; then
    [[ "$VMID" =~ ^[0-9]+$ ]] || fail "--vmid doit être numérique"
    if [[ -z "$VM_IP" ]]; then
        VM_IP="${IP_PREFIX}.$((IP_START + VMID - VMID_BASE))"
    fi
    if [[ -z "$NAME" && "$ACTION" != "list" ]]; then
        if nn=$(_vm_node_and_name "$VMID"); then
            NAME="${nn#*$'\t'}"
            info "VMID ${VMID} → nom='${NAME}' ip=${VM_IP}"
        else
            fail "VM ${VMID} introuvable sur les nœuds (${OMEGA_NODES}); fournir --name"
        fi
    fi
fi

case "$ACTION" in
    register)
        [[ -n "$NAME" ]] || fail "--name ou --vmid requis"
        [[ -n "$VM_IP" ]] || fail "--ip ou --vmid requis"
        LABEL="$(_dns_label "$NAME")"
        [[ -n "$LABEL" ]] || fail "nom '${NAME}' ne donne aucun label DNS valide"
        if pf_register "$LABEL" "$VM_IP"; then
            _nodes_sync add "$LABEL" "$VM_IP"
            ok "DNS enregistré : ${LABEL}.${DOMAIN} → ${VM_IP}"
            echo "  Vérif : dig +short @${PFSENSE_IP} ${LABEL}.${DOMAIN}"
        else
            fail "échec enregistrement pfSense (${PFSENSE_USER}@${PFSENSE_IP}) — vérifier SSH/perms"
        fi
        ;;
    delete)
        [[ -n "$NAME" ]] || fail "--name ou --vmid requis"
        LABEL="$(_dns_label "$NAME")"
        pf_delete "$LABEL" || warn "suppression pfSense incertaine (continue le nettoyage nœuds)"
        _nodes_sync del "$LABEL"
        ok "DNS supprimé : ${LABEL}.${DOMAIN}"
        ;;
    list)
        info "Entrées DNS de la zone ${DOMAIN} (pfSense ${PFSENSE_IP}) :"
        ssh "${SSH_OPTS[@]}" "${PFSENSE_USER}@${PFSENSE_IP}" \
            "grep -E 'local-data: \"[^\"]+\\.${DOMAIN}\\. A ' /var/unbound/host_entries.conf 2>/dev/null \
             | sed -E 's/.*local-data: \"([^ ]+) A ([0-9.]+)\".*/  A    \\1 -> \\2/' | sort -u" \
            2>/dev/null || echo "  (lecture pfSense impossible)"
        ;;
esac
