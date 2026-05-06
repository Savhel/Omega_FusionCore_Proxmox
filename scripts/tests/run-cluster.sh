#!/usr/bin/env bash
# Lance tous les tests sur cluster Proxmox (virtuel ou physique)
# Usage : ./run-cluster.sh [vmid] [--gpu] [--ceph] [--skip M3,M7] [--drain-node 10.10.0.11]
#
# Variables d'environnement :
#   OMEGA_NODES=10.10.0.11,10.10.0.12,10.10.0.13   — tous les nœuds (N >= 2)
#   OMEGA_CONTROLLER=10.10.0.11                     — nœud contrôleur (défaut: premier)
#   OMEGA_TEST_VMID=9001                            — VM principale pour les tests
#   OMEGA_BIN_DIR=/usr/local/bin                    — si binaires déployés
#   OMEGA_REMOTE_BIN_DIR=/usr/local/bin             — binaires sur les nœuds distants
#   OMEGA_SKIP=M3,M7                                — tests à ignorer
#
# Tests 01-04 et 10 s'exécutent sur CONTROLLER_NODE (userfaultfd requis).
# Les tests cluster (05, 08, 09, Mx) s'exécutent aussi sur le nœud contrôleur
# pour disposer de qm/pvesh et des stores réseau actifs.

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"; shift || true
DO_GPU=false; DO_CEPH=false
SKIP_LIST="${OMEGA_SKIP:-}"
DRAIN_NODE=""

for arg in "$@"; do
    case $arg in
        --gpu)          DO_GPU=true ;;
        --ceph)         DO_CEPH=true ;;
        --skip=*)       SKIP_LIST="${arg#--skip=}" ;;
        --drain-node=*) DRAIN_NODE="${arg#--drain-node=}" ;;
    esac
done

DRAIN_NODE="${DRAIN_NODE:-$CONTROLLER_NODE}"

should_skip() { [[ ",$SKIP_LIST," == *",$1,"* ]]; }

TESTS_DIR="$(dirname "$0")"
PASS=0; FAIL=0; SKIP=0
RESULTS=()

# ── Synchronisation scripts + binaires vers le nœud contrôleur ────────────────
REMOTE_TESTS_DIR="/tmp/omega-tests"
REMOTE_BINS_DIR="/tmp/omega-tests-bins"

sync_to_controller() {
    info "Synchronisation vers ${CONTROLLER_NODE}..."
    rsync -aq --delete "${TESTS_DIR}/" "root@${CONTROLLER_NODE}:${REMOTE_TESTS_DIR}/"
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" "mkdir -p ${REMOTE_BINS_DIR}"
    for bin in node-a-agent node-bc-store; do
        local local_bin="${REPO_ROOT}/target/release/${bin}"
        if [[ -x "$local_bin" ]]; then
            rsync -aq "$local_bin" "root@${CONTROLLER_NODE}:${REMOTE_BINS_DIR}/${bin}"
        fi
    done
    pass "scripts + binaires synchronisés sur ${CONTROLLER_NODE}"
}

# ── Exécution locale (tests ne nécessitant pas de cluster ni userfaultfd) ──────
run_test() {
    local num="$1" name="$2" script="$3"; shift 3
    if should_skip "$num"; then
        warn "Test $num ($name) — ignoré"
        RESULTS+=("SKIP  $num $name")
        ((SKIP++)) || true
        return
    fi
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  Test $num — $name${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    t0=$SECONDS
    if bash "$script" "$@"; then
        RESULTS+=("${GREEN}PASS${RESET}  $num $name ($(( SECONDS - t0 ))s)")
        ((PASS++)) || true
    else
        RESULTS+=("${RED}FAIL${RESET}  $num $name ($(( SECONDS - t0 ))s)")
        ((FAIL++)) || true
    fi
    sleep 2
}

# ── Exécution distante — daemon omega reste actif ─────────────────────────────
# Pour tests cluster : qm/pvesh disponibles, stores réseau actifs
run_test_on_node() {
    local num="$1" name="$2" script="$3"; shift 3
    if should_skip "$num"; then
        warn "Test $num ($name) — ignoré"
        RESULTS+=("SKIP  $num $name")
        ((SKIP++)) || true
        return
    fi
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  Test $num — $name  [${CONTROLLER_NODE}]${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    t0=$SECONDS
    local exit_code=0
    local remote_script="${REMOTE_TESTS_DIR}/$(basename "$script")"
    # Passer les arguments en chaîne (pas de tableaux via SSH)
    local args_str="$*"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${CONTROLLER_NODE}" \
        "OMEGA_NODES='${OMEGA_NODES}' \
         OMEGA_CONTROLLER='${OMEGA_CONTROLLER}' \
         OMEGA_TEST_VMID='${VMID}' \
         OMEGA_BIN_DIR='${REMOTE_BINS_DIR}' \
         bash '${remote_script}' ${args_str}" \
        || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        RESULTS+=("${GREEN}PASS${RESET}  $num $name [remote] ($(( SECONDS - t0 ))s)")
        ((PASS++)) || true
    else
        RESULTS+=("${RED}FAIL${RESET}  $num $name [remote] ($(( SECONDS - t0 ))s)")
        ((FAIL++)) || true
    fi
    sleep 2
}

# ── Exécution distante isolée — arrête omega-daemon le temps du test ──────────
# Pour tests qui démarrent leurs propres stores sur les ports 9100-9202.
# Après le test (succès ou échec), omega-daemon est redémarré.
run_test_on_node_isolated() {
    local num="$1" name="$2" script="$3"; shift 3
    if should_skip "$num"; then
        warn "Test $num ($name) — ignoré"
        RESULTS+=("SKIP  $num $name")
        ((SKIP++)) || true
        return
    fi
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  Test $num — $name  [${CONTROLLER_NODE}, isolé]${RESET}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    t0=$SECONDS

    # Stopper omega-daemon pour libérer 9100-9202
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" \
        "systemctl stop omega-daemon 2>/dev/null || true" || true

    local exit_code=0
    local remote_script="${REMOTE_TESTS_DIR}/$(basename "$script")"
    local args_str="$*"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${CONTROLLER_NODE}" \
        "OMEGA_NODES='${OMEGA_NODES}' \
         OMEGA_CONTROLLER='${OMEGA_CONTROLLER}' \
         OMEGA_TEST_VMID='${VMID}' \
         OMEGA_BIN_DIR='${REMOTE_BINS_DIR}' \
         bash '${remote_script}' ${args_str}" \
        || exit_code=$?

    # Redémarrer omega-daemon dans tous les cas
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" \
        "systemctl start omega-daemon 2>/dev/null || true; sleep 2" || true

    if [[ $exit_code -eq 0 ]]; then
        RESULTS+=("${GREEN}PASS${RESET}  $num $name [remote/isolé] ($(( SECONDS - t0 ))s)")
        ((PASS++)) || true
    else
        RESULTS+=("${RED}FAIL${RESET}  $num $name [remote/isolé] ($(( SECONDS - t0 ))s)")
        ((FAIL++)) || true
    fi
    sleep 2
}

# ── En-tête ────────────────────────────────────────────────────────────────────
header "Tests cluster — omega-remote-paging"
print_cluster_config
info "VM test      : $VMID"
info "GPU          : $DO_GPU"
info "Ceph         : $DO_CEPH"
info "Skip         : ${SKIP_LIST:-aucun}"
info "Nœuds        : $(node_count) ($(store_count) store(s))"

# ── Preflight ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Preflight${RESET}"
flags="--cluster"
$DO_GPU  && flags="$flags --gpu"
$DO_CEPH && flags="$flags --ceph"
bash "$TESTS_DIR/preflight.sh" $flags || fail "preflight échoué — corriger les prérequis"

# ── Tests unitaires (local — cargo test) ──────────────────────────────────────
run_test "00" "Tests unitaires" "$TESTS_DIR/00-unit-tests.sh"

# ── Synchronisation vers le nœud contrôleur ───────────────────────────────────
sync_to_controller

# ── Tests store + agent locaux (isolés — daemon arrêté temporairement) ────────
# Ces tests démarrent leurs propres stores sur 9100-9202.
run_test_on_node_isolated "01" "Smoke test"           "$TESTS_DIR/01-smoke-test.sh"
run_test_on_node_isolated "02" "Réplication 2 stores" "$TESTS_DIR/02-replication.sh"
run_test_on_node_isolated "03" "Failover store"       "$TESTS_DIR/03-failover.sh"
run_test_on_node_isolated "04" "Éviction daemon"      "$TESTS_DIR/04-eviction-daemon.sh" 20
run_test_on_node_isolated "10" "Multi-VM 3 agents"    "$TESTS_DIR/10-multi-vm.sh"
run_test_on_node_isolated "18" "Recall LIFO"          "$TESTS_DIR/18-recall-lifo.sh"
run_test_on_node_isolated "20" "Prefetch stride"      "$TESTS_DIR/20-prefetch-stride.sh"
run_test_on_node_isolated "21" "TLS TOFU"             "$TESTS_DIR/21-tls-tofu.sh"

# ── Tests cluster (daemon actif, qm/pvesh disponibles) ────────────────────────
run_test_on_node "05" "vCPU élastique"              "$TESTS_DIR/05-vcpu-elastic.sh"         "$VMID"
run_test_on_node "08" "Migration RAM"               "$TESTS_DIR/08-migration-ram.sh"        "$VMID"
run_test_on_node "09" "Orphan cleaner"              "$TESTS_DIR/09-orphan-cleaner.sh"
run_test_on_node "19" "Compaction cluster"          "$TESTS_DIR/19-compaction.sh"           "$VMID"
run_test_on_node "22" "Balloon thin-provisioning"   "$TESTS_DIR/22-balloon-thinprov.sh"     "$VMID"

# ── Tests GPU (optionnels) ─────────────────────────────────────────────────────
if $DO_GPU; then
    run_test_on_node "06" "GPU placement"           "$TESTS_DIR/06-gpu-placement.sh"        "$VMID"
    run_test_on_node "07" "GPU scheduler"           "$TESTS_DIR/07-gpu-scheduler.sh"        "$VMID" "9002"
else
    for t in "06:GPU placement" "07:GPU scheduler"; do
        num="${t%:*}"; name="${t#*:}"
        RESULTS+=("SKIP  $num $name (passer --gpu)")
        ((SKIP++)) || true
    done
fi

# ── Tests mixtes ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}  ── Tests mixtes ──────────────────────────────────${RESET}"

run_test_on_node "M1" "RAM + CPU simultanés"          "$TESTS_DIR/11-mixed-ram-cpu.sh"              "$VMID"
run_test_on_node "M2" "CPU+RAM saturés → migration"   "$TESTS_DIR/12-mixed-cpu-ram-migration.sh"    "$VMID"
run_test_on_node "M4" "Stress cluster complet"        "$TESTS_DIR/14-mixed-cluster-pressure.sh"     "$(node_count)" 60
run_test_on_node "M5" "Migration live sous pression"  "$TESTS_DIR/15-mixed-live-migration-pressure.sh" "$VMID"
run_test_on_node "M6" "Rafale démarrages simultanés"  "$TESTS_DIR/16-mixed-burst-starts.sh"         6
run_test_on_node "M7" "Drain nœud complet"            "$TESTS_DIR/17-mixed-drain-node.sh"           "$DRAIN_NODE"

# ── Tests GPU mixtes (optionnels) ─────────────────────────────────────────────
if $DO_GPU; then
    run_test_on_node "M3" "GPU + CPU multi-contraintes" "$TESTS_DIR/13-mixed-gpu-cpu.sh"    "$VMID"
else
    RESULTS+=("SKIP  M3 GPU+CPU multi-contraintes (passer --gpu)")
    ((SKIP++)) || true
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Résumé — cluster $(node_count) nœuds${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
for r in "${RESULTS[@]}"; do echo -e "  $r"; done
echo ""
echo -e "  ${GREEN}PASS${RESET}: $PASS  ${RED}FAIL${RESET}: $FAIL  ${YELLOW}SKIP${RESET}: $SKIP"

[[ $FAIL -eq 0 ]] && \
    echo -e "\n${GREEN}${BOLD}  ✓ Tous les tests cluster passent${RESET}" || \
    { echo -e "\n${RED}${BOLD}  ✗ $FAIL test(s) échoué(s)${RESET}"; exit 1; }
