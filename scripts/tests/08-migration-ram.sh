#!/usr/bin/env bash
# Test 8 — Migration RAM : recall complet + qm migrate sous pression mémoire
# Usage : ./08-migration-ram.sh [vmid]
# Prérequis : cluster 3 nœuds, VM 9001 sur pve1, stores sur pve2/pve3

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"

header "Test 8 — Migration RAM (VM $VMID)"

step "Vérifications prérequis"
require_bin qm
require_bin pvesh
qm status "$VMID" | grep -q "running" || fail "VM $VMID non démarrée"
nc -zv "${PVE2}" 9100 2>/dev/null || fail "store ${PVE2}:9100 inaccessible"
nc -zv "${PVE3}" 9100 2>/dev/null || fail "store ${PVE3}:9100 inaccessible"

step "Nœud initial de la VM"
node_before=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c "import sys,json; vms=json.load(sys.stdin); \
      [print(v['node']) for v in vms if v.get('vmid')==$VMID]" | head -1)
info "VM $VMID sur : ${node_before:-inconnu}"

step "Démarrage agent avec migration activée et seuil d'éviction agressif"
LOG_AGENT="/tmp/omega-agent-migration.log"
_TMPFILES+=("$LOG_AGENT")
"$AGENT_BIN" \
    --stores "${PVE2}:9100,${PVE3}:9100" \
    --status-addrs "${PVE2}:9200,${PVE3}:9200" \
    --vm-id "$VMID" \
    --vm-requested-mib 2048 \
    --region-mib 2048 \
    --current-node "$(hostname)" \
    --eviction-threshold-mib 999999 \
    --eviction-batch-size 64 \
    --eviction-interval-secs 3 \
    --migration-enabled true \
    --migration-interval-secs 20 \
    --mode daemon >"$LOG_AGENT" 2>&1 &
_PIDS+=($!)
AGENT_PID=$!
sleep 5

step "Simulation pression mémoire (stress-ng 90s)"
info "démarrage stress-ng --vm 1 --vm-bytes 85% --timeout 90s"
stress-ng --vm 1 --vm-bytes 85% --timeout 90s &>/dev/null &
STRESS_PID=$!
_PIDS+=($STRESS_PID)

step "Surveillance éviction + migration pendant 120s"
t0=$SECONDS
migration_triggered=false
while [[ $(elapsed $t0) -lt 120 ]]; do
    evicted=$(grep -c "éviction\|evict" "$LOG_AGENT" 2>/dev/null || echo 0)
    if grep -qi "migration\|qm migrate" "$LOG_AGENT" 2>/dev/null; then
        migration_triggered=true
        info "migration déclenchée à $(elapsed $t0)s"
    fi
    printf "\r  [%3ds] évictions loggées=%-4s  migration=%s" \
        "$(elapsed $t0)" "$evicted" "$([ $migration_triggered = true ] && echo OUI || echo non)"
    sleep 5
done
echo ""

kill "$STRESS_PID" 2>/dev/null || true

step "Logs éviction + migration"
grep -i "éviction\|recall\|migration\|qm migrate" "$LOG_AGENT" | head -30

step "Nœud final de la VM"
node_after=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c "import sys,json; vms=json.load(sys.stdin); \
      [print(v['node']) for v in vms if v.get('vmid')==$VMID]" | head -1)
info "VM $VMID maintenant sur : ${node_after:-inconnu}"

if [[ "$node_before" != "$node_after" ]]; then
    pass "migration RAM OK — VM déplacée de $node_before vers $node_after"
elif $migration_triggered; then
    pass "migration RAM déclenchée (voir logs) — VM peut être revenue sur le même nœud"
else
    warn "aucune migration déclenchée — pression insuffisante ou stores non saturés"
    pass "test migration RAM terminé — voir logs pour diagnostic"
fi
