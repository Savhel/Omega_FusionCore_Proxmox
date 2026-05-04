#!/usr/bin/env bash
# Test M4 — Stress cluster complet : RAM + CPU + stores sur tous les nœuds simultanément
# Vérifie la stabilité du système sous charge généralisée
# Usage : ./14-mixed-cluster-pressure.sh [nb_vms] [duree_secs]
# Prérequis : cluster N nœuds, N VMs démarrées (une par nœud ou plusieurs)

source "$(dirname "$0")/lib.sh"

NB_VMS="${1:-3}"
DUREE="${2:-120}"

header "Test M4 — Stress cluster complet ($NB_VMS VMs, ${DUREE}s)"
print_cluster_config

step "Prérequis"
require_cluster
require_bin stress-ng

step "Inventaire cluster avant stress"
info "$(node_count) nœuds, $(store_count) stores"
echo ""
for n in "${OMEGA_NODES_ARR[@]}"; do
    status=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
        python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f\"  {d.get('node_id','?'):12s}  ram={d.get('available_mib','?')} Mio  vcpu_free={d.get('vcpu_free','?')}  pages={d.get('page_count',0)}\")
" 2>/dev/null || echo "  $n : inaccessible")
    echo "$status"
done

step "Démarrage $NB_VMS agents (un par vmid)"
LOGS=()
BASE_VMID=9000
for i in $(seq 1 "$NB_VMS"); do
    vmid=$((BASE_VMID + i))
    LOG="/tmp/omega-m4-vm${vmid}.log"
    _TMPFILES+=("$LOG")
    LOGS+=("$LOG")
    # On démarre un agent par VM — si la VM n'existe pas, l'agent tourne quand même
    # (il ne peut pas faire de hotplug vCPU mais peut gérer la mémoire)
    "$AGENT_BIN" \
        --stores "$STORES_CSV" \
        --status-addrs "$STATUS_CSV" \
        --vm-id "$vmid" \
        --vm-requested-mib 512 \
        --region-mib 512 \
        --eviction-threshold-mib 999999 \
        --eviction-batch-size 32 \
        --eviction-interval-secs 3 \
        --mode daemon >"$LOG" 2>&1 &
    _PIDS+=($!)
    info "agent vmid=$vmid démarré (log: $LOG)"
done
sleep 3

step "Saturation RAM sur tous les nœuds"
for n in "${OMEGA_NODES_ARR[@]}"; do
    info "stress-ng --vm 1 --vm-bytes 75% sur $n"
    ssh_run_bg "$n" "stress-ng --vm 1 --vm-bytes 75% --timeout ${DUREE}s &>/dev/null"
done

step "Saturation CPU sur tous les nœuds"
for n in "${OMEGA_NODES_ARR[@]}"; do
    info "stress-ng --cpu 0 sur $n"
    ssh_run_bg "$n" "stress-ng --cpu 0 --timeout ${DUREE}s &>/dev/null"
done

step "Observation pendant ${DUREE}s"
t0=$SECONDS
declare -A pages_evicted_per_node
for n in "${STORE_NODES_ARR[@]}"; do pages_evicted_per_node["$n"]=0; done

while [[ $(elapsed $t0) -lt $DUREE ]]; do
    total_pages=0
    status_line=""
    for n in "${STORE_NODES_ARR[@]}"; do
        pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
        total_pages=$((total_pages + pc))
        status_line+="${n##*.}:${pc}  "
    done
    printf "\r  [%3ds/%ds] pages_stores=%s  (%s)" \
        "$(elapsed $t0)" "$DUREE" "$total_pages" "$status_line"
    sleep 10
done
echo ""

step "État cluster après stress"
for n in "${OMEGA_NODES_ARR[@]}"; do
    status=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
        python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f\"  {d.get('node_id','?'):12s}  ram={d.get('available_mib','?')} Mio  pages={d.get('page_count',0)}\")
" 2>/dev/null || echo "  $n : inaccessible")
    echo "$status"
done

step "Vérification stabilité"
errors_total=0
for log in "${LOGS[@]}"; do
    panics=$(grep -c "panic\|FATAL\|thread.*main.*panicked" "$log" 2>/dev/null || echo 0)
    [[ "$panics" -gt 0 ]] && { warn "panic dans $log"; ((errors_total++)) || true; }
done

total_pages_final=0
for n in "${STORE_NODES_ARR[@]}"; do
    pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
    total_pages_final=$((total_pages_final + pc))
done
info "Pages totales dans les stores : $total_pages_final"

step "Vérification que les stores sont toujours joignables"
stores_ok=0
for n in "${STORE_NODES_ARR[@]}"; do
    curl -sf "http://${n}:${STATUS_PORT}/status" &>/dev/null && \
        { pass "store $n toujours joignable"; ((stores_ok++)) || true; } || \
        warn "store $n inaccessible après le stress"
done

[[ $errors_total -eq 0 ]] || fail "M4 : $errors_total panic(s) détecté(s) dans les logs"
[[ $stores_ok -eq $(store_count) ]] || warn "$(( $(store_count) - stores_ok )) store(s) inaccessible(s)"

pass "M4 OK — cluster stable sous charge ($NB_VMS VMs, $(node_count) nœuds, ${DUREE}s)"
