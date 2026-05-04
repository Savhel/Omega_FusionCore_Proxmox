#!/usr/bin/env bash
# Lance tous les tests sur cluster Proxmox (virtuel ou physique)
# Usage : ./run-cluster.sh [vmid] [--gpu] [--ceph] [--skip M3,M7] [--drain-node 10.10.0.11]
#
# Variables d'environnement :
#   OMEGA_NODES=10.10.0.11,10.10.0.12,10.10.0.13   — tous les nœuds (N >= 2)
#   OMEGA_COMPUTE_NODE=10.10.0.11                   — nœud compute (défaut: premier)
#   OMEGA_STORE_NODES=10.10.0.12,10.10.0.13         — nœuds store (défaut: tout sauf compute)
#   OMEGA_TEST_VMID=9001                            — VM principale pour les tests
#   OMEGA_BIN_DIR=/usr/local/bin                    — si binaires déployés
#   OMEGA_REMOTE_BIN_DIR=/usr/local/bin             — binaires sur les nœuds distants
#   OMEGA_SKIP=M3,M7                                — tests à ignorer

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

# Drain node par défaut = compute node
DRAIN_NODE="${DRAIN_NODE:-$COMPUTE_NODE}"

should_skip() { [[ ",$SKIP_LIST," == *",$1,"* ]]; }

TESTS_DIR="$(dirname "$0")"
PASS=0; FAIL=0; SKIP=0
RESULTS=()

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

# ── Tests unitaires ───────────────────────────────────────────────────────────
run_test "00" "Tests unitaires"              "$TESTS_DIR/00-unit-tests.sh"

# ── Tests store + agent locaux ────────────────────────────────────────────────
run_test "01" "Smoke test"                   "$TESTS_DIR/01-smoke-test.sh"
run_test "02" "Réplication 2 stores"         "$TESTS_DIR/02-replication.sh"
run_test "03" "Failover store"               "$TESTS_DIR/03-failover.sh"
run_test "04" "Éviction daemon"              "$TESTS_DIR/04-eviction-daemon.sh" 20

# ── Tests cluster simples ─────────────────────────────────────────────────────
run_test "05" "vCPU élastique"               "$TESTS_DIR/05-vcpu-elastic.sh"         "$VMID"
run_test "08" "Migration RAM"                "$TESTS_DIR/08-migration-ram.sh"        "$VMID"
run_test "09" "Orphan cleaner"               "$TESTS_DIR/09-orphan-cleaner.sh"
run_test "10" "Multi-VM 3 agents"            "$TESTS_DIR/10-multi-vm.sh"

# ── Tests GPU (optionnels) ────────────────────────────────────────────────────
if $DO_GPU; then
    run_test "06" "GPU placement"            "$TESTS_DIR/06-gpu-placement.sh"        "$VMID"
    run_test "07" "GPU scheduler"            "$TESTS_DIR/07-gpu-scheduler.sh"        "$VMID" "9002"
else
    for t in "06:GPU placement" "07:GPU scheduler"; do
        num="${t%:*}"; name="${t#*:}"
        RESULTS+=("SKIP  $num $name (passer --gpu)")
        ((SKIP++)) || true
    done
fi

# ── Tests mixtes ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}  ── Tests mixtes ──────────────────────────────────${RESET}"

run_test "M1" "RAM + CPU simultanés"         "$TESTS_DIR/11-mixed-ram-cpu.sh"        "$VMID"
run_test "M2" "CPU+RAM saturés → migration"  "$TESTS_DIR/12-mixed-cpu-ram-migration.sh" "$VMID"
run_test "M4" "Stress cluster complet"       "$TESTS_DIR/14-mixed-cluster-pressure.sh" \
                                             "$(node_count)" 60
run_test "M5" "Migration live sous pression" "$TESTS_DIR/15-mixed-live-migration-pressure.sh" "$VMID"
run_test "M6" "Rafale démarrages simultanés" "$TESTS_DIR/16-mixed-burst-starts.sh"   6
run_test "M7" "Drain nœud complet"          "$TESTS_DIR/17-mixed-drain-node.sh"     "$DRAIN_NODE"

# ── Tests GPU mixtes (optionnels) ─────────────────────────────────────────────
if $DO_GPU; then
    run_test "M3" "GPU + CPU multi-contraintes" "$TESTS_DIR/13-mixed-gpu-cpu.sh"    "$VMID"
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
