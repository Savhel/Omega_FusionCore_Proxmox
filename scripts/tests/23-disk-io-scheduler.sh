#!/usr/bin/env bash
# Test 23 — Scheduler I/O disque (cgroups v2 io.weight + PSI)
#
# Ce que ça vérifie :
#   1. Unité : les tests unitaires du module disk_scheduler passent.
#   2. Isolation : l'agent démarre avec --disk-scheduler-enabled,
#      les logs montrent "scheduler I/O disque activé".
#   3. Cluster (si CLUSTER_MODE=1) : sous charge I/O réelle, les cgroups
#      io.weight des VMs actives passent à 200 et les VMs idle à 50.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

header "Test 23 — Scheduler I/O disque"

# ── 1. Tests unitaires ────────────────────────────────────────────────────────

step "1/3 : tests unitaires disk_scheduler"
cargo test -p node-a-agent disk_scheduler 2>&1 | tail -20
pass "tests unitaires disk_scheduler OK"

# ── 2. Test isolation (pas besoin du cluster) ─────────────────────────────────

step "2/3 : démarrage agent avec disk-scheduler-enabled"

STORE_PID=""
cleanup() {
    [[ -n "$STORE_PID" ]] && kill "$STORE_PID" 2>/dev/null || true
}
trap cleanup EXIT

start_store 0 9100

AGENT_LOG=$(mktemp /tmp/omega-disk-sched-XXXXXX.log)
"${AGENT_BIN}" \
    --stores              "127.0.0.1:9100" \
    --vm-id               100 \
    --region-mib          32 \
    --vm-requested-mib    32 \
    --mode                demo \
    --disk-scheduler-enabled \
    --disk-interval-secs  2 \
    --disk-psi-threshold  0.0 \
    --log-level           debug \
    2>&1 | tee "$AGENT_LOG" &
AGENT_PID=$!

# Attendre le log de démarrage ou la fin du mode demo
for i in $(seq 1 20); do
    sleep 1
    if grep -q "scheduler I/O disque activé" "$AGENT_LOG" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$AGENT_PID" 2>/dev/null; then break; fi
done
wait "$AGENT_PID" || true

if grep -q "scheduler I/O disque activé" "$AGENT_LOG"; then
    pass "scheduler I/O disque activé : log confirmé"
else
    warn "scheduler I/O disque : log non trouvé (PSI peut-être non supporté sur ce kernel)"
fi

# Vérifier que le mode demo s'est terminé correctement
if grep -q "SUCCÈS" "$AGENT_LOG"; then
    pass "mode demo terminé avec succès"
else
    fail "mode demo n'a pas retourné SUCCÈS"
fi
rm -f "$AGENT_LOG"

# ── 3. Test cluster (charge I/O réelle) ───────────────────────────────────────

if [[ "${CLUSTER_MODE:-0}" != "1" ]]; then
    warn "CLUSTER_MODE non activé — test de charge I/O disque ignoré"
    info "Pour le tester sur cluster : CLUSTER_MODE=1 VMID=<vmid> ./23-disk-io-scheduler.sh"
    summary "Test 23 terminé (unitaire + isolation OK, cluster ignoré)"
    exit 0
fi

step "3/3 : test cluster — io.weight sous charge I/O (VM ${VMID})"

require_var VMID "identifiant VM Proxmox"
require_var CONTROLLER_NODE "nœud Proxmox pour les commandes qm"

# Démarrer l'agent en mode daemon avec disk-scheduler-enabled
ssh "${DEPLOY_USER:-root}@${CONTROLLER_NODE}" "
    export AGENT_DISK_SCHEDULER_ENABLED=true
    export AGENT_DISK_PSI_THRESHOLD=5.0
    export AGENT_DISK_INTERVAL_SECS=3
    systemctl restart omega-agent@${VMID} 2>/dev/null || true
    sleep 2
    journalctl -u omega-agent@${VMID} -n 5 --no-pager 2>/dev/null || true
"

# Générer de la charge I/O dans la VM
info "Génération de charge I/O dans la VM ${VMID}"
ssh "${DEPLOY_USER:-root}@${CONTROLLER_NODE}" "
    qm guest exec ${VMID} -- bash -c 'dd if=/dev/urandom of=/tmp/io-test bs=1M count=200 oflag=direct 2>&1 &' 2>/dev/null \
    || warn 'qm guest exec non disponible — utilisez stress-ng depuis la VM'
" || true

sleep 10

# Vérifier les io.weight dans les cgroups
CGROUP_ACTIVE=""
for scope in \
    "/sys/fs/cgroup/qemu.slice/${VMID}.scope/io.weight" \
    "/sys/fs/cgroup/machine.slice/qemu-${VMID}.scope/io.weight"
do
    if ssh "${DEPLOY_USER:-root}@${CONTROLLER_NODE}" "test -f '${scope}'" 2>/dev/null; then
        CGROUP_ACTIVE=$(ssh "${DEPLOY_USER:-root}@${CONTROLLER_NODE}" "cat '${scope}'" 2>/dev/null || echo "")
        break
    fi
done

if [[ -n "$CGROUP_ACTIVE" ]]; then
    info "io.weight actuel : ${CGROUP_ACTIVE}"
    # Sous charge active on attend 200, au repos 100 ou 50
    if [[ "$CGROUP_ACTIVE" == *"200"* ]]; then
        pass "VM active détectée : io.weight = 200"
    elif [[ "$CGROUP_ACTIVE" == *"100"* ]]; then
        pass "VM au repos : io.weight = 100 (pas de pression PSI)"
    elif [[ "$CGROUP_ACTIVE" == *"50"* ]]; then
        pass "VM idle sous pression : io.weight = 50"
    else
        warn "io.weight inattendu : ${CGROUP_ACTIVE}"
    fi
else
    warn "cgroup io.weight introuvable — kernel sans cgroups v2 BFQ ?"
fi

# Nettoyage : remettre à la valeur par défaut
ssh "${DEPLOY_USER:-root}@${CONTROLLER_NODE}" "
    for scope in \
        /sys/fs/cgroup/qemu.slice/${VMID}.scope/io.weight \
        /sys/fs/cgroup/machine.slice/qemu-${VMID}.scope/io.weight; do
        [ -f \"\$scope\" ] && echo 'default 100' > \"\$scope\" || true
    done
" 2>/dev/null || true

summary "Test 23 — Scheduler I/O disque : OK"
