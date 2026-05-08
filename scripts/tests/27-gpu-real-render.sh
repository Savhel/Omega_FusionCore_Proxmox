#!/usr/bin/env bash
# Test 27 — GPU réel : render node, daemon GPU, passthrough/VM si disponible.
# Usage : ./27-gpu-real-render.sh [vmid]

set -euo pipefail
source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
require_vm_running "$VMID"
VMID="$SELECTED_VMID"

header "Test 27 — GPU réel / rendu minimal (VM $VMID)"

guest_exec() {
    local cmd="$1"
    local started pid status
    started=$(qm guest exec "$VMID" -- bash -lc "$cmd" 2>/dev/null || true)
    pid=$(printf '%s' "$started" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("pid",""))' 2>/dev/null || true)
    [[ -n "$pid" ]] || return 1
    for _ in $(seq 1 30); do
        status=$(qm guest exec-status "$VMID" "$pid" 2>/dev/null || true)
        if printf '%s' "$status" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("exited") else 1)' 2>/dev/null; then
            printf '%s' "$status" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("out-data","") + d.get("err-data",""), end="")' 2>/dev/null
            return 0
        fi
        sleep 1
    done
    return 1
}

gpu_nodes=()
for node in "${OMEGA_NODES_ARR[@]}"; do
    step "Nœud $node — inventaire GPU"
    pci=$(ssh_run "$node" "ls /sys/bus/pci/devices/*/class 2>/dev/null | xargs grep -l '^0x03' 2>/dev/null | head -5" || true)
    renders=$(ssh_run "$node" "ls /dev/dri/renderD* 2>/dev/null || true")
    if [[ -n "$pci$renders" ]]; then
        gpu_nodes+=("$node")
        info "PCI GPU:"
        printf '%s\n' "$pci" | sed 's/^/    /'
        info "Render nodes:"
        printf '%s\n' "$renders" | sed 's/^/    /'
    else
        warn "$node : aucun GPU/render node détecté"
    fi
done

[[ ${#gpu_nodes[@]} -gt 0 ]] || fail "aucun nœud GPU/render node dans OMEGA_NODES"

step "API daemon GPU"
for node in "${gpu_nodes[@]}"; do
    if curl -sf "http://${node}:9300/control/gpu/status" | python3 -m json.tool | sed 's/^/    /'; then
        pass "$node : /control/gpu/status OK"
    else
        warn "$node : endpoint GPU indisponible (daemon ancien ou GPU backend non démarré)"
    fi
done

step "VM — hostpci/render visible"
hostpci=$(qm config "$VMID" | grep '^hostpci' || true)
if [[ -n "$hostpci" ]]; then
    info "hostpci VM:"
    printf '%s\n' "$hostpci" | sed 's/^/    /'
else
    warn "VM $VMID sans hostpci configuré — placement GPU peut encore migrer/configurer plus tard"
fi

if qm guest ping "$VMID" &>/dev/null; then
    guest_gpu=$(guest_exec "ls /dev/dri 2>/dev/null; command -v glxinfo >/dev/null && timeout 10 glxinfo -B 2>/dev/null | head -20 || true" || true)
    if [[ -n "$guest_gpu" ]]; then
        info "GPU visible dans l'invité:"
        printf '%s\n' "$guest_gpu" | sed 's/^/    /'
        pass "inspection GPU invité OK"
    else
        warn "aucun GPU visible dans l'invité via qemu-guest-agent"
    fi
else
    warn "qemu-guest-agent indisponible — test GPU invité ignoré"
fi

pass "GPU réel inspecté"
