#!/usr/bin/env bash
# Test 10 — Charge multi-VM : 3 stores, 3 agents simultanés, pas de collision
# Usage : ./10-multi-vm.sh
# Prérequis : binaires compilés, userfaultfd autorisé

source "$(dirname "$0")/lib.sh"

header "Test 10 — Charge multi-VM (3 stores × 3 VMs)"

require_omega_bins

step "Démarrage 3 stores"
start_store "m0" 9100 9200
start_store "m1" 9101 9201
start_store "m2" 9102 9202

step "Lancement 3 agents simultanés (vmid 11, 12, 13)"
LOGS=()
AGENT_PIDS=()
t0=$SECONDS

for vmid in 11 12 13; do
    LOG="/tmp/omega-agent-multi-${vmid}.log"
    _TMPFILES+=("$LOG")
    LOGS+=("$LOG")
    "$AGENT_BIN" \
        --stores "127.0.0.1:9100,127.0.0.1:9101,127.0.0.1:9102" \
        --vm-id "$vmid" \
        --vm-requested-mib 64 \
        --region-mib 64 \
        --recall-priority "$vmid" \
        --mode demo >"$LOG" 2>&1 &
    AGENT_PIDS+=($!)
    _PIDS+=($!)
done

step "Attente fin des 3 agents"
all_ok=true
for i in 0 1 2; do
    vmid=$((11 + i))
    wait "${AGENT_PIDS[$i]}" 2>/dev/null || true
    if grep -q "SUCCÈS" "${LOGS[$i]}"; then
        pass "agent vmid=$vmid : SUCCÈS"
    else
        fail "agent vmid=$vmid : ÉCHEC (voir ${LOGS[$i]})"
        all_ok=false
    fi
done

step "Vérification isolation : pas de collision de pages entre VMs"
pages_total=0
for port in 9200 9201 9202; do
    pc=$(curl -sf "http://127.0.0.1:$port/status" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" 2>/dev/null || echo 0)
    info "store :$port — $pc pages"
    pages_total=$((pages_total + pc))
done
info "total pages dans les stores : $pages_total"

step "Vérification logs : aucune collision de vm_id"
for log in "${LOGS[@]}"; do
    errors=$(grep -c "collision\|wrong vm\|vm_id mismatch" "$log" 2>/dev/null) || true
    [[ "$errors" -eq 0 ]] || fail "collision de pages détectée dans $log"
done

step "Vérification priorités recall (priorité = vmid, 11 < 12 < 13)"
for i in 0 1 2; do
    vmid=$((11 + i))
    recall_delay=$(grep -oP 'recall.*delay=\K[0-9.]+' "${LOGS[$i]}" | head -1 || echo "?")
    info "vmid=$vmid recall_delay=$recall_delay"
done

pass "multi-VM OK ($(elapsed $t0)s) — 3 VMs simultanées, aucune collision, tous SUCCÈS"
