#!/usr/bin/env bash
# Test 3 — Résilience : failover automatique si store primaire tombe
# Usage : ./03-failover.sh
# Prérequis : binaires compilés, userfaultfd autorisé

source "$(dirname "$0")/lib.sh"

header "Test 3 — Failover store"

require_omega_bins

step "Démarrage stores s0 (primaire) et s1 (secondaire)"
start_store "fa0" 9100 9200
start_store "fa1" 9101 9201
PID_S0="${_PIDS[0]}"

step "Phase 1 : éviction des pages vers les 2 stores (réplication)"
output=$("$AGENT_BIN" \
    --stores "127.0.0.1:9100,127.0.0.1:9101" \
    --status-addrs "127.0.0.1:9200,127.0.0.1:9201" \
    --vm-id 3 \
    --vm-requested-mib 64 \
    --region-mib 64 \
    --replication-enabled \
    --mode demo 2>&1) || true

echo "$output" | grep -q "SUCCÈS" || fail "phase 1 échouée (éviction/demo)"
pages_before=$(curl -sf "http://127.0.0.1:9201/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))")
info "pages sur s1 avant failover : $pages_before"
[[ "$pages_before" -gt 0 ]] || fail "s1 n'a aucune page — réplication non effective"

step "Phase 2 : arrêt brutal du store primaire s0"
kill "$PID_S0" 2>/dev/null || true
sleep 1
nc -z 127.0.0.1 9100 && fail "store s0 toujours actif après kill"
info "store s0 tué"

step "Phase 3 : vérification que s1 répond encore"
wait_http "http://127.0.0.1:9201/status" 5
pages_after=$(curl -sf "http://127.0.0.1:9201/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))")
info "pages sur s1 après failover : $pages_after"
[[ "$pages_after" -eq "$pages_before" ]] || warn "nombre de pages a changé (${pages_before} → ${pages_after})"

step "Phase 4 : lecture depuis le store survivant (agent demo sans s0)"
output2=$("$AGENT_BIN" \
    --stores "127.0.0.1:9101" \
    --vm-id 3 \
    --vm-requested-mib 64 \
    --region-mib 64 \
    --mode demo 2>&1) || true
echo "$output2"
echo "$output2" | grep -q "SUCCÈS" || fail "recall depuis store secondaire échoué après perte du primaire"

pass "failover OK — les pages sont accessibles depuis s1 malgré la perte de s0"
