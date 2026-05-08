#!/usr/bin/env bash
# Test 24 — Installation physique : services, wrapper QEMU, hookscript, doctor launcher.
# Usage : ./24-install-doctor.sh

set -euo pipefail
source "$(dirname "$0")/lib.sh"

header "Test 24 — Installation physique / doctor"

require_cluster

REMOTE_BIN_DIR="${OMEGA_REMOTE_BIN_DIR:-/usr/local/bin}"
REMOTE_RUN_DIR="${OMEGA_RUN_DIR:-/run/omega-qemu}"
REMOTE_BRIDGE_LIB="${OMEGA_BRIDGE_LIB:-/usr/local/lib/omega-uffd-bridge.so}"
REMOTE_REAL_KVM="${OMEGA_REAL_KVM:-/usr/bin/kvm.real}"

for node in "${OMEGA_NODES_ARR[@]}"; do
    step "Nœud $node — services et binaires"

    ssh_run "$node" "test -x '${REMOTE_BIN_DIR}/omega-daemon'" \
        || fail "$node : omega-daemon absent dans ${REMOTE_BIN_DIR}"
    ssh_run "$node" "test -x '${REMOTE_BIN_DIR}/node-a-agent'" \
        || fail "$node : node-a-agent absent dans ${REMOTE_BIN_DIR}"
    ssh_run "$node" "test -x '${REMOTE_BIN_DIR}/omega-qemu-launcher'" \
        || fail "$node : omega-qemu-launcher absent dans ${REMOTE_BIN_DIR}"

    active=$(ssh_run "$node" "systemctl is-active omega-daemon 2>/dev/null || true")
    [[ "$active" == "active" ]] || fail "$node : omega-daemon non actif (status=$active)"
    pass "$node : omega-daemon actif"

    step "Nœud $node — wrapper QEMU"
    ssh_run "$node" "test -L /usr/bin/kvm" \
        || fail "$node : /usr/bin/kvm n'est pas un symlink vers le wrapper"
    wrapper_target=$(ssh_run "$node" "readlink -f /usr/bin/kvm")
    case "$wrapper_target" in
        *omega-qemu-wrapper*|*omega-qemu-launcher*) pass "$node : wrapper QEMU actif ($wrapper_target)" ;;
        *) fail "$node : /usr/bin/kvm pointe vers $wrapper_target, pas vers Omega" ;;
    esac

    ssh_run "$node" "test -x '${REMOTE_REAL_KVM}'" \
        || fail "$node : QEMU réel introuvable/non exécutable: ${REMOTE_REAL_KVM}"

    step "Nœud $node — hookscript Proxmox"
    ssh_run "$node" "test -f /var/lib/vz/snippets/omega-hook.pl || test -f /var/lib/vz/snippets/proxmox_hook.pl" \
        || warn "$node : hookscript Omega non trouvé dans local:snippets"

    step "Nœud $node — omega-qemu-launcher doctor"
    bridge_arg=""
    if ssh_run "$node" "test -f '${REMOTE_BRIDGE_LIB}'"; then
        bridge_arg="--bridge-lib '${REMOTE_BRIDGE_LIB}'"
    else
        warn "$node : bridge UFFD absent (${REMOTE_BRIDGE_LIB}) — doctor sans bridge"
    fi

    if ssh_run "$node" "'${REMOTE_BIN_DIR}/omega-qemu-launcher' doctor \
            --qemu-bin '${REMOTE_REAL_KVM}' \
            --agent-bin '${REMOTE_BIN_DIR}/node-a-agent' \
            --run-dir '${REMOTE_RUN_DIR}' \
            ${bridge_arg}"; then
        pass "$node : doctor OK"
    else
        fail "$node : omega-qemu-launcher doctor en échec"
    fi
done

pass "Installation physique validée sur ${#OMEGA_NODES_ARR[@]} nœud(s)"
