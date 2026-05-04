#!/usr/bin/env bash
# Test M1 — Mixte RAM + CPU : une VM grossit simultanément sur les deux axes
# L'agent doit évincer des pages ET faire du hotplug vCPU en même temps
# Usage : ./11-mixed-ram-cpu.sh [vmid]
# Prérequis : cluster Proxmox, stress-ng disponible dans la VM

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"

header "Test M1 — Mixte RAM + CPU (VM $VMID)"
print_cluster_config

step "Prérequis"
require_cluster
require_vm_running "$VMID"

step "État initial"
vcpus_init=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "1")
node_init=$(vm_node "$VMID")
ram_free_init=$(curl -sf "http://${COMPUTE_NODE}:${STATUS_PORT}/status" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('available_mib','?'))" || echo "?")
info "VM $VMID sur $node_init | vCPUs=$vcpus_init | RAM libre nœud=${ram_free_init} Mio"

step "Démarrage agent (éviction agressive + vCPU élastique)"
LOG="/tmp/omega-m1.log"
_TMPFILES+=("$LOG")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --status-addrs "$STATUS_CSV" \
    --vm-id "$VMID" \
    --vm-requested-mib 4096 \
    --region-mib 4096 \
    --current-node "$COMPUTE_NODE" \
    --eviction-threshold-mib 999999 \
    --eviction-batch-size 32 \
    --eviction-interval-secs 3 \
    --vm-vcpus 8 \
    --vm-initial-vcpus 1 \
    --vcpu-high-threshold-pct 60 \
    --vcpu-low-threshold-pct 20 \
    --vcpu-scale-interval-secs 10 \
    --metrics-listen "${COMPUTE_NODE}:${METRICS_PORT}" \
    --mode daemon >"$LOG" 2>&1 &
_PIDS+=($!)
wait_http "http://${COMPUTE_NODE}:${METRICS_PORT}/metrics" 20

step "Charge simultanée RAM + CPU dans la VM (90s)"
info "stress-ng --vm 1 --vm-bytes 70% --cpu 0 --timeout 90s"
qm guest exec "$VMID" -- stress-ng --vm 1 --vm-bytes 70% --cpu 0 --timeout 90s &>/dev/null &
_PIDS+=($!)

step "Surveillance simultanée évictions + vCPUs pendant 100s"
t0=$SECONDS
vcpus_max=1; evicted_max=0

while [[ $(elapsed $t0) -lt 100 ]]; do
    evicted=$(curl -sf "http://${COMPUTE_NODE}:${METRICS_PORT}/metrics" | \
        grep "^pages_evicted " | awk '{print $2}' | head -1 || echo 0)
    vcpus_now=$(qm config "$VMID" | grep "^vcpus:" | awk '{print $2}' || echo "?")
    pages_stores=0
    for n in "${STORE_NODES_ARR[@]}"; do
        pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
        pages_stores=$((pages_stores + pc))
    done

    [[ "${vcpus_now:-1}" -gt "$vcpus_max" ]] && vcpus_max="$vcpus_now"
    [[ "${evicted%.*}" -gt "$evicted_max" ]] && evicted_max="${evicted%.*}"

    printf "\r  [%3ds] vCPUs=%-3s(max=%s)  pages_évincées=%-6s  pages_stores=%-6s" \
        "$(elapsed $t0)" "${vcpus_now:-?}" "$vcpus_max" "${evicted:-0}" "$pages_stores"
    sleep 5
done
echo ""

step "Résultats"
info "vCPU initial=$vcpus_init | vCPU max sous charge=$vcpus_max"
info "Pages évincées max=$evicted_max"

all_stores_status

FAILS=0
[[ "$vcpus_max" -gt "$vcpus_init" ]] || \
    { warn "aucun scale-up vCPU détecté (max=$vcpus_max)"; ((FAILS++)) || true; }
[[ "$evicted_max" -gt 0 ]] || \
    { warn "aucune page évincée vers les stores"; ((FAILS++)) || true; }

step "Logs agent (extraits)"
grep -i "vcpu\|scale\|évict\|evict\|ajust" "$LOG" | head -20

[[ $FAILS -eq 0 ]] && \
    pass "M1 OK — scale-up vCPU ($vcpus_init→$vcpus_max) + éviction RAM ($evicted_max pages) simultanés" || \
    fail "M1 échoué — $FAILS axe(s) non fonctionnel(s)"
