#!/usr/bin/env bash
# omega-llm-access-reconciler.sh — réconcilie l'accès GPU/LLM des VMs Omega.
#
# RÈGLE : toute VM Omega démarrée dont la config contient
#         `omega_gpu_vram_mib > SEUIL` (défaut 0) DOIT pouvoir joindre la
#         gateway LLM (port 4000). Les VMs à vram<=SEUIL n'y ont pas accès.
#
# Idempotent : ajoute la règle pfSense manquante (via llm-access.sh, qui vérifie
# l'existant), et — avec --prune — retire l'accès des VMs non conformes.
# À lancer sur le CONTRÔLEUR (accès pvesh + /etc/pve + joint pfSense), à la main
# ou via un timer systemd. Résout l'IP des VMs lui-même (pvesh agent), donc pas
# de dépendance à un SSH vers le contrôleur.
#
# Usage :
#   omega-llm-access-reconciler.sh                 # vram>0 -> accès
#   omega-llm-access-reconciler.sh --dry-run       # montre sans appliquer
#   omega-llm-access-reconciler.sh --prune         # + retire l'accès des non-conformes
#   omega-llm-access-reconciler.sh --threshold 0   # seuil (défaut 0)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

info(){ echo -e "\033[36m[INF]\033[0m $*"; }
ok(){   echo -e "\033[32m[OK]\033[0m  $*"; }

THRESHOLD="${OMEGA_LLM_ACCESS_VRAM_THRESHOLD:-0}"
PRUNE=false; DRY=false
GATEWAY_IP="${OMEGA_LLM_GATEWAY_IP:-192.168.123.100}"
GW_PORT="${OMEGA_LLM_GATEWAY_PORT:-4000}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY=true; shift ;;
        --prune)     PRUNE=true; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --gateway)   GATEWAY_IP="$2"; shift 2 ;;
        -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue: $1" >&2; exit 1 ;;
    esac
done

command -v pvesh >/dev/null || { echo "pvesh introuvable — à lancer sur un nœud du cluster" >&2; exit 1; }

# Carte vmid -> "status|node" (cluster-wide)
declare -A STATUS NODE
while IFS='|' read -r vmid st nd; do
    [[ -n "$vmid" ]] && { STATUS["$vmid"]="$st"; NODE["$vmid"]="$nd"; }
done < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c 'import sys,json
for v in json.load(sys.stdin): print("%s|%s|%s" % (v.get("vmid"), v.get("status"), v.get("node")))' 2>/dev/null)

resolve_ip() {  # $1=vmid $2=node -> IPv4 sur stdout (vide si introuvable)
    pvesh get "/nodes/$2/qemu/$1/agent/network-get-interfaces" --output-format json 2>/dev/null \
      | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    ifs=d.get("result",d) if isinstance(d,dict) else d
    for i in ifs:
        for a in i.get("ip-addresses",[]):
            ip=a.get("ip-address","")
            if ip and not ip.startswith("127.") and ":" not in ip and not ip.startswith("169.254"):
                print(ip); raise SystemExit
except Exception: pass'
}

apply() {  # $1=ip $2=enable|disable $3=vmid
    if $DRY; then echo "    (dry-run) llm-access $2 vm $3 ($1)"; return 0; fi
    bash "${SCRIPT_DIR}/llm-access.sh" --ip "$1" "--$2" --gateway "$GATEWAY_IP" --gw-port "$GW_PORT" 2>&1 | sed 's/^/      /'
}

n_grant=0; n_revoke=0; n_skip=0
info "Réconciliation accès LLM (vram > ${THRESHOLD} → gateway ${GATEWAY_IP}:${GW_PORT})"

for f in /etc/pve/nodes/*/qemu-server/*.conf; do
    [[ -e "$f" ]] || continue
    vmid="$(basename "$f" .conf)"
    vram="$(grep -oE 'omega_gpu_vram_mib=-?[0-9]+' "$f" 2>/dev/null | head -1 | cut -d= -f2 || true)"
    [[ -z "$vram" ]] && continue
    st="${STATUS[$vmid]:-unknown}"; nd="${NODE[$vmid]:-}"

    if [[ "$vram" -gt "$THRESHOLD" ]]; then
        [[ "$st" == "running" ]] || { n_skip=$((n_skip+1)); continue; }
        ip="$(resolve_ip "$vmid" "$nd")"
        [[ -z "$ip" ]] && { info "vm ${vmid} (vram=${vram}) running mais IP non résolue (QGA ?) → ignorée"; n_skip=$((n_skip+1)); continue; }
        info "vm ${vmid} (vram=${vram}, ${ip}) → garantir l'accès"
        apply "$ip" enable "$vmid"; n_grant=$((n_grant+1))
    elif $PRUNE && [[ "$st" == "running" ]]; then
        ip="$(resolve_ip "$vmid" "$nd")"
        [[ -z "$ip" ]] && { n_skip=$((n_skip+1)); continue; }
        info "vm ${vmid} (vram=${vram} ≤ ${THRESHOLD}, ${ip}) → retirer l'accès"
        apply "$ip" disable "$vmid"; n_revoke=$((n_revoke+1))
    fi
done

ok "Terminé : ${n_grant} accès garantis, ${n_revoke} retirés, ${n_skip} ignorés."
