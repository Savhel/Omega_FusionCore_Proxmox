#!/usr/bin/env bash
# Test M1 — Mixte RAM + CPU : une VM grossit simultanément sur les deux axes
# L'agent doit évincer des pages ET faire du hotplug vCPU en même temps
# Usage : ./11-mixed-ram-cpu.sh [vmid]
# Prérequis : cluster Proxmox, stress-ng disponible dans la VM

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
require_vm_running "$VMID"
VMID="$SELECTED_VMID"
ensure_omega_vcpu_profile "$VMID"
VM_RAM_MIB=$(vm_ram_mib "$VMID"); VM_RAM_MIB="${VM_RAM_MIB:-1024}"
VM_CORES=$(vm_cores "$VMID");     VM_CORES="${VM_CORES:-4}"

header "Test M1 — Mixte RAM + CPU (VM $VMID)"
print_cluster_config

step "Prérequis"
require_cluster

step "Remise à 1 vCPU (état de référence avant le test)"
# Hot-unplug SANS arrêt : un stop/restart d'une VM omega déclenche les hooks de paging
# (~2 min) → échec/timeout du redémarrage. Les VM omega ont hotplug=cpu, donc le hot-set
# suffit. Stop/restart seulement en secours si le hot-set n'aboutit pas.
if qm set "$VMID" --vcpus 1 >/dev/null 2>&1 && sleep 3 && \
   [[ "$(vm_runtime_vcpus "$VMID" 2>/dev/null || echo 0)" == "1" ]]; then
    info "vCPU ramené à 1 à chaud (sans redémarrage)"
else
    stop_vm_for_reconfig "$VMID"
    qm set "$VMID" --vcpus 1 >/dev/null
    start_vm_with_hostpci_repair "$VMID" >/dev/null || fail "impossible de redémarrer la VM $VMID avec 1 vCPU runtime"
fi
sleep 5
for _ in $(seq 1 30); do
    guest_agent_ready "$VMID" && break
    sleep 2
done

step "État initial"
vcpus_init="$(vm_runtime_vcpus "$VMID" || true)"
[[ -n "$vcpus_init" ]] || fail "impossible de lire les vCPUs runtime via QMP/qm monitor"
node_init=$(vm_node "$VMID")
[[ -n "$node_init" ]] || fail "impossible de déterminer le nœud Proxmox de la VM $VMID"
METRICS_BIND_HOST="${OMEGA_M1_METRICS_BIND_HOST:-127.0.0.1}"
METRICS_LISTEN="${METRICS_BIND_HOST}:${METRICS_PORT}"
METRICS_URL="http://127.0.0.1:${METRICS_PORT}/metrics"
ram_free_init=$(curl -sf "http://${node_init}:${STATUS_PORT}/status" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('available_mib','?'))" || echo "?")
info "VM $VMID sur $node_init | vCPUs runtime=$vcpus_init | RAM libre nœud=${ram_free_init} Mio"

step "Démarrage agent (éviction agressive + vCPU élastique)"
LOG="/tmp/omega-m1.log"
_TMPFILES+=("$LOG")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --status-addrs "$STATUS_CSV" \
    --vm-id "$VMID" \
    --vm-requested-mib "$VM_RAM_MIB" \
    --region-mib "$VM_RAM_MIB" \
    --current-node "$node_init" \
    --eviction-threshold-mib 999999 \
    --eviction-batch-size 32 \
    --eviction-interval-secs 3 \
    --vm-vcpus "$VM_CORES" \
    --vm-initial-vcpus 1 \
    --vcpu-high-threshold-pct 60 \
    --vcpu-low-threshold-pct 20 \
    --vcpu-scale-interval-secs 10 \
    --metrics-listen "$METRICS_LISTEN" \
    --mode daemon >"$LOG" 2>&1 &
_PIDS+=($!)
metrics_ready=0
for _ in $(seq 1 20); do
    if curl -sf "$METRICS_URL" >/dev/null 2>&1; then
        metrics_ready=1
        break
    fi
    sleep 1
done
if [[ "$metrics_ready" -ne 1 ]]; then
    warn "endpoint metrics M1 indisponible: $METRICS_URL"
    warn "log agent M1:"
    tail -80 "$LOG" || true
    fail "URL $METRICS_URL non disponible après 20s"
fi

step "Charge simultanée RAM + CPU dans la VM (90s)"
info "stress-ng --vm 1 --vm-bytes 70% --cpu 0 --timeout 90s"
ensure_guest_packages "$VMID" stress-ng qemu-guest-agent || true
# Charge combinée RAM+CPU. Fallback 'stress' (classique, libc seul) si stress-ng absent
# du guest (VLAN omega isolé → apt KO) : 'stress' gère aussi --cpu + --vm dans un seul
# appel. Lancé détaché (setsid) + nice pour saturer sans affamer le QGA ; --vm-bytes en
# octets absolus calculés depuis MemTotal (70%).
if qm guest exec "$VMID" -- stress-ng --vm 1 --vm-bytes 70% --cpu 0 --timeout 90s &>/dev/null 2>&1; then
    :
elif qm guest exec "$VMID" -- /bin/sh -c 'command -v stress >/dev/null 2>&1 || exit 1; kb=$(awk "/MemTotal/{print \$2}" /proc/meminfo); vb=$(( kb*1024*70/100 )); setsid nice -n 19 stress --cpu 4 --vm 1 --vm-bytes "$vb" --timeout 90s </dev/null >/dev/null 2>&1 & echo started' 2>/dev/null | grep -q started; then
    info "charge RAM+CPU via 'stress' (fallback détaché, sans stress-ng)"
else
    fail "qemu-guest-agent/stress(-ng) indisponible dans la VM $VMID — M1 exige une vraie pression RAM+CPU dans l'invité"
fi

step "Surveillance simultanée évictions + vCPUs pendant 100s"
t0=$SECONDS
vcpus_max="$vcpus_init"; evicted_max=0

while [[ $(elapsed $t0) -lt 100 ]]; do
    evicted=$(curl -sf "$METRICS_URL" | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('pages_evicted',0))" 2>/dev/null || echo 0)
    vcpus_now="$(vm_runtime_vcpus "$VMID" || true)"
    pages_stores=0
    for n in "${STORE_NODES_ARR[@]}"; do
        pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
        pages_stores=$((pages_stores + pc))
    done

    [[ -n "$vcpus_now" && "${vcpus_now:-1}" -gt "$vcpus_max" ]] && vcpus_max="$vcpus_now"
    [[ "${evicted%.*}" -gt "$evicted_max" ]] && evicted_max="${evicted%.*}"

    printf "\r  [%3ds] vCPUs runtime=%-3s(max=%s)  pages_évincées=%-6s  pages_stores=%-6s" \
        "$(elapsed $t0)" "${vcpus_now:-?}" "$vcpus_max" "${evicted:-0}" "$pages_stores"
    sleep 5
done
echo ""

step "Résultats"
info "vCPU runtime initial=$vcpus_init | vCPU max sous charge=$vcpus_max"
info "Pages évincées max=$evicted_max"

all_stores_status

FAILS=0
[[ "$vcpus_max" -gt "$vcpus_init" ]] || \
    { warn "aucun scale-up vCPU détecté (max=$vcpus_max)"; ((FAILS++)) || true; }
[[ "$evicted_max" -gt 0 ]] || \
    { warn "aucune page évincée vers les stores"; ((FAILS++)) || true; }

step "Logs agent (extraits)"
grep -i "vcpu\|scale\|évict\|evict\|ajust" "$LOG" | head -20 || true

[[ $FAILS -eq 0 ]] && \
    pass "M1 OK — scale-up vCPU ($vcpus_init→$vcpus_max) + éviction RAM ($evicted_max pages) simultanés" || \
    fail "M1 échoué — $FAILS axe(s) non fonctionnel(s)"
