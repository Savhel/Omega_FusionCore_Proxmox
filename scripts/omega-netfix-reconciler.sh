#!/usr/bin/env bash
# omega-netfix-reconciler.sh — répare automatiquement les VMs Omega sans réseau.
#
# PROBLÈME traité : une VM adoptée/recréée garde dans son netplan in-guest
# (/etc/netplan/50-cloud-init.yaml) un `match: macaddress:` pointant l'ANCIENNE
# MAC (cloud-init ne régénère pas le net-config car l'instance-id n'a pas changé),
# alors que `net0` a une nouvelle MAC → le match échoue → eth0 reste DOWN, aucune
# IP. La VM est saine mais injoignable (l'install proxys, le DNS, etc. échouent).
#
# STRATÉGIE (non intrusive) :
#   1. VM omega *running* qui a DÉJÀ une IPv4 (via pvesh agent) → on ne touche à rien.
#   2. VM running SANS IPv4 → on lit la MAC réelle de net0 (conf PVE) et, via le
#      GUEST AGENT (canal virtio, fonctionne SANS réseau), on corrige la MAC du
#      netplan si elle diffère, puis `netplan apply`. Filet : link up + re-apply.
#
# Idempotent. Agir uniquement sur les VMs Omega (conf contenant un marqueur omega_).
# À lancer sur le CONTRÔLEUR (pvesh + /etc/pve + ssh vers les nœuds), à la main ou
# via le timer systemd (cf install-netfix-reconciler-remote.sh).
#
# Usage :
#   omega-netfix-reconciler.sh                 # détecte et répare
#   omega-netfix-reconciler.sh --dry-run       # détecte et montre, sans rien changer
#   omega-netfix-reconciler.sh --all-vms       # ne pas restreindre aux VMs omega_
#   omega-netfix-reconciler.sh --vmids 3012,3009

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

info(){ echo -e "\033[36m[INF]\033[0m $*"; }
ok(){   echo -e "\033[32m[OK]\033[0m  $*"; }
warn(){ echo -e "\033[33m[WRN]\033[0m $*"; }

case "${OMEGA_NETFIX_DRY_RUN:-0}" in 1|true|yes|on) DRY=true ;; *) DRY=false ;; esac
ALL_VMS=false
ONLY_VMIDS=""
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=yes)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=true; shift ;;
        --all-vms) ALL_VMS=true; shift ;;
        --vmids)   ONLY_VMIDS="$2"; shift 2 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
for v in json.load(sys.stdin):
    if v.get("type")=="qemu": print("%s|%s|%s" % (v.get("vmid"), v.get("status"), v.get("node")))' 2>/dev/null)

# IPv4 utile d'une VM via le guest agent (lecture seule, côté contrôleur)
resolve_ip() {  # $1=vmid $2=node
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

# MAC de net0 depuis la conf PVE (minuscule, format aa:bb:..)
net0_mac() {  # $1=conf_file
    grep -oiE 'net0:[^,]*virtio=[0-9a-f:]{17}' "$1" 2>/dev/null \
        | grep -oiE '[0-9a-f:]{17}' | head -1 | tr 'A-Z' 'a-z'
}

# Script exécuté DANS la VM (via guest agent). Lit la MAC cible en argv[1].
# Renvoie une ligne "RESULT=..." + l'état IP final.
guest_fix_script() {
cat <<'GUEST'
set -u
WANT="$(echo "$1" | tr 'A-Z' 'a-z')"
have_ip(){ ip -4 -o addr show 2>/dev/null | grep -vE ' lo |inet 127\.' | grep -q 'inet '; }
if have_ip; then echo "RESULT=already-up"; ip -4 -o addr show | grep -vE ' lo '; exit 0; fi
NP=/etc/netplan/50-cloud-init.yaml
ACTION="none"
if [ -f "$NP" ]; then
  CUR="$(grep -oiE 'macaddress:[[:space:]]*[0-9a-f:]{17}' "$NP" | grep -oiE '[0-9a-f:]{17}' | head -1 | tr 'A-Z' 'a-z')"
  if [ -n "$CUR" ] && [ -n "$WANT" ] && [ "$CUR" != "$WANT" ]; then
    sed -i "s/$CUR/$WANT/Ig" "$NP"
    ACTION="mac:$CUR->$WANT"
  fi
  chmod 600 "$NP" 2>/dev/null
  netplan apply >/dev/null 2>&1 && [ "$ACTION" = "none" ] && ACTION="reapply"
else
  ACTION="no-netplan"
fi
# filet : remonter l'interphace principale
IFACE="$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|veth|br-|tap)' | head -1)"
[ -n "$IFACE" ] && ip link set "$IFACE" up 2>/dev/null
sleep 3
if have_ip; then echo "RESULT=fixed($ACTION)"; else echo "RESULT=still-down($ACTION)"; fi
ip -4 -o addr show 2>/dev/null | grep -vE ' lo '
GUEST
}

# Exécute le fix dans la VM via `qm guest exec` sur le nœud hôte (ssh par nom de nœud).
run_guest_fix() {  # $1=vmid $2=node $3=mac
    local vmid="$1" node="$2" mac="$3"
    local b64; b64="$(guest_fix_script | base64 -w0)"
    # bash -c '...' : décode le script, l'exécute avec la MAC en argument ($0=_ , $1=mac)
    local inner="echo ${b64} | base64 -d | bash -s ${mac}"
    ssh "${SSH_OPTS[@]}" "root@${node}" \
        "qm guest exec ${vmid} -- bash -c $(printf '%q' "$inner") 2>&1" \
      | python3 -c 'import sys,json
raw=sys.stdin.read()
try:
    d=json.loads(raw); print((d.get("out-data") or d.get("err-data") or "").strip())
except Exception: print(raw.strip()[:300])'
}

is_omega_conf() { grep -qE '(^|[#[:space:]])omega_[a-z_]+' "$1" 2>/dev/null; }

declare -A WANT_VMID
if [[ -n "$ONLY_VMIDS" ]]; then for v in ${ONLY_VMIDS//,/ }; do WANT_VMID["$v"]=1; done; fi

n_ok=0; n_fixed=0; n_fail=0; n_skip=0
$DRY && warn "MODE DRY-RUN : détection seulement, aucune modification."
info "Réconciliation réseau des VMs Omega (MAC netplan ≠ net0 → eth0 down)"

for f in /etc/pve/nodes/*/qemu-server/*.conf; do
    [[ -e "$f" ]] || continue
    vmid="$(basename "$f" .conf)"
    [[ -n "$ONLY_VMIDS" && -z "${WANT_VMID[$vmid]:-}" ]] && continue
    $ALL_VMS || is_omega_conf "$f" || continue
    st="${STATUS[$vmid]:-unknown}"; nd="${NODE[$vmid]:-}"
    [[ "$st" == "running" ]] || { n_skip=$((n_skip+1)); continue; }

    ip="$(resolve_ip "$vmid" "$nd")"
    if [[ -n "$ip" ]]; then
        n_ok=$((n_ok+1)); continue   # déjà en ligne → rien à faire
    fi

    mac="$(net0_mac "$f")"
    if [[ -z "$mac" ]]; then warn "vm ${vmid} (${nd}) sans IP mais net0 MAC introuvable → ignorée"; n_skip=$((n_skip+1)); continue; fi
    warn "vm ${vmid} (${nd}) running SANS IP — net0 MAC=${mac} → réparation netplan"
    if $DRY; then info "    (dry-run) corrigerait la MAC netplan vers ${mac} via guest agent"; n_skip=$((n_skip+1)); continue; fi

    out="$(run_guest_fix "$vmid" "$nd" "$mac")"
    echo "$out" | sed 's/^/      /'
    if echo "$out" | grep -q 'RESULT=fixed'; then
        ok "vm ${vmid} réparée ✓"; n_fixed=$((n_fixed+1))
    elif echo "$out" | grep -q 'RESULT=already-up'; then
        n_ok=$((n_ok+1))
    else
        warn "vm ${vmid} non réparée (voir ci-dessus)"; n_fail=$((n_fail+1))
    fi
done

ok "Terminé : ${n_ok} déjà OK, ${n_fixed} réparées, ${n_fail} en échec, ${n_skip} ignorées."
[[ "$n_fail" -eq 0 ]]
