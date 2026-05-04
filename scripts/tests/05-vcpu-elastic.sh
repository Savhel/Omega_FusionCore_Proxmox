#!/usr/bin/env bash
# Test 5 — vCPU élastique (hotplug + scale-up sous charge)
# Usage : ./05-vcpu-elastic.sh [vmid]
# Prérequis : nœud Proxmox, VM démarrée, qm accessible, stress-ng dans la VM

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"

header "Test 5 — vCPU élastique (VM $VMID)"

step "Vérifications prérequis"
require_bin qm
qm status "$VMID" | grep -q "running" || fail "VM $VMID n'est pas démarrée (qm start $VMID)"
pass "VM $VMID en cours d'exécution"

step "État initial vCPU"
vcpus_init=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "1")
info "vCPUs actuels : $vcpus_init"

step "Démarrage agent avec vCPU initial=1, max=4"
LOG_AGENT="/tmp/omega-agent-vcpu.log"
_TMPFILES+=("$LOG_AGENT")
"$AGENT_BIN" \
    --stores "${PVE2}:9100,${PVE3}:9100" \
    --status-addrs "${PVE2}:9200,${PVE3}:9200" \
    --vm-id "$VMID" \
    --vm-requested-mib 2048 \
    --region-mib 2048 \
    --vm-vcpus 4 \
    --vm-initial-vcpus 1 \
    --vcpu-high-threshold-pct 60 \
    --vcpu-low-threshold-pct 20 \
    --vcpu-scale-interval-secs 10 \
    --vcpu-overcommit-ratio 3 \
    --current-node "$(hostname)" \
    --mode daemon >"$LOG_AGENT" 2>&1 &
_PIDS+=($!)
AGENT_PID=$!
sleep 3

step "Vérification vCPU initial = 1"
vcpus_current=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "?")
info "vCPUs après démarrage agent : $vcpus_current"
[[ "${vcpus_current:-1}" -le 2 ]] || warn "vCPUs déjà > 2 au démarrage ($vcpus_current)"

step "Pool vCPU partagé"
if [[ -f /run/omega-vcpu-pool.json ]]; then
    cat /run/omega-vcpu-pool.json | python3 -m json.tool 2>/dev/null || cat /run/omega-vcpu-pool.json
else
    warn "/run/omega-vcpu-pool.json absent (normal si premier démarrage)"
fi

step "Simulation charge CPU (stress-ng dans la VM — 60s)"
info "Lance stress-ng dans la VM : qm guest exec $VMID -- stress-ng --cpu 0 --timeout 60s"
info "(ou depuis l'intérieur de la VM)"
qm guest exec "$VMID" -- stress-ng --cpu 0 --timeout 60s &>/dev/null &
STRESS_PID=$!

step "Surveillance scale-up pendant 70s"
t0=$SECONDS
vcpus_max=1
while [[ $(elapsed $t0) -lt 70 ]]; do
    vcpus_now=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "1")
    [[ "${vcpus_now:-1}" -gt "$vcpus_max" ]] && vcpus_max="$vcpus_now"
    printf "\r  [%3ds] vCPUs actifs : %-3s (max observé : %s)" "$(elapsed $t0)" "${vcpus_now:-?}" "$vcpus_max"
    sleep 3
done
echo ""

kill "$STRESS_PID" 2>/dev/null || true

step "Surveillance scale-down (60s sans charge)"
info "Attente scale-down..."
t0=$SECONDS
while [[ $(elapsed $t0) -lt 60 ]]; do
    vcpus_now=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "?")
    printf "\r  [%3ds] vCPUs actifs : %s" "$(elapsed $t0)" "${vcpus_now:-?}"
    sleep 5
done
echo ""

vcpus_final=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "?")
info "vCPUs finaux : $vcpus_final"

step "Résultats"
info "vCPU initial : $vcpus_init | max observé sous charge : $vcpus_max | final : $vcpus_final"

[[ "$vcpus_max" -gt "${vcpus_init:-1}" ]] || fail "aucun scale-up observé sous charge (toujours $vcpus_max vCPUs)"

step "Logs agent (scale events)"
grep -i "vcpu\|scale\|ajust" "$LOG_AGENT" | head -20 || warn "aucun log vCPU trouvé"

pass "vCPU élastique OK — scale-up de ${vcpus_init} à ${vcpus_max} vCPUs détecté"
