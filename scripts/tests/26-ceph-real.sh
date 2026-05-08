#!/usr/bin/env bash
# Test 26 — Ceph réel : librados, ceph.conf, pool, exposition status Omega.
# Usage : ./26-ceph-real.sh [pool]

set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOL="${1:-${OMEGA_CEPH_POOL:-omega-pages}}"

header "Test 26 — Ceph réel (pool $POOL)"

require_cluster

for node in "${OMEGA_NODES_ARR[@]}"; do
    step "Nœud $node — packages/config Ceph"
    ssh_run "$node" "test -f /etc/ceph/ceph.conf" \
        || fail "$node : /etc/ceph/ceph.conf absent"
    ssh_run "$node" "ldconfig -p 2>/dev/null | grep -q librados" \
        || fail "$node : librados absent — installer librados-dev/ceph-common puis recompiler"
    pass "$node : ceph.conf + librados OK"

    step "Nœud $node — ceph status/pool"
    if ssh_run "$node" "command -v ceph >/dev/null && ceph status --connect-timeout 5 >/tmp/omega-ceph-status.txt 2>&1"; then
        ssh_run "$node" "head -20 /tmp/omega-ceph-status.txt" | sed 's/^/    /'
    else
        fail "$node : ceph status échoue"
    fi

    if ssh_run "$node" "ceph osd pool ls 2>/dev/null | grep -qx '${POOL}'"; then
        pass "$node : pool $POOL présent"
    else
        fail "$node : pool $POOL absent"
    fi
done

step "Status Omega — ceph_enabled"
ceph_ok=0
for node in "${OMEGA_NODES_ARR[@]}"; do
    status=$(curl -sf "http://${node}:${STATUS_PORT}/status" 2>/dev/null || curl -sf "http://${node}:${STATUS_PORT}/api/status" 2>/dev/null || echo "{}")
    enabled=$(printf '%s' "$status" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ceph_enabled", False))' 2>/dev/null || echo "False")
    info "$node : ceph_enabled=$enabled"
    [[ "$enabled" == "True" || "$enabled" == "true" ]] && ceph_ok=$((ceph_ok + 1))
done

[[ "$ceph_ok" -gt 0 ]] || fail "aucun store Omega ne déclare ceph_enabled=true"
pass "Ceph réel validé côté cluster Omega"
