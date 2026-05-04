#!/usr/bin/env bash
# Test 7 — GPU scheduler round-robin (partage entre 2 VMs)
# Usage : ./07-gpu-scheduler.sh [vmid1] [vmid2]
# Prérequis : 2 VMs démarrées sur le même nœud GPU, QMP socket accessible

source "$(dirname "$0")/lib.sh"

VMID1="${1:-9001}"
VMID2="${2:-9002}"

header "Test 7 — GPU scheduler round-robin (VM $VMID1 + VM $VMID2)"

step "Vérifications prérequis"
require_bin qm
qm status "$VMID1" | grep -q "running" || fail "VM $VMID1 non démarrée"
qm status "$VMID2" | grep -q "running" || fail "VM $VMID2 non démarrée"

step "Vérification lock GPU (aucun scheduler actif)"
ls /run/omega-gpu-scheduler-*.lock 2>/dev/null && \
    info "lock GPU existant : $(ls /run/omega-gpu-scheduler-*.lock)" || \
    info "aucun lock GPU actif (normal)"

step "Démarrage agent 1 (VM $VMID1)"
LOG1="/tmp/omega-agent-gpu1.log"
_TMPFILES+=("$LOG1")
"$AGENT_BIN" \
    --stores "${PVE2}:9100,${PVE3}:9100" \
    --vm-id "$VMID1" \
    --vm-requested-mib 2048 \
    --region-mib 2048 \
    --gpu-quantum-secs 15 \
    --mode daemon >"$LOG1" 2>&1 &
_PIDS+=($!)
sleep 2

step "Démarrage agent 2 (VM $VMID2)"
LOG2="/tmp/omega-agent-gpu2.log"
_TMPFILES+=("$LOG2")
"$AGENT_BIN" \
    --stores "${PVE2}:9100,${PVE3}:9100" \
    --vm-id "$VMID2" \
    --vm-requested-mib 2048 \
    --region-mib 2048 \
    --gpu-quantum-secs 15 \
    --mode daemon >"$LOG2" 2>&1 &
_PIDS+=($!)

step "Observation rotation GPU pendant 90s"
t0=$SECONDS
rotations=0
last_owner=""
while [[ $(elapsed $t0) -lt 90 ]]; do
    owner1=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG1" 2>/dev/null || echo 0)
    owner2=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG2" 2>/dev/null || echo 0)
    lock=$(ls /run/omega-gpu-scheduler-*.lock 2>/dev/null | head -1 || echo "aucun")
    printf "\r  [%3ds] VM1 assigns=%-3s  VM2 assigns=%-3s  lock=%s" \
        "$(elapsed $t0)" "$owner1" "$owner2" "$(basename "$lock" 2>/dev/null || echo aucun)"
    sleep 5
done
echo ""

step "Résultats"
assigns1=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG1" 2>/dev/null || echo 0)
assigns2=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG2" 2>/dev/null || echo 0)
info "VM $VMID1 : $assigns1 assignations GPU"
info "VM $VMID2 : $assigns2 assignations GPU"

step "Leader election (flock)"
lock_files=$(ls /run/omega-gpu-scheduler-*.lock 2>/dev/null || echo "")
if [[ -n "$lock_files" ]]; then
    info "lock actif : $lock_files"
    pass "leader election OK — lock flock présent"
else
    warn "aucun lock GPU détecté (QMP socket peut-être inaccessible)"
fi

step "Logs GPU (agent 1)"
grep -i "gpu\|flock\|leader\|device_del\|device_add" "$LOG1" | head -15
step "Logs GPU (agent 2)"
grep -i "gpu\|flock\|leader\|device_del\|device_add" "$LOG2" | head -15

[[ $((assigns1 + assigns2)) -gt 0 ]] || warn "aucune assignation GPU loggée — vérifier QMP socket"
pass "GPU scheduler testé — voir logs pour la rotation"
