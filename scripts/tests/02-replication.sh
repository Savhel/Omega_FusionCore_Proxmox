#!/usr/bin/env bash
# Test 2 — Réplication write-through sur 2 stores
# Usage : ./02-replication.sh
# Prérequis : binaires compilés, userfaultfd autorisé

source "$(dirname "$0")/lib.sh"

header "Test 2 — Réplication 2 stores"

require_omega_bins

step "Démarrage stores s0 et s1"
start_store "s0" 9100 9200
start_store "s1" 9101 9201

step "Agent demo avec réplication activée"
t0=$SECONDS
output=$("$AGENT_BIN" \
    --stores "127.0.0.1:9100,127.0.0.1:9101" \
    --status-addrs "127.0.0.1:9200,127.0.0.1:9201" \
    --vm-id 2 \
    --vm-requested-mib 64 \
    --region-mib 64 \
    --replication-enabled \
    --mode demo 2>&1) || true

echo "$output"

step "Vérification intégrité"
echo "$output" | grep -q "SUCCÈS" || fail "scénario demo échoué"

step "Vérification pages sur les deux stores"
pages0=$(curl -sf "http://127.0.0.1:9200/status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('page_count',0))")
pages1=$(curl -sf "http://127.0.0.1:9201/status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('page_count',0))")
info "store s0 : $pages0 pages"
info "store s1 : $pages1 pages"

[[ "$pages0" -gt 0 ]] || fail "store s0 ne contient aucune page"
[[ "$pages1" -gt 0 ]] || fail "store s1 ne contient aucune page (réplication inactive ?)"

pass "réplication OK ($(elapsed $t0)s) — s0=$pages0 pages, s1=$pages1 pages"
