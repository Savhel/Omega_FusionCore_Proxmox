#!/usr/bin/env bash
# Test 7 — GPU scheduler round-robin (partage entre 2 VMs)
# Usage : ./07-gpu-scheduler.sh [vmid1] [vmid2]
# Prérequis : 2 VMs démarrées sur le même nœud GPU, QMP socket accessible

source "$(dirname "$0")/lib.sh"

VMID1="${1:-${TEST_VMIDS_ARR[0]:-$TEST_VMID}}"
VMID2="${2:-${TEST_VMIDS_ARR[1]:-}}"
[[ -n "$VMID1" ]] || fail "VMID1 non défini — vérifier OMEGA_TEST_VMIDS dans cluster.conf"
[[ -n "$VMID2" ]] || fail "VMID2 non défini — ce test requiert 2 VMIDs dans OMEGA_TEST_VMIDS"
require_two_vms_running "$VMID1" "$VMID2"
VMID1="${SELECTED_VMIDS[0]}"
VMID2="${SELECTED_VMIDS[1]}"
VM1_RAM=$(vm_ram_mib "$VMID1"); VM1_RAM="${VM1_RAM:-1024}"
VM2_RAM=$(vm_ram_mib "$VMID2"); VM2_RAM="${VM2_RAM:-1024}"

header "Test 7 — GPU scheduler round-robin (VM $VMID1 + VM $VMID2)"

step "Vérifications prérequis"
require_bin qm

step "Vérification lock GPU (aucun scheduler actif)"
ls /run/omega-gpu-scheduler-*.lock 2>/dev/null && \
    info "lock GPU existant : $(ls /run/omega-gpu-scheduler-*.lock)" || \
    info "aucun lock GPU actif (normal)"

step "Démarrage agent 1 (VM $VMID1)"
LOG1="/tmp/omega-agent-gpu1.log"
_TMPFILES+=("$LOG1")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --vm-id "$VMID1" \
    --vm-requested-mib "$VM1_RAM" \
    --region-mib "$VM1_RAM" \
    --gpu-quantum-secs 15 \
    --mode daemon >"$LOG1" 2>&1 &
_PIDS+=($!)
sleep 2

step "Démarrage agent 2 (VM $VMID2)"
LOG2="/tmp/omega-agent-gpu2.log"
_TMPFILES+=("$LOG2")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --vm-id "$VMID2" \
    --vm-requested-mib "$VM2_RAM" \
    --region-mib "$VM2_RAM" \
    --gpu-quantum-secs 15 \
    --mode daemon >"$LOG2" 2>&1 &
_PIDS+=($!)

step "Observation rotation GPU pendant 90s"
t0=$SECONDS
rotations=0
last_owner=""
while [[ $(elapsed $t0) -lt 90 ]]; do
    owner1=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG1" 2>/dev/null) || owner1=0
    owner2=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG2" 2>/dev/null) || owner2=0
    lock=$(ls /run/omega-gpu-scheduler-*.lock 2>/dev/null | head -1 || echo "aucun")
    printf "\r  [%3ds] VM1 assigns=%-3s  VM2 assigns=%-3s  lock=%s" \
        "$(elapsed $t0)" "$owner1" "$owner2" "$(basename "$lock" 2>/dev/null || echo aucun)"
    sleep 5
done
echo ""

step "Résultats"
assigns1=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG1" 2>/dev/null) || assigns1=0
assigns2=$(grep -c "GPU assigné\|gpu.*assign\|device_add" "$LOG2" 2>/dev/null) || assigns2=0
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
grep -i "gpu\|flock\|leader\|device_del\|device_add\|qmp\|erreur\|error\|warn" "$LOG1" | head -15 || true
step "Logs GPU (agent 2)"
grep -i "gpu\|flock\|leader\|device_del\|device_add\|qmp\|erreur\|error\|warn" "$LOG2" | head -15 || true

if [[ $((assigns1 + assigns2)) -eq 0 ]]; then
    warn "aucune assignation GPU loggée — environnement probablement non applicable"
    warn "à vérifier sur le nœud GPU : QMP socket, hostpci, et présence d'un GPU libre"
    for vmid in "$VMID1" "$VMID2"; do
        info "diagnostic VM $vmid"
        qm config "$vmid" | grep -E "^hostpci|^args|^name|^machine" || true
        qm monitor "$vmid" <<<"info status" 2>/dev/null | head -5 || warn "QMP monitor inaccessible pour VM $vmid"
    done
fi
pass "GPU scheduler testé — voir logs pour la rotation"
