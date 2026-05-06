#!/usr/bin/env bash
# omega-lab.sh — Lab interactif : configuration + installation + tests
#
# Usage : ./scripts/omega-lab.sh [--gpu] [--ceph] [--auto]
#
# Le script lit scripts/cluster.conf pour la configuration du cluster.
# Si le fichier n'existe pas ou si les nœuds ne sont pas encore définis,
# le menu propose de les saisir directement.
#
# Options :
#   --gpu    activer les tests GPU
#   --ceph   activer les tests Ceph
#   --auto   toutes les sections sans pause (mode CI)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

# ── Options CLI ───────────────────────────────────────────────────────────────
DO_GPU=false; DO_CEPH=false; AUTO=false
for arg in "$@"; do
    case "$arg" in
        --gpu)  DO_GPU=true  ;;
        --ceph) DO_CEPH=true ;;
        --auto) AUTO=true    ;;
    esac
done

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
DIM='\033[2m'; MAG='\033[0;35m'

_ok()   { echo -e "${GREEN}[OK]${RESET}  $*"; }
_err()  { echo -e "${RED}[ERR]${RESET} $*"; }
_info() { echo -e "${CYAN}[INF]${RESET} $*"; }
_warn() { echo -e "${YELLOW}[WRN]${RESET} $*"; }
_sep()  { echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"; }
_hdr()  { echo -e "\n${BOLD}${BLUE}$*${RESET}"; }
_ask()  { echo -en "${YELLOW}  → ${RESET}$* : "; }

# ── Chargement/rechargement de la configuration ───────────────────────────────
# Appelé à chaque modification de cluster.conf et au démarrage.
OMEGA_NODES=""
OMEGA_CONTROLLER=""
OMEGA_TEST_VMID="9001"
DEPLOY_USER="root"
STORE_PORT="9100"
STATUS_PORT="9200"
NODES_ARR=()
CONTROLLER_NODE=""
STORES_CSV=""
STATUS_CSV=""
CONFIGURED=false

_load_config() {
    # Priorité : variables d'environnement > cluster.conf
    local env_nodes="${OMEGA_NODES:-}"
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
    [[ -n "$env_nodes" ]] && OMEGA_NODES="$env_nodes"

    OMEGA_NODES="${OMEGA_NODES:-}"
    OMEGA_TEST_VMID="${OMEGA_TEST_VMID:-9001}"
    DEPLOY_USER="${DEPLOY_USER:-root}"
    STORE_PORT="${STORE_PORT:-9100}"
    STATUS_PORT="${STATUS_PORT:-9200}"

    if [[ -n "$OMEGA_NODES" ]]; then
        IFS=',' read -ra NODES_ARR <<< "$OMEGA_NODES"
        CONTROLLER_NODE="${OMEGA_CONTROLLER:-${NODES_ARR[0]}}"
        STORES_CSV=""; STATUS_CSV=""
        for n in "${NODES_ARR[@]}"; do
            STORES_CSV="${STORES_CSV:+$STORES_CSV,}${n}:${STORE_PORT}"
            STATUS_CSV="${STATUS_CSV:+$STATUS_CSV,}${n}:${STATUS_PORT}"
        done
        CONFIGURED=true
    else
        NODES_ARR=(); CONTROLLER_NODE=""; STORES_CSV=""; STATUS_CSV=""
        CONFIGURED=false
    fi
}
_load_config

# ── Résultats tests ───────────────────────────────────────────────────────────
declare -A RESULTS=()
declare -A DURATIONS=()
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0

# ── Enregistrement d'un résultat ──────────────────────────────────────────────
_record() {
    local num="$1" name="$2" rc="$3" elapsed="$4"
    DURATIONS["$num"]="$elapsed"
    if [[ "$rc" -eq 0 ]]; then
        RESULTS["$num"]="PASS"; ((TOTAL_PASS++)) || true
        echo -e "\n  ${GREEN}✓ PASS${RESET}  ${num} — ${name}  (${elapsed}s)"
    else
        RESULTS["$num"]="FAIL"; ((TOTAL_FAIL++)) || true
        echo -e "\n  ${RED}✗ FAIL${RESET}  ${num} — ${name}  (${elapsed}s) [code $rc]"
    fi
}

# ── Exécution des tests ───────────────────────────────────────────────────────
_need_config() {
    if ! $CONFIGURED; then
        _warn "Cluster non configuré. Utilisez [c] pour définir les nœuds."
        return 1
    fi
    return 0
}

_sync() {
    _need_config || return
    _info "Sync scripts + binaires → ${CONTROLLER_NODE}..."
    rsync -aq --delete "${TESTS_DIR}/" "root@${CONTROLLER_NODE}:/tmp/omega-tests/"
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" "mkdir -p /tmp/omega-tests-bins" 2>/dev/null || true
    for bin in node-a-agent node-bc-store omega-daemon omega-qemu-launcher; do
        local b="${ROOT_DIR}/target/release/${bin}"
        [[ -x "$b" ]] && rsync -aq "$b" "root@${CONTROLLER_NODE}:/tmp/omega-tests-bins/${bin}" || true
    done
    _ok "Sync OK"
}

_remote_env() {
    echo "OMEGA_NODES='${OMEGA_NODES}' \
OMEGA_CONTROLLER='${CONTROLLER_NODE}' \
OMEGA_TEST_VMID='${OMEGA_TEST_VMID}' \
OMEGA_BIN_DIR='/tmp/omega-tests-bins'"
}

_run_isolated() {
    local num="$1" name="$2" script="$3"; shift 3
    _hdr "  Test ${num} — ${name}  [isolé]"
    _sep
    local t0=$SECONDS rc=0
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" \
        "systemctl stop omega-daemon 2>/dev/null || true" || true
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${CONTROLLER_NODE}" \
        "$(_remote_env) bash '/tmp/omega-tests/$(basename "$script")' $*" || rc=$?
    ssh -o ConnectTimeout=5 "root@${CONTROLLER_NODE}" \
        "systemctl start omega-daemon 2>/dev/null || true; sleep 2" || true
    _record "$num" "$name" "$rc" "$(( SECONDS - t0 ))"
}

_run_cluster() {
    local num="$1" name="$2" script="$3"; shift 3
    _hdr "  Test ${num} — ${name}  [cluster]"
    _sep
    local t0=$SECONDS rc=0
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${CONTROLLER_NODE}" \
        "$(_remote_env) bash '/tmp/omega-tests/$(basename "$script")' $*" || rc=$?
    _record "$num" "$name" "$rc" "$(( SECONDS - t0 ))"
}

# ── Affichage du résumé en ligne ──────────────────────────────────────────────
_results_line() {
    local total=$(( TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP ))
    if [[ $total -eq 0 ]]; then
        echo -e "  ${DIM}aucun test exécuté${RESET}"
    else
        echo -ne "  Tests : ${GREEN}✓ $TOTAL_PASS${RESET}  ${RED}✗ $TOTAL_FAIL${RESET}  ${YELLOW}— $TOTAL_SKIP${RESET}  / $total"
        # Lister les FAIL
        local fails=""
        for id in "${!RESULTS[@]}"; do
            [[ "${RESULTS[$id]}" == "FAIL" ]] && fails="$fails ${RED}$id${RESET}"
        done
        [[ -n "$fails" ]] && echo -e "    FAIL :${fails}" || echo ""
    fi
}

show_results() {
    _hdr "══ Résumé des tests ══"
    echo ""
    local ids=()
    for id in $(echo "${!RESULTS[@]}" | tr ' ' '\n' | sort -V); do ids+=("$id"); done
    for id in "${ids[@]}"; do
        local s="${RESULTS[$id]}" d="${DURATIONS[$id]:-?}s"
        case "$s" in
            PASS) echo -e "  ${GREEN}✓${RESET} $id  ($d)" ;;
            FAIL) echo -e "  ${RED}✗${RESET} $id  ($d)" ;;
            SKIP) echo -e "  ${YELLOW}–${RESET} $id  (ignoré)" ;;
        esac
    done
    echo ""
    echo -e "  ${GREEN}PASS${RESET} $TOTAL_PASS   ${RED}FAIL${RESET} $TOTAL_FAIL   ${YELLOW}SKIP${RESET} $TOTAL_SKIP"
    echo ""
}

# ── Configuration du cluster ──────────────────────────────────────────────────
do_configure() {
    clear
    _hdr "══ Configuration du cluster ══"
    echo ""

    # Afficher la configuration actuelle
    if $CONFIGURED; then
        echo -e "  Configuration actuelle :"
        echo -e "    Nœuds       : ${CYAN}${OMEGA_NODES}${RESET}"
        echo -e "    Contrôleur  : ${CYAN}${CONTROLLER_NODE}${RESET}"
        echo -e "    VM test     : ${CYAN}${OMEGA_TEST_VMID}${RESET}"
        echo -e "    User SSH    : ${CYAN}${DEPLOY_USER}${RESET}"
        echo ""
        read -rp "  Modifier ? [o/N] " mod
        [[ "$mod" =~ ^[oOyY]$ ]] || return
    else
        _warn "Aucune configuration trouvée dans ${CONF_FILE}"
    fi

    echo ""
    echo -e "  Entrez les IPs ou hostnames des nœuds, séparés par des virgules."
    echo -e "  ${DIM}Exemples :${RESET}"
    echo -e "  ${DIM}  2 nœuds : 192.168.1.10,192.168.1.11${RESET}"
    echo -e "  ${DIM}  3 nœuds : pve1,pve2,pve3${RESET}"
    echo -e "  ${DIM}  4 nœuds : 10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4${RESET}"
    echo ""
    while true; do
        _ask "Nœuds du cluster (séparés par virgule)"
        read -r input_nodes
        input_nodes="${input_nodes// /}"   # supprimer espaces
        [[ -n "$input_nodes" ]] && break
        _warn "La liste des nœuds ne peut pas être vide."
    done

    IFS=',' read -ra tmp_arr <<< "$input_nodes"
    local first_node="${tmp_arr[0]}"

    _ask "Nœud contrôleur [défaut : ${first_node}]"
    read -r input_ctrl
    input_ctrl="${input_ctrl:-$first_node}"

    _ask "VM test VMID [défaut : ${OMEGA_TEST_VMID}]"
    read -r input_vmid
    input_vmid="${input_vmid:-${OMEGA_TEST_VMID}}"

    _ask "Utilisateur SSH [défaut : ${DEPLOY_USER}]"
    read -r input_user
    input_user="${input_user:-${DEPLOY_USER}}"

    # Sauvegarder dans cluster.conf
    cat > "$CONF_FILE" <<EOF
# Configuration du cluster omega-remote-paging.
# Généré par omega-lab.sh — $(date)

# Nœuds du cluster (IPs ou hostnames résolvables depuis tous les nœuds).
OMEGA_NODES="${input_nodes}"

# Nœud qui exécute le contrôleur (un seul au choix).
OMEGA_CONTROLLER="${input_ctrl}"

# VM principale utilisée pour les tests cluster.
OMEGA_TEST_VMID="${input_vmid}"

# Utilisateur SSH pour la connexion aux nœuds.
DEPLOY_USER="${input_user}"

# Ports (ne pas modifier sauf si conflit)
STORE_PORT=9100
STATUS_PORT=9200
EOF

    _ok "Configuration sauvegardée dans ${CONF_FILE}"
    echo ""

    # Recharger
    _load_config

    echo -e "  ${GREEN}✓${RESET} Nœuds      : ${CYAN}${OMEGA_NODES}${RESET}"
    echo -e "  ${GREEN}✓${RESET} Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo -e "  ${GREEN}✓${RESET} VM test    : ${CYAN}${OMEGA_TEST_VMID}${RESET}"
    echo -e "  ${GREEN}✓${RESET} User SSH   : ${CYAN}${DEPLOY_USER}${RESET}"
    echo ""

    # Test de connectivité SSH sur chaque nœud
    _info "Test de connectivité SSH..."
    local ok=true
    for n in "${NODES_ARR[@]}"; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${n}" "hostname" &>/dev/null; then
            _ok "  SSH root@${n} — OK"
        else
            _warn "  SSH root@${n} — ÉCHEC (vérifier clé SSH et connectivité)"
            ok=false
        fi
    done
    $ok && _ok "Tous les nœuds sont joignables" || \
          _warn "Certains nœuds sont injoignables — l'installation peut échouer"
}

# ── Opérations d'installation ─────────────────────────────────────────────────
do_build() {
    _hdr "══ Build ══"
    cd "$ROOT_DIR"
    _info "cargo build --release --workspace"
    cargo build --release --workspace
    _ok "Build terminé"
    for bin in omega-daemon node-a-agent node-bc-store omega-qemu-launcher; do
        local b="${ROOT_DIR}/target/release/${bin}"
        [[ -x "$b" ]] && _ok "  ${bin}  $(ls -lh "$b" | awk '{print $5}')" || \
                          _warn "  ${bin} absent"
    done
    cd - &>/dev/null
}

do_uninstall() {
    _need_config || return
    _hdr "══ Désinstallation ══"
    _warn "Arrêt des services et suppression des fichiers sur :"
    for n in "${NODES_ARR[@]}"; do echo -e "  ${CYAN}${n}${RESET}"; done
    echo ""
    if ! $AUTO; then
        read -rp "  Confirmer la désinstallation ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi
    OMEGA_NODES="$OMEGA_NODES" \
    OMEGA_CONTROLLER="$CONTROLLER_NODE" \
    DEPLOY_USER="$DEPLOY_USER" \
    bash "${SCRIPT_DIR}/uninstall.sh"
    _ok "Désinstallation terminée"
}

do_deploy() {
    _need_config || return
    _hdr "══ Déploiement ══"
    _info "Déploiement sur ${#NODES_ARR[@]} nœud(s) : ${OMEGA_NODES}"
    OMEGA_NODES="$OMEGA_NODES" \
    OMEGA_CONTROLLER="$CONTROLLER_NODE" \
    DEPLOY_USER="$DEPLOY_USER" \
    bash "${SCRIPT_DIR}/deploy.sh"
    _ok "Déploiement terminé"
    _sync
}

do_install_full() {
    _need_config || return
    _hdr "══ Installation complète ══"
    echo -e "  Étapes : ${CYAN}désinstallation → build → déploiement${RESET}"
    echo -e "  Nœuds  : ${CYAN}${OMEGA_NODES}${RESET} (${#NODES_ARR[@]} nœud(s))"
    echo ""
    if ! $AUTO; then
        read -rp "  Lancer l'installation complète ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi
    do_uninstall
    do_build
    do_deploy
}

# ── Sections de tests ─────────────────────────────────────────────────────────
run_section_1() {
    _need_config || return
    _hdr "══ Section 1 — Tests isolés (smoke, réplication, failover, éviction) ══"
    _sync
    _run_isolated "00" "Tests unitaires Rust"  "00-unit-tests.sh"
    _run_isolated "01" "Smoke test"            "01-smoke-test.sh"
    _run_isolated "02" "Réplication 2 stores"  "02-replication.sh"
    _run_isolated "03" "Failover store"        "03-failover.sh"
    _run_isolated "04" "Éviction daemon"       "04-eviction-daemon.sh" 20
    _run_isolated "10" "Multi-VM 3 agents"     "10-multi-vm.sh"
}

run_section_2() {
    _need_config || return
    _hdr "══ Section 2 — Fonctionnalités avancées store ══"
    _sync
    _run_isolated "18" "Recall LIFO"       "18-recall-lifo.sh"
    _run_isolated "20" "Prefetch stride"   "20-prefetch-stride.sh"
    _run_isolated "21" "TLS TOFU"          "21-tls-tofu.sh"
}

run_section_3() {
    _need_config || return
    _hdr "══ Section 3 — Tests cluster (vCPU, migration, balloon, compaction) ══"
    _sync
    _run_cluster "05" "vCPU élastique"            "05-vcpu-elastic.sh"         "$OMEGA_TEST_VMID"
    _run_cluster "08" "Migration RAM"             "08-migration-ram.sh"        "$OMEGA_TEST_VMID"
    _run_cluster "09" "Orphan cleaner"            "09-orphan-cleaner.sh"
    _run_cluster "19" "Compaction cluster"        "19-compaction.sh"           "$OMEGA_TEST_VMID"
    _run_cluster "22" "Balloon thin-provisioning" "22-balloon-thinprov.sh"     "$OMEGA_TEST_VMID"
}

run_section_4() {
    _need_config || return
    _hdr "══ Section 4 — Tests GPU ══"
    if ! $DO_GPU; then
        _warn "GPU non activé — relancez avec --gpu pour activer ces tests"
        for t in 06 07; do RESULTS["$t"]="SKIP"; ((TOTAL_SKIP++)) || true; done
        return
    fi
    _sync
    _run_cluster "06" "GPU placement"  "06-gpu-placement.sh"  "$OMEGA_TEST_VMID"
    _run_cluster "07" "GPU scheduler"  "07-gpu-scheduler.sh"  "$OMEGA_TEST_VMID" "9002"
}

run_section_5() {
    _need_config || return
    _hdr "══ Section 5 — Tests mixtes (stress, pression cluster) ══"
    _sync
    local nc="${#NODES_ARR[@]}"
    _run_cluster "M1" "RAM + CPU simultanés"        "11-mixed-ram-cpu.sh"               "$OMEGA_TEST_VMID"
    _run_cluster "M2" "CPU+RAM → migration"         "12-mixed-cpu-ram-migration.sh"     "$OMEGA_TEST_VMID"
    if $DO_GPU; then
        _run_cluster "M3" "GPU+CPU multi"           "13-mixed-gpu-cpu.sh"               "$OMEGA_TEST_VMID"
    else
        RESULTS["M3"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    _run_cluster "M4" "Stress cluster complet"      "14-mixed-cluster-pressure.sh"      "$nc" 60
    _run_cluster "M5" "Live migration pression"     "15-mixed-live-migration-pressure.sh" "$OMEGA_TEST_VMID"
    _run_cluster "M6" "Rafale démarrages"           "16-mixed-burst-starts.sh"          6
    _run_cluster "M7" "Drain nœud"                  "17-mixed-drain-node.sh"            "${CONTROLLER_NODE}"
}

# ── Pause inter-section ───────────────────────────────────────────────────────
_pause_section() {
    local name="$1"
    $AUTO && return 0
    echo ""
    _sep
    _results_line
    _sep
    echo -e "\n  Section ${BOLD}${name}${RESET} terminée."
    echo -e "  ${BOLD}[Entrée]${RESET} Section suivante   ${BOLD}[m]${RESET} Menu   ${BOLD}[r]${RESET} Résumé   ${BOLD}[q]${RESET} Quitter\n"
    read -rp "  Choix : " c
    case "${c,,}" in
        q) echo "Au revoir."; exit 0 ;;
        m) return 1 ;;
        r) show_results; read -rp "  [Entrée] " _ ;;
    esac
    return 0
}

run_all() {
    _need_config || return
    run_section_1; _pause_section "1 — Isolés"          || return
    run_section_2; _pause_section "2 — Store avancé"    || return
    run_section_3; _pause_section "3 — Cluster"         || return
    run_section_4; _pause_section "4 — GPU"             || return
    run_section_5
    show_results
}

# ── Test individuel ───────────────────────────────────────────────────────────
run_one() {
    _need_config || return
    _sync
    case "${1^^}" in
        00) _run_isolated "00" "Tests unitaires Rust"       "00-unit-tests.sh" ;;
        01) _run_isolated "01" "Smoke test"                 "01-smoke-test.sh" ;;
        02) _run_isolated "02" "Réplication 2 stores"       "02-replication.sh" ;;
        03) _run_isolated "03" "Failover store"             "03-failover.sh" ;;
        04) _run_isolated "04" "Éviction daemon"            "04-eviction-daemon.sh" 20 ;;
        10) _run_isolated "10" "Multi-VM 3 agents"          "10-multi-vm.sh" ;;
        18) _run_isolated "18" "Recall LIFO"                "18-recall-lifo.sh" ;;
        20) _run_isolated "20" "Prefetch stride"            "20-prefetch-stride.sh" ;;
        21) _run_isolated "21" "TLS TOFU"                   "21-tls-tofu.sh" ;;
        05) _run_cluster  "05" "vCPU élastique"             "05-vcpu-elastic.sh"         "$OMEGA_TEST_VMID" ;;
        06) _run_cluster  "06" "GPU placement"              "06-gpu-placement.sh"        "$OMEGA_TEST_VMID" ;;
        07) _run_cluster  "07" "GPU scheduler"              "07-gpu-scheduler.sh"        "$OMEGA_TEST_VMID" "9002" ;;
        08) _run_cluster  "08" "Migration RAM"              "08-migration-ram.sh"        "$OMEGA_TEST_VMID" ;;
        09) _run_cluster  "09" "Orphan cleaner"             "09-orphan-cleaner.sh" ;;
        19) _run_cluster  "19" "Compaction cluster"         "19-compaction.sh"           "$OMEGA_TEST_VMID" ;;
        22) _run_cluster  "22" "Balloon thin-provisioning"  "22-balloon-thinprov.sh"     "$OMEGA_TEST_VMID" ;;
        M1) _run_cluster  "M1" "RAM + CPU simultanés"       "11-mixed-ram-cpu.sh"             "$OMEGA_TEST_VMID" ;;
        M2) _run_cluster  "M2" "CPU+RAM → migration"        "12-mixed-cpu-ram-migration.sh"   "$OMEGA_TEST_VMID" ;;
        M3) _run_cluster  "M3" "GPU+CPU multi"              "13-mixed-gpu-cpu.sh"             "$OMEGA_TEST_VMID" ;;
        M4) _run_cluster  "M4" "Stress cluster"             "14-mixed-cluster-pressure.sh"    "${#NODES_ARR[@]}" 60 ;;
        M5) _run_cluster  "M5" "Live migration pression"    "15-mixed-live-migration-pressure.sh" "$OMEGA_TEST_VMID" ;;
        M6) _run_cluster  "M6" "Rafale démarrages"          "16-mixed-burst-starts.sh"        6 ;;
        M7) _run_cluster  "M7" "Drain nœud"                 "17-mixed-drain-node.sh"          "${CONTROLLER_NODE}" ;;
        *)  _warn "ID de test inconnu : $1" ;;
    esac
}

# ── Menu principal ────────────────────────────────────────────────────────────
show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║          omega-remote-paging — Lab interactif                    ║${RESET}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # ── Statut cluster ────────────────────────────────────────────────────────
    if $CONFIGURED; then
        echo -e "  ${GREEN}●${RESET} Cluster configuré"
        echo -e "    Nœuds (${#NODES_ARR[@]}) : ${CYAN}${OMEGA_NODES}${RESET}"
        echo -e "    Contrôleur        : ${CYAN}${CONTROLLER_NODE}${RESET}"
        echo -e "    VM test           : ${CYAN}${OMEGA_TEST_VMID}${RESET}"
        echo -e "    GPU               : $(${DO_GPU} && echo "${GREEN}activé${RESET}" || echo "${DIM}non (--gpu)${RESET}")"
    else
        echo -e "  ${RED}●${RESET} ${BOLD}Cluster non configuré${RESET} — entrez ${BOLD}[c]${RESET} pour définir les nœuds"
    fi

    # ── Binaires ──────────────────────────────────────────────────────────────
    local bin_ok=true
    for b in node-a-agent node-bc-store; do
        [[ -x "${ROOT_DIR}/target/release/${b}" ]] || { bin_ok=false; break; }
    done
    if $bin_ok; then
        local ts; ts=$(stat -c %y "${ROOT_DIR}/target/release/node-a-agent" 2>/dev/null | cut -d. -f1 || echo "?")
        echo -e "    Binaires          : ${GREEN}compilés${RESET}  ${DIM}(${ts})${RESET}"
    else
        echo -e "    Binaires          : ${YELLOW}non compilés${RESET} — ${DIM}entrez [b] pour builder${RESET}"
    fi

    echo ""
    _sep
    _results_line
    _sep
    echo ""

    # ── Configuration ─────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Configuration ────────────────────────────────────────────${RESET}"
    echo -e "   ${BOLD}[c]${RESET}  Configurer les nœuds du cluster (IPs, VM test, user SSH)"
    echo ""

    # ── Installation ──────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Installation ─────────────────────────────────────────────${RESET}"
    echo -e "   ${BOLD}[I]${RESET}  Installation complète  (désinstaller → build → déployer)"
    echo -e "   ${BOLD}[u]${RESET}  Désinstaller           (arrêter services + supprimer fichiers)"
    echo -e "   ${BOLD}[b]${RESET}  Build                  (cargo build --release --workspace)"
    echo -e "   ${BOLD}[d]${RESET}  Déployer               (copier binaires + démarrer services)"
    echo ""

    # ── Tests par section ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Tests ─────────────────────────────────────────────────────${RESET}"
    echo -e "   ${BOLD}[A]${RESET}  Tout — sections 1→5 avec pause entre chaque"
    echo -e "   ${BOLD}[1]${RESET}  Section 1 — Isolés    : smoke · réplication · failover · éviction"
    echo -e "   ${BOLD}[2]${RESET}  Section 2 — Store+    : recall LIFO · prefetch · TLS TOFU"
    echo -e "   ${BOLD}[3]${RESET}  Section 3 — Cluster   : vCPU · migration · balloon · compaction"
    echo -e "   ${BOLD}[4]${RESET}  Section 4 — GPU       : placement · scheduler$(${DO_GPU} && echo '' || echo '  (--gpu requis)')"
    echo -e "   ${BOLD}[5]${RESET}  Section 5 — Mixtes    : stress · live migration · drain"
    echo ""

    # ── Tests individuels ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Test individuel (entrer le numéro) ───────────────────────${RESET}"
    echo -e "   ${DIM}Isolés  :${RESET}  00  01  02  03  04  10  18  20  21"
    echo -e "   ${DIM}Cluster :${RESET}  05  06  07  08  09  19  22"
    echo -e "   ${DIM}Mixtes  :${RESET}  M1  M2  M3  M4  M5  M6  M7"
    echo ""

    echo -e "   ${BOLD}[g]${RESET}  GPU tests : $(${DO_GPU} && echo "${GREEN}activé  ${RESET}→ [g] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [g] pour activer")"
    echo -e "   ${BOLD}[r]${RESET}  Résumé détaillé des résultats       ${BOLD}[q]${RESET}  Quitter"
    echo ""
    _sep
    echo -ne "  Choix : "
}

# ── Boucle principale ─────────────────────────────────────────────────────────
main_loop() {
    while true; do
        show_menu
        read -r choice || choice="q"
        echo ""
        case "${choice}" in
            c|C) do_configure ;;
            I)   do_install_full ;;
            u|U) do_uninstall ;;
            b|B) do_build ;;
            d|D) do_deploy ;;
            A)   run_all ;;
            1)   run_section_1 ;;
            2)   run_section_2 ;;
            3)   run_section_3 ;;
            4)   run_section_4 ;;
            5)   run_section_5 ;;
            g|G) if $DO_GPU; then DO_GPU=false; _info "Tests GPU désactivés"
                 else DO_GPU=true; _info "Tests GPU activés"
                 fi ;;
            r|R) show_results ;;
            q|Q) echo "Au revoir."; exit 0 ;;
            "")  continue ;;
            # Tests individuels : 00-22 ou M1-M7 (insensible casse)
            [0-9][0-9]|[0-9]|M[1-9]|m[1-9]) run_one "$choice" ;;
            *)   _warn "Choix inconnu : '${choice}'" ;;
        esac

        if ! $AUTO && [[ "${choice}" != "" ]]; then
            echo ""
            read -rp "  [Entrée] revenir au menu  [q] quitter : " back
            [[ "${back,,}" == "q" ]] && { echo "Au revoir."; exit 0; }
        fi
    done
}

# ── Mode auto (CI) ────────────────────────────────────────────────────────────
if $AUTO; then
    if ! $CONFIGURED; then
        echo "Mode --auto : OMEGA_NODES requis (cluster.conf ou variable d'environnement)"
        exit 1
    fi
    _hdr "Mode automatique — installation + toutes les sections"
    do_install_full
    run_all
    show_results
    [[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
fi

main_loop
