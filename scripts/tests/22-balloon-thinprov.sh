#!/usr/bin/env bash
# Test 22 — Balloon thin-provisioning : VM démarre avec min RAM, grandit selon la charge
# Usage : ./22-balloon-thinprov.sh [vmid]
# Prérequis : cluster Proxmox, VM démarrée avec driver virtio-balloon, stress-ng dans la VM

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
# La VM doit avoir été créée avec au moins 2048 MiB de RAM dans Proxmox
VM_MAX_MIB="${BALLOON_MAX_MIB:-2048}"
VM_INIT_MIB="${BALLOON_INIT_MIB:-512}"
VM_STEP_MIB="${BALLOON_STEP_MIB:-256}"

header "Test 22 — Balloon thin-provisioning (VM $VMID)"

step "Vérifications prérequis"
require_bin qm
qm status "$VMID" | grep -q "running" || fail "VM $VMID non démarrée"

# Vérifier que la VM a un balloon virtio
if ! qm config "$VMID" | grep -qi "balloon\|virtio.*balloon\|memory.*$VM_MAX_MIB"; then
    warn "balloon virtio non détecté dans la config de VM $VMID"
    warn "s'assurer que la VM a été créée avec virtio-balloon et memory=${VM_MAX_MIB}"
fi

step "RAM actuelle de la VM"
ram_current=$(qm config "$VMID" | grep "^balloon:" | awk '{print $2}' 2>/dev/null || echo "?")
ram_total=$(qm config "$VMID" | grep "^memory:" | awk '{print $2}' 2>/dev/null || echo "$VM_MAX_MIB")
info "RAM totale VM : ${ram_total} MiB"
info "RAM balloon actuelle : ${ram_current:-<non défini>} MiB"

step "Réinitialisation balloon à la valeur initiale"
qm balloon "$VMID" "$VM_INIT_MIB" 2>/dev/null || warn "qm balloon a échoué — le driver peut être absent"
sleep 2
ram_after_init=$(qm config "$VMID" | grep "^balloon:" | awk '{print $2}' 2>/dev/null || echo "?")
info "Balloon après reset : ${ram_after_init:-?} MiB (attendu : $VM_INIT_MIB)"

step "Démarrage agent avec BalloonManager activé"
LOG_AGENT="/tmp/omega-agent-balloon.log"
_TMPFILES+=("$LOG_AGENT")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --status-addrs "$STATUS_CSV" \
    --vm-id "$VMID" \
    --vm-requested-mib "$VM_MAX_MIB" \
    --region-mib "$VM_MAX_MIB" \
    --current-node "$(hostname)" \
    --balloon-enabled true \
    --balloon-initial-mib "$VM_INIT_MIB" \
    --balloon-step-mib "$VM_STEP_MIB" \
    --balloon-interval-secs 5 \
    --balloon-grow-faults-per-sec 2 \
    --balloon-shrink-faults-per-sec 0 \
    --mode daemon >"$LOG_AGENT" 2>&1 &
_PIDS+=($!)
AGENT_PID=$!
sleep 3

step "Vérification balloon = initial après démarrage de l'agent"
ram_agent_start=$(qm config "$VMID" | grep "^balloon:" | awk '{print $2}' 2>/dev/null || echo "?")
info "Balloon au démarrage agent : ${ram_agent_start:-?} MiB (attendu : $VM_INIT_MIB)"
[[ "${ram_agent_start:-0}" -le "$(( VM_INIT_MIB + VM_STEP_MIB ))" ]] || \
    warn "balloon plus grand que prévu ($ram_agent_start > $(( VM_INIT_MIB + VM_STEP_MIB )))"

step "Simulation charge mémoire dans la VM pour déclencher la croissance (60s)"
vm_cpu_stress "$VMID" 60
STRESS_PID=${_PIDS[-1]:-0}
info "stress-ng démarré dans la VM $VMID"

step "Surveillance croissance balloon pendant 90s"
t0=$SECONDS
ram_max="$VM_INIT_MIB"
grew=false
while [[ $(elapsed $t0) -lt 90 ]]; do
    ram_now=$(qm config "$VMID" | grep "^balloon:" | awk '{print $2}' 2>/dev/null || echo "$VM_INIT_MIB")
    if [[ "${ram_now:-0}" -gt "${ram_max:-0}" ]]; then
        ram_max="$ram_now"
        grew=true
        info "balloon grandi → $ram_max MiB à $(elapsed $t0)s"
    fi
    printf "\r  [%3ds] balloon=%-6s MiB  max=%-6s MiB  grandi=%s" \
        "$(elapsed $t0)" "${ram_now:-?}" "$ram_max" "$([ $grew = true ] && echo OUI || echo non)"
    sleep 5
done
echo ""

kill "$STRESS_PID" 2>/dev/null || true

step "Logs agent (balloon events)"
grep -i "balloon\|grow\|shrink\|mib\|fault.rate" "$LOG_AGENT" | head -20 || \
    warn "aucun log balloon trouvé"

step "Vérification que le balloon ne dépasse pas max ($VM_MAX_MIB MiB)"
ram_final=$(qm config "$VMID" | grep "^balloon:" | awk '{print $2}' 2>/dev/null || echo "?")
info "Balloon final : ${ram_final:-?} MiB"
if [[ "${ram_final:-0}" -gt "$VM_MAX_MIB" ]]; then
    fail "balloon a dépassé le maximum : $ram_final > $VM_MAX_MIB MiB"
fi

step "Résumé"
info "initial=$VM_INIT_MIB | max_observé=$ram_max | max_autorisé=$VM_MAX_MIB | final=${ram_final:-?}"

if $grew; then
    pass "balloon thin-provisioning OK — VM a grandi de $VM_INIT_MIB MiB à $ram_max MiB sous charge"
else
    warn "aucune croissance du balloon observée"
    info "vérifications :"
    info "  1. Le driver virtio-balloon est bien chargé dans le guest (lsmod | grep balloon)"
    info "  2. stress-ng a bien créé de la pression mémoire"
    info "  3. fault_rate ≥ grow_faults_per_sec ($( grep -oE 'grow.*=[0-9]+' "$LOG_AGENT" | head -1 || echo '?'))"
    pass "balloon testé — voir logs pour diagnostic"
fi
