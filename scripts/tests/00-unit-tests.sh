#!/usr/bin/env bash
# Test 0 — Tests unitaires Rust (toujours en premier)
# Usage : ./00-unit-tests.sh
# Prérequis : cargo, workspace compilable

source "$(dirname "$0")/lib.sh"

header "Test 0 — Tests unitaires"

step "Compilation workspace"
cd "$REPO_ROOT"
cargo build --workspace --quiet || fail "compilation échouée"
pass "compilation OK"

step "Exécution tests unitaires"
output=$(cargo test --workspace -- --nocapture 2>&1)
echo "$output" | tail -20

failures=$(echo "$output" | grep -c "^FAILED" || true)
[[ "$failures" -eq 0 ]] || fail "$failures tests échoués"

total=$(echo "$output" | grep "^test result: ok" | awk '{sum+=$4} END{print sum}')
info "Total : $total tests"
[[ "${total:-0}" -ge 200 ]] || warn "moins de 200 tests — possible régression ($total trouvés)"

pass "tous les tests unitaires passent ($total tests)"
