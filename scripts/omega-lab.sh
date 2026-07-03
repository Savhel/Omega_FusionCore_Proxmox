#!/usr/bin/env bash
# omega-lab.sh — Lab interactif : configuration + installation + tests
#
# Usage : ./scripts/omega-lab.sh [--gpu] [--ceph] [--long] [--scale] [--fleet] [--destructive] [--provision] [--production] [--auto]
#         ./scripts/omega-lab.sh --list-categories | --category <RAM|CPU|DISK|GPU|NETWORK|MIGRATION|MIXED|OPS|all>
#
# Le script lit scripts/cluster.conf pour la configuration du cluster.
# Si le fichier n'existe pas ou si les nœuds ne sont pas encore définis,
# le menu propose de les saisir directement.
#
# Options :
#   --gpu    activer les tests GPU
#   --ceph   activer les tests Ceph
#   --long   active les tests longue durée
#   --scale  active le test de scalabilité VMs physiques
#   --fleet  active le test puissance Omega sur 40-75 VMs
#   --destructive active les tests qui modifient temporairement le réseau/services
#   --provision cree les VMs physiques configurees avant les tests en mode --auto
#   --production validation complete stricte: GPU/Ceph/long/scale/destructif, aucun skip accepte
#   --auto   toutes les sections sans pause (mode CI)
#   --list-categories  affiche les tests classés par ressource (RAM/CPU/DISK/GPU/…)
#   --category NAME    lance une/des catégorie(s) : --category RAM · --category "CPU GPU" · --category all

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

# ── Options CLI ───────────────────────────────────────────────────────────────
DO_GPU=false; DO_CEPH=false; DO_LONG=false; DO_SCALE=false; DO_FLEET=false; DO_DESTRUCTIVE=false; DO_PROVISION=false; DO_PRODUCTION=false; AUTO=false; DO_LLM=false; DO_LLM_ACCESS=false; DO_LLM_ACCESS_RECONCILE=false; OMEGA_LAB_DRYRUN=false
RUN_CATEGORY=""; LIST_CATEGORIES=false; _want_cat=false
for arg in "$@"; do
    if [[ "$_want_cat" == true ]]; then RUN_CATEGORY="$arg"; _want_cat=false; continue; fi
    case "$arg" in
        --list-categories|--categories) LIST_CATEGORIES=true ;;
        --category=*)  RUN_CATEGORY="${arg#*=}" ;;
        --category|--cat) _want_cat=true ;;
        --gpu)         DO_GPU=true  ;;
        --llm)         DO_LLM=true  ;;
        --llm-access)  DO_LLM_ACCESS=true ;;
        --llm-access-reconcile) DO_LLM_ACCESS_RECONCILE=true ;;
        --dry-run)     OMEGA_LAB_DRYRUN=true ;;
        --ceph)        DO_CEPH=true ;;
        --long)        DO_LONG=true ;;
        --scale)       DO_SCALE=true ;;
        --fleet)       DO_FLEET=true ;;
        --destructive) DO_DESTRUCTIVE=true ;;
        --provision)   DO_PROVISION=true ;;
        --production)  DO_PRODUCTION=true; DO_GPU=true; DO_CEPH=true; DO_LONG=true; DO_SCALE=true; DO_FLEET=true; DO_DESTRUCTIVE=true ;;
        --auto)        AUTO=true    ;;
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
fail()  { _err "$*"; return 1; }

# ── Chargement/rechargement de la configuration ───────────────────────────────
# Appelé à chaque modification de cluster.conf et au démarrage.
OMEGA_NODES=""
OMEGA_CONTROLLER=""
OMEGA_TEST_VMID="9001"
OMEGA_TEST_VMIDS=""
OMEGA_PROVISION_VMIDS=""
OMEGA_VM_STORAGE="ceph-vm"
OMEGA_VM_BRIDGE="vmbr0"
OMEGA_VM_IMAGE_REMOTE="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
OMEGA_VM_IMAGE_LOCAL=""
OMEGA_VM_SSHKEY_REMOTE="/root/.ssh/id_rsa.pub"
OMEGA_VM_MEMORY=3072
OMEGA_VM_BALLOON=512
OMEGA_VM_CORES=4
OMEGA_VM_VCPUS=1
OMEGA_VM_DISK_MAX_GIB=20
OMEGA_VM_GPU_VRAM_MIB=0
OMEGA_QGA_WATCHDOG_NODES=""
OMEGA_QGA_WATCHDOG_VMIDS=""
OMEGA_QGA_WATCHDOG_ROOT_PASSWORD="root"
OMEGA_QGA_WATCHDOG_RESET_STUCK=0
OMEGA_QGA_WATCHDOG_INTERVAL_SECS=60
OMEGA_GPU_NODES=""
OMEGA_GPU_PRIMARY_NODE=""
OMEGA_GPU_PROXY_URL=""
OMEGA_GPU_PROXY_LISTEN="0.0.0.0:9400"
OMEGA_GPU_PROXY_MAX_CONCURRENT=1
OMEGA_GPU_PROXY_TOTAL_VRAM_MIB=0
OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS=900
OMEGA_GPU_MIGRATE_TO_GPU_NODE=1
OMEGA_GPU_FALLBACK_NETWORK=1
OMEGA_GPU_PROXY_API_TOKEN_FILE="/etc/omega/gpu-proxy.token"
OMEGA_GPU_PROXY_API_TOKEN=""
OMEGA_SCALE_STEPS=""
OMEGA_SCALE_STOP_AFTER=0
OMEGA_SCALE_DESTROY_AFTER=0
OMEGA_SCALE_CLEANUP_SCOPE="started"
OMEGA_TEST_TIMEOUT_MULTIPLIER=1
OMEGA_MIGRATION_TIMEOUT_SECS=120
OMEGA_CEPH_TIMEOUT_SECS=60
OMEGA_DISK_TIMEOUT_SECS=60
OMEGA_SCALE_TIMEOUT_SECS=1800
OMEGA_FLEET_VMIDS=""
OMEGA_FLEET_VM_COUNT=50
OMEGA_FLEET_CHAOS_VM_COUNT=75
OMEGA_FLEET_DURATION_SECS=900
OMEGA_FLEET_PHASE_SECS=180
OMEGA_FLEET_BATCH_SIZE=10
OMEGA_FLEET_MIGRATIONS=12
OMEGA_FLEET_GPU_VM_COUNT=12
OMEGA_FLEET_GPU_JOB_N=1024
OMEGA_FLEET_GPU_JOB_VRAM_MIB=256
DEPLOY_USER="root"
STORE_PORT="9100"
STATUS_PORT="9200"
NODES_ARR=()
TEST_VMIDS_ARR=()
CONTROLLER_NODE=""
STORES_CSV=""
STATUS_CSV=""
CONFIGURED=false

_load_config() {
    # Priorité : variables d'environnement exportées > cluster.conf
    # printenv ne retourne que les vraies variables exportées, pas les variables shell de session
    local env_nodes
    env_nodes="$(printenv OMEGA_NODES 2>/dev/null || true)"
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
    [[ -n "$env_nodes" ]] && OMEGA_NODES="$env_nodes"

    OMEGA_NODES="${OMEGA_NODES:-}"
    OMEGA_TEST_VMID="${OMEGA_TEST_VMID:-9001}"
    OMEGA_TEST_VMIDS="${OMEGA_TEST_VMIDS:-$OMEGA_TEST_VMID}"
    OMEGA_PROVISION_VMIDS="${OMEGA_PROVISION_VMIDS:-$OMEGA_TEST_VMIDS}"
    OMEGA_VM_STORAGE="${OMEGA_VM_STORAGE:-ceph-vm}"
    OMEGA_VM_BRIDGE="${OMEGA_VM_BRIDGE:-vmbr0}"
    OMEGA_VM_IMAGE_REMOTE="${OMEGA_VM_IMAGE_REMOTE:-/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2}"
    OMEGA_VM_IMAGE_LOCAL="${OMEGA_VM_IMAGE_LOCAL:-}"
    OMEGA_VM_TEMPLATE_ID="${OMEGA_VM_TEMPLATE_ID:-2299}"
    OMEGA_VM_LINKED_CLONE="${OMEGA_VM_LINKED_CLONE:-1}"
    OMEGA_VM_SSHKEY_REMOTE="${OMEGA_VM_SSHKEY_REMOTE:-/root/.ssh/id_rsa.pub}"
    OMEGA_VM_MEMORY="${OMEGA_VM_MEMORY:-3072}"
    OMEGA_VM_BALLOON="${OMEGA_VM_BALLOON:-512}"
    OMEGA_VM_CORES="${OMEGA_VM_CORES:-4}"
    OMEGA_VM_SOCKETS="${OMEGA_VM_SOCKETS:-1}"
    OMEGA_VM_VCPUS="${OMEGA_VM_VCPUS:-1}"
    OMEGA_VM_DISK_MAX_GIB="${OMEGA_VM_DISK_MAX_GIB:-20}"
    OMEGA_VM_GPU_VRAM_MIB="${OMEGA_VM_GPU_VRAM_MIB:-0}"
    OMEGA_VM_ROOT_PASSWORD="${OMEGA_VM_ROOT_PASSWORD:-root}"
    OMEGA_PROVISION_RANDOMIZE="${OMEGA_PROVISION_RANDOMIZE:-1}"
    OMEGA_PROVISION_RECREATE_BAD="${OMEGA_PROVISION_RECREATE_BAD:-1}"
    OMEGA_PROVISION_RESOURCE_ONLY="${OMEGA_PROVISION_RESOURCE_ONLY:-0}"
    OMEGA_PROVISION_BOOT_WAIT_SECS="${OMEGA_PROVISION_BOOT_WAIT_SECS:-180}"
    # Réseau privé VMs
    OMEGA_NET_VM_BRIDGE="${OMEGA_NET_VM_BRIDGE:-}"
    OMEGA_NET_VM_VLAN_TAG="${OMEGA_NET_VM_VLAN_TAG:-}"
    OMEGA_NET_VM_IP_PREFIX="${OMEGA_NET_VM_IP_PREFIX:-}"
    OMEGA_NET_VM_IP_START="${OMEGA_NET_VM_IP_START:-101}"
    OMEGA_NET_VM_GATEWAY="${OMEGA_NET_VM_GATEWAY:-}"
    OMEGA_NET_VM_NETMASK="${OMEGA_NET_VM_NETMASK:-24}"
    OMEGA_NET_VM_DNS_IP="${OMEGA_NET_VM_DNS_IP:-}"
    # Distribution des VMs par nœud
    OMEGA_VM_NODE_DISTRIBUTION="${OMEGA_VM_NODE_DISTRIBUTION:-}"
    OMEGA_VM_NODE_DEFAULT_MAX="${OMEGA_VM_NODE_DEFAULT_MAX:-2}"
    OMEGA_QGA_WATCHDOG_NODES="${OMEGA_QGA_WATCHDOG_NODES:-${OMEGA_NODES}}"
    OMEGA_QGA_WATCHDOG_VMIDS="${OMEGA_QGA_WATCHDOG_VMIDS:-}"
    OMEGA_QGA_WATCHDOG_ROOT_PASSWORD="${OMEGA_QGA_WATCHDOG_ROOT_PASSWORD:-${OMEGA_VM_ROOT_PASSWORD:-root}}"
    OMEGA_QGA_WATCHDOG_RESET_STUCK="${OMEGA_QGA_WATCHDOG_RESET_STUCK:-0}"
    OMEGA_QGA_WATCHDOG_INTERVAL_SECS="${OMEGA_QGA_WATCHDOG_INTERVAL_SECS:-60}"
    OMEGA_GPU_NODES="${OMEGA_GPU_NODES:-}"
    OMEGA_GPU_PRIMARY_NODE="${OMEGA_GPU_PRIMARY_NODE:-}"
    OMEGA_GPU_PROXY_URL="${OMEGA_GPU_PROXY_URL:-}"
    OMEGA_GPU_PROXY_LISTEN="${OMEGA_GPU_PROXY_LISTEN:-0.0.0.0:9400}"
    OMEGA_GPU_PROXY_MAX_CONCURRENT="${OMEGA_GPU_PROXY_MAX_CONCURRENT:-1}"
    OMEGA_GPU_PROXY_TOTAL_VRAM_MIB="${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}"
    OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS="${OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS:-900}"
    OMEGA_GPU_MIGRATE_TO_GPU_NODE="${OMEGA_GPU_MIGRATE_TO_GPU_NODE:-1}"
    OMEGA_GPU_FALLBACK_NETWORK="${OMEGA_GPU_FALLBACK_NETWORK:-1}"
    OMEGA_GPU_PROXY_API_TOKEN_FILE="${OMEGA_GPU_PROXY_API_TOKEN_FILE:-/etc/omega/gpu-proxy.token}"
    OMEGA_GPU_PROXY_API_TOKEN="${OMEGA_GPU_PROXY_API_TOKEN:-}"
    OMEGA_SCALE_STEPS="${OMEGA_SCALE_STEPS:-}"
    OMEGA_SCALE_STOP_AFTER="${OMEGA_SCALE_STOP_AFTER:-0}"
    OMEGA_SCALE_DESTROY_AFTER="${OMEGA_SCALE_DESTROY_AFTER:-0}"
    OMEGA_SCALE_CLEANUP_SCOPE="${OMEGA_SCALE_CLEANUP_SCOPE:-started}"
    OMEGA_TEST_TIMEOUT_MULTIPLIER="${OMEGA_TEST_TIMEOUT_MULTIPLIER:-1}"
    OMEGA_MIGRATION_TIMEOUT_SECS="${OMEGA_MIGRATION_TIMEOUT_SECS:-120}"
    OMEGA_CEPH_TIMEOUT_SECS="${OMEGA_CEPH_TIMEOUT_SECS:-60}"
    OMEGA_DISK_TIMEOUT_SECS="${OMEGA_DISK_TIMEOUT_SECS:-60}"
    OMEGA_SCALE_TIMEOUT_SECS="${OMEGA_SCALE_TIMEOUT_SECS:-1800}"
    OMEGA_FLEET_VMIDS="${OMEGA_FLEET_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}"
    OMEGA_FLEET_VM_COUNT="${OMEGA_FLEET_VM_COUNT:-50}"
    OMEGA_FLEET_CHAOS_VM_COUNT="${OMEGA_FLEET_CHAOS_VM_COUNT:-75}"
    OMEGA_FLEET_DURATION_SECS="${OMEGA_FLEET_DURATION_SECS:-900}"
    OMEGA_FLEET_PHASE_SECS="${OMEGA_FLEET_PHASE_SECS:-180}"
    OMEGA_FLEET_BATCH_SIZE="${OMEGA_FLEET_BATCH_SIZE:-10}"
    OMEGA_FLEET_MIGRATIONS="${OMEGA_FLEET_MIGRATIONS:-12}"
    OMEGA_FLEET_GPU_VM_COUNT="${OMEGA_FLEET_GPU_VM_COUNT:-12}"
    OMEGA_FLEET_GPU_JOB_N="${OMEGA_FLEET_GPU_JOB_N:-1024}"
    OMEGA_FLEET_GPU_JOB_VRAM_MIB="${OMEGA_FLEET_GPU_JOB_VRAM_MIB:-256}"
    IFS=',' read -ra TEST_VMIDS_ARR <<< "$OMEGA_TEST_VMIDS"
    DEPLOY_USER="${DEPLOY_USER:-root}"
    STORE_PORT="${STORE_PORT:-9100}"
    STATUS_PORT="${STATUS_PORT:-9200}"
    SSH_KEY="${SSH_KEY:-${HOME}/.ssh/omega_ed25519}"

    # Options SSH/rsync communes (clé dédiée si elle existe)
    if [[ -f "$SSH_KEY" ]]; then
        SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
        RSYNC_OPTS=(-aq -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new")
    else
        SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
        RSYNC_OPTS=(-aq)
    fi

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

reset_results() {
    RESULTS=()
    DURATIONS=()
    TOTAL_PASS=0
    TOTAL_FAIL=0
    TOTAL_SKIP=0
}

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
    _info "Sync scripts + binaires → ${OMEGA_NODES}..."
    local node bin b
    for node in "${NODES_ARR[@]}"; do
        [[ -n "$node" ]] || continue
        rsync "${RSYNC_OPTS[@]}" --delete "${TESTS_DIR}/" "${DEPLOY_USER}@${node}:/tmp/omega-tests/"
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${DEPLOY_USER}@${node}" "mkdir -p /tmp/omega-tests-bins" 2>/dev/null || true
        for bin in node-a-agent node-bc-store omega-daemon omega-qemu-launcher omega-gpu-proxy; do
            b="${ROOT_DIR}/target/release/${bin}"
            [[ -x "$b" ]] && rsync "${RSYNC_OPTS[@]}" "$b" "${DEPLOY_USER}@${node}:/tmp/omega-tests-bins/${bin}" || true
        done
        for worker in omega-gpu-worker-cpu.py omega-gpu-worker-app.py; do
            b="${ROOT_DIR}/scripts/${worker}"
            if [[ -f "$b" ]]; then
                rsync "${RSYNC_OPTS[@]}" "$b" "${DEPLOY_USER}@${node}:/tmp/omega-tests-bins/${worker}" || true
                ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${DEPLOY_USER}@${node}" "chmod +x /tmp/omega-tests-bins/${worker}" 2>/dev/null || true
            fi
        done
    done
    _ok "Sync OK"
}

_remote_env() {
    echo "OMEGA_NODES='${OMEGA_NODES}' \
OMEGA_CONTROLLER='${CONTROLLER_NODE}' \
OMEGA_TEST_VMID='${OMEGA_TEST_VMID}' \
OMEGA_TEST_VMIDS='${OMEGA_TEST_VMIDS}' \
OMEGA_PROVISION_VMIDS='${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}' \
OMEGA_BIN_DIR='/tmp/omega-tests-bins' \
OMEGA_REMOTE_BIN_DIR='/tmp/omega-tests-bins' \
OMEGA_STORE_PORT='${STORE_PORT}' \
OMEGA_STATUS_PORT='${STATUS_PORT}' \
DEPLOY_USER='${DEPLOY_USER}' \
VMID='${OMEGA_TEST_VMID}' \
CLUSTER_MODE='1' \
OMEGA_DESTRUCTIVE='$($DO_DESTRUCTIVE && echo 1 || echo 0)' \
OMEGA_SOAK_SECS='${OMEGA_SOAK_SECS:-1800}' \
OMEGA_SCALE_VMIDS='${OMEGA_SCALE_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}' \
OMEGA_SCALE_TARGET='${OMEGA_SCALE_TARGET:-500}' \
OMEGA_SCALE_BATCH_SIZE='${OMEGA_SCALE_BATCH_SIZE:-20}' \
OMEGA_SCALE_SOAK_SECS='${OMEGA_SCALE_SOAK_SECS:-${OMEGA_SCALE_TIMEOUT_SECS:-1800}}' \
OMEGA_SCALE_STEPS='${OMEGA_SCALE_STEPS:-}' \
OMEGA_SCALE_STOP_AFTER='${OMEGA_SCALE_STOP_AFTER:-0}' \
OMEGA_SCALE_DESTROY_AFTER='${OMEGA_SCALE_DESTROY_AFTER:-0}' \
OMEGA_SCALE_CLEANUP_SCOPE='${OMEGA_SCALE_CLEANUP_SCOPE:-started}' \
OMEGA_FLEET_VMIDS='${OMEGA_FLEET_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}' \
OMEGA_FLEET_VM_COUNT='${OMEGA_FLEET_VM_COUNT:-50}' \
OMEGA_FLEET_CHAOS_VM_COUNT='${OMEGA_FLEET_CHAOS_VM_COUNT:-75}' \
OMEGA_FLEET_DURATION_SECS='${OMEGA_FLEET_DURATION_SECS:-900}' \
OMEGA_FLEET_PHASE_SECS='${OMEGA_FLEET_PHASE_SECS:-180}' \
OMEGA_FLEET_BATCH_SIZE='${OMEGA_FLEET_BATCH_SIZE:-10}' \
OMEGA_FLEET_MIGRATIONS='${OMEGA_FLEET_MIGRATIONS:-12}' \
OMEGA_FLEET_GPU_VM_COUNT='${OMEGA_FLEET_GPU_VM_COUNT:-12}' \
OMEGA_FLEET_GPU_JOB_N='${OMEGA_FLEET_GPU_JOB_N:-1024}' \
OMEGA_FLEET_GPU_JOB_VRAM_MIB='${OMEGA_FLEET_GPU_JOB_VRAM_MIB:-256}' \
OMEGA_TEST_TIMEOUT_MULTIPLIER='${OMEGA_TEST_TIMEOUT_MULTIPLIER:-1}' \
OMEGA_MIGRATION_TIMEOUT_SECS='${OMEGA_MIGRATION_TIMEOUT_SECS:-120}' \
OMEGA_CEPH_TIMEOUT_SECS='${OMEGA_CEPH_TIMEOUT_SECS:-60}' \
OMEGA_DISK_TIMEOUT_SECS='${OMEGA_DISK_TIMEOUT_SECS:-60}' \
OMEGA_SCALE_TIMEOUT_SECS='${OMEGA_SCALE_TIMEOUT_SECS:-1800}' \
OMEGA_GPU_PRIMARY_NODE='${OMEGA_GPU_PRIMARY_NODE:-}' \
OMEGA_GPU_NODES='${OMEGA_GPU_NODES:-}' \
OMEGA_GPU_PROXY_URL='${OMEGA_GPU_PROXY_URL:-}' \
OMEGA_GPU_PROXY_LISTEN='${OMEGA_GPU_PROXY_LISTEN:-0.0.0.0:9400}' \
OMEGA_GPU_PROXY_BACKEND_COMMAND='${OMEGA_GPU_PROXY_BACKEND_COMMAND:-/tmp/omega-tests-bins/omega-gpu-worker-app.py}' \
OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS='${OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS:-900}' \
OMEGA_GPU_PROXY_TOTAL_VRAM_MIB='${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}' \
OMEGA_GPU_PROXY_MAX_CONCURRENT='${OMEGA_GPU_PROXY_MAX_CONCURRENT:-1}' \
OMEGA_GPU_PROXY_API_TOKEN_FILE='${OMEGA_GPU_PROXY_API_TOKEN_FILE:-/etc/omega/gpu-proxy.token}' \
OMEGA_GPU_PROXY_API_TOKEN='${OMEGA_GPU_PROXY_API_TOKEN:-}' \
OMEGA_GPU_MIGRATE_TO_GPU_NODE='${OMEGA_GPU_MIGRATE_TO_GPU_NODE:-1}' \
OMEGA_GPU_FALLBACK_NETWORK='${OMEGA_GPU_FALLBACK_NETWORK:-1}' \
OMEGA_GPU_PROXY_REQUIRE_CUDA='${OMEGA_GPU_PROXY_REQUIRE_CUDA:-1}' \
OMEGA_GPU_PROXY_REQUIRE_PARALLEL='${OMEGA_GPU_PROXY_REQUIRE_PARALLEL:-1}' \
OMEGA_STRICT_FULL='${OMEGA_STRICT_FULL:-0}' \
OMEGA_REQUIRE_NO_SKIP='${OMEGA_REQUIRE_NO_SKIP:-0}' \
OMEGA_GPU_PROXY_TEST_VM_COUNT='${OMEGA_GPU_PROXY_TEST_VM_COUNT:-3}'"
}

_quote_args() {
    printf ' %q' "$@"
}

_node_ip_for_pve_name() {
    local pve_name="$1" node host
    [[ -n "$pve_name" ]] || return 1
    for node in "${NODES_ARR[@]}"; do
        [[ -n "$node" ]] || continue
        if [[ "$node" == "$pve_name" ]]; then
            printf '%s' "$node"
            return 0
        fi
        host=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=3 -o BatchMode=yes \
            "${DEPLOY_USER}@${node}" "hostname -s 2>/dev/null || hostname" 2>/dev/null || true)
        if [[ "$host" == "$pve_name" ]]; then
            printf '%s' "$node"
            return 0
        fi
    done
    return 1
}

_vm_host_node() {
    local vmid="$1" pve_name node_ip
    [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
    pve_name=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
        "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null | \
        python3 -c "
import sys, json
vmid = int('$vmid')
try:
    for v in json.load(sys.stdin):
        if v.get('vmid') == vmid:
            print(v.get('node', ''))
            break
except Exception:
    pass
" 2>/dev/null | head -1)
    [[ -n "$pve_name" ]] || return 1
    node_ip=$(_node_ip_for_pve_name "$pve_name" || true)
    [[ -n "$node_ip" ]] || return 1
    printf '%s' "$node_ip"
}

# Déploie vm-isolation.sh sur tous les nœuds (chemin de secours /opt/vm-isolation.sh).
# Idempotent : ne dépend pas du paquet .deb, mais ne l'écrase pas s'il est déjà là.
# Permet d'avoir l'isolation OVS/iptables sans aucune étape manuelle (scp).
_deploy_isolation_script() {
    local src="${SCRIPT_DIR}/vm-isolation.sh"
    [[ -f "$src" ]] || return 0
    local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    local node
    for node in "${nodes_arr[@]}"; do
        scp "${SSH_OPTS[@]/#-i/-i}" "$src" \
            "${DEPLOY_USER}@${node}:/opt/vm-isolation.sh" 2>/dev/null \
            && ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "chmod +x /opt/vm-isolation.sh" 2>/dev/null \
            || true
    done
}

_normalize_vmids_spec() {
    local spec="${1// /}"
    local out="" part start end v
    [[ -n "$spec" ]] || return 1
    IFS=',' read -ra _parts <<< "$spec"
    for part in "${_parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            [[ "$start" -le "$end" ]] || return 1
            for ((v=start; v<=end; v++)); do
                out="${out:+$out,}${v}"
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            out="${out:+$out,}${part}"
        else
            return 1
        fi
    done
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

_test_explanation() {
    local id="$1"
    case "$id" in
        00) cat <<'EOF'
Valide la base logicielle du depot.
Le script lance les tests unitaires Rust et verifie que les composants principaux compilent encore.
Un echec ici indique une regression de code, une dependance manquante ou un environnement de build incomplet.
EOF
            ;;
        01) cat <<'EOF'
Valide le chemin minimal agent -> store sur la machine de test.
Le script demarre un store temporaire, lance l'agent en mode demo, force quelques pages a etre stockees, puis verifie que le scenario termine avec SUCCES.
Ce test ne valide pas Proxmox; il valide le socle store/agent, userfaultfd, les binaires et les ports locaux.
EOF
            ;;
        02) cat <<'EOF'
Valide la replication de pages entre deux stores temporaires.
Le script demarre deux stores locaux, lance l'agent avec replication active, puis verifie que le store secondaire contient aussi des pages.
Si ce test echoue, le probleme est dans la replication, les ports, les stores temporaires ou userfaultfd, pas dans la VM Proxmox.
EOF
            ;;
        03) cat <<'EOF'
Valide le failover du store de pages.
Le script demarre deux stores temporaires: fa0 sur le port 9100 et fa1 sur le port 9101. Ces numeros sont des ports TCP, pas des VMID.
Il ecrit des pages sur les deux stores, tue brutalement fa0, puis verifie que fa1 garde les pages et peut continuer a repondre.
EOF
            ;;
        04) cat <<'EOF'
Valide le moteur d'eviction memoire en mode controle.
Le script cree une pression memoire artificielle, declenche l'eviction de pages vers le store, puis verifie que des pages ont bien ete deplacees.
Un echec indique souvent userfaultfd interdit, des permissions kernel manquantes, ou une pression memoire insuffisante.
EOF
            ;;
        05) cat <<'EOF'
Valide le vCPU elastique sur une vraie VM Proxmox.
Le script verifie d'abord que la VM a ete creee pour Omega: vcpus=1 au boot, cores/sockets donnant maxcpus > 1, hotplug CPU actif et QMP accessible.
Ensuite il met la VM sous charge CPU, attend que le daemon augmente les vCPU jusqu'au maximum autorise, puis attend le retour au minimum quand la charge disparait.
Si -smp affiche maxcpus=1, le test doit echouer: la VM a ete demarree avec un profil non hotpluggable et doit etre arretee puis recreee ou corrigee.
EOF
            ;;
        06) cat <<'EOF'
Valide la detection et le placement GPU cote daemon.
Le script interroge le noeud Proxmox et les endpoints Omega pour savoir si un backend GPU est visible et si un budget GPU peut etre attribue a une VM.
Il ne garantit pas le passthrough physique NVIDIA; il valide ce que le daemon expose et peut controler.
EOF
            ;;
        07) cat <<'EOF'
Valide le scheduler GPU entre deux VMs.
Le script prend deux VMIDs, observe les attributions GPU, puis verifie que le daemon arbitre l'acces sans laisser deux VMs bloquer le meme GPU de facon incoherente.
Il peut echouer normalement si aucun GPU exploitable n'existe, si le driver est casse, ou si le lock/QMP n'est pas accessible.
EOF
            ;;
        08) cat <<'EOF'
Valide la migration RAM/VM sur le cluster physique.
Le script choisit une VM running, genere une pression RAM/CPU, observe la decision Omega, puis tente une migration Proxmox si une cible saine existe.
Ce test ne doit pas migrer a tout prix: si Ceph, le reseau ou les ressources cible ne sont pas sains, l'echec signale que le cluster refuse correctement la migration.
EOF
            ;;
        09) cat <<'EOF'
Valide le nettoyage des ressources orphelines.
Le script force/observe des etats ou une VM n'est plus locale ou plus running, puis verifie que le daemon libere les slots CPU, budgets RAM/GPU/I/O et traces associees.
Un echec indique que le daemon garde un etat obsolete ou ne lit pas correctement l'etat Proxmox.
EOF
            ;;
        10) cat <<'EOF'
Valide plusieurs agents contre les stores temporaires.
Le script lance plusieurs agents demo avec des VMID differents pour verifier que le store accepte plusieurs workloads et conserve des metriques coherentes.
Ce n'est pas un test de creation VM; c'est un test de concurrence agent/store.
EOF
            ;;
        18) cat <<'EOF'
Valide le rappel LIFO des pages.
Le script stocke des pages dans un ordre controle puis les rappelle pour verifier que la politique de rappel respecte le comportement attendu.
Un echec indique une regression dans l'ordre interne des pages ou dans le protocole agent/store.
EOF
            ;;
        19) cat <<'EOF'
Valide la compaction cluster.
Le script observe les VMs locales, identifie celles qui peuvent rendre des ressources sans passer sous leur minimum, puis verifie que le daemon applique/rapporte cette compaction.
Il peut echouer si le daemon ne voit pas la VM, si l'API de controle est indisponible, ou si aucune VM ne peut legalement donner de ressources.
EOF
            ;;
        20) cat <<'EOF'
Valide le prefetch par stride.
Le script simule des acces memoire repetitifs, puis verifie que l'agent detecte le motif et precharge les pages suivantes.
Un echec indique souvent un seuil trop strict, un backend memoire incompatible ou une regression du detecteur de pattern.
EOF
            ;;
        21) cat <<'EOF'
Valide TLS et TOFU entre composants Omega.
Le script verifie la generation/lecture des certificats, les empreintes attendues et la capacite des composants a dialoguer avec TLS.
Il peut echouer si les certificats ont ete regeneres sans mise a jour des pairs ou si les chemins TLS ne sont pas deployes.
EOF
            ;;
        22) cat <<'EOF'
Valide le balloon thin-provisioning puis l'escalade vers migration sur une vraie VM Proxmox.
Le script remet la VM a son balloon minimum, lance une forte charge memoire dans l'invite, observe la croissance QEMU du balloon, puis surveille les logs Omega et Proxmox pour verifier qu'une migration est recherchee/lancee.
Il echoue si la RAM active grandit mais qu'aucune recherche/migration n'apparait: cela signifie que la politique RAM reste locale au lieu d'escalader vers un noeud plus sain.
EOF
            ;;
        23|23C) cat <<'EOF'
Valide le scheduler I/O disque.
Le script verifie d'abord les tests unitaires du disk scheduler, puis controle sur le cluster que cgroup v2 expose io.weight/io.stat sous qemu.slice pour les VMs.
Si io.weight n'existe pas, Omega doit signaler "support indisponible" plutot qu'une panne fonctionnelle: le noyau/systemd n'a pas active le controleur I/O pour les scopes QEMU.
EOF
            ;;
        24) cat <<'EOF'
Valide l'installation Omega sur les noeuds.
Le script controle les binaires, les services systemd, les hooks Proxmox, les endpoints HTTP et l'etat du daemon.
Un echec indique un deploiement incomplet, un service arrete ou une version de binaire differente entre noeuds.
EOF
            ;;
        25) cat <<'EOF'
Valide le reseau dans la VM invitee.
Le script cherche l'IP de la VM, teste l'interface, la route, le ping, le DNS et si possible apt.
Il peut echouer si qemu-guest-agent est absent, si DHCP ne donne pas d'IP, si vmbr1/NAT est mal configure, ou si DNS/Internet sont bloques.
EOF
            ;;
        26) cat <<'EOF'
Valide Ceph reel avant les tests qui dependent du stockage partage.
Le script inspecte mon/mgr/osd, les PG, l'etat active+clean, les pools et les storages Proxmox.
Si Ceph est degrade, les tests CPU simples peuvent continuer, mais migration/disque/scale peuvent etre lents ou echouer.
EOF
            ;;
        27) cat <<'EOF'
Valide le GPU reel et le rendu minimal quand le materiel le permet.
Le script inspecte /dev/dri, les permissions, le backend GPU expose par Omega et les commandes de diagnostic disponibles.
Sur NVIDIA, un driver DKMS casse ou incompatible avec le kernel suffit a faire echouer ce test sans remettre en cause CPU/RAM/disque.
EOF
            ;;
        32) cat <<'EOF'
Valide le proxy GPU applicatif Omega.
Le script contacte omega-gpu-proxy, attribue un budget VRAM logique a plusieurs VMs, verifie qu'un job au-dessus du budget est refuse, puis soumet plusieurs jobs matrix_multiply.
Ce test prouve le chemin multi-VM -> API proxy -> budgets VRAM -> file d'attente -> worker applicatif. Il prouve CUDA uniquement si le resultat indique backend=torch device=cuda.
EOF
            ;;
        33) cat <<'EOF'
Collecte les métriques production sur tous les axes du projet.
Le script mesure les endpoints Omega par nœud, l'état Proxmox des VMs, qemu-guest-agent, Ceph, cgroup I/O, le proxy GPU et un micro-benchmark CUDA.
Il écrit un rapport JSON dans /tmp/omega-production-metrics-*.json pour comparer si le cluster est lent ou rapide après plusieurs runs.
EOF
            ;;
        34|M8) cat <<'EOF'
Valide le placement GPU global.
Le script choisit le meilleur nœud GPU selon VRAM libre, RAM, vCPU et pression disque; si la VM n'est pas déjà dessus, il tente une migration Proxmox live, puis vérifie un job CUDA via le proxy.
Si la migration est impossible mais que le fallback réseau est autorisé, il valide que la VM peut quand même consommer le GPU via omega-gpu-proxy.
EOF
            ;;
        35|M9) cat <<'EOF'
Valide le fallback GPU réseau.
Le script ne dépend pas du passthrough GPU dans la VM: il attribue un budget VRAM logique et soumet un job CUDA au proxy applicatif.
Un succès prouve le scénario VM sans GPU local -> API proxy -> worker CUDA sur nœud GPU.
EOF
            ;;
        36) cat <<'EOF'
Valide la concurrence GPU CUDA.
Le script lance plusieurs jobs matrix_multiply CUDA depuis plusieurs VMIDs et exige que le proxy respecte les budgets, refuse le hors-budget et exécute réellement sur backend=torch device=cuda.
Un échec indique souvent une mauvaise configuration OMEGA_GPU_PYTHON, un max_concurrent trop bas ou un worker qui retombe en CPU.
EOF
            ;;
        37) cat <<'EOF'
Valide la puissance Omega sur une flotte physique large.
Le script prend 40 à 50 VMs pour charger simultanément CPU, RAM, disque, GPU proxy et migrations, puis lance un chaos live sur jusqu'à 75 VMs avec démarrages/arrêts aléatoires et travaux mixtes.
Il compare aussi une tâche de référence sur l'hôte physique puis dans une VM pour mesurer le coût Omega/virtualisation sur CPU, RAM et disque, et écrit un rapport JSON exploitable.
EOF
            ;;
        28) cat <<'EOF'
Valide la resilience a une partition reseau controlee.
Le script coupe volontairement une partie du reseau pour observer la reaction du cluster, puis restaure la connectivite.
Ce test est destructif et ne doit etre lance que si --destructive est active et que tu acceptes une perturbation temporaire.
EOF
            ;;
        29) cat <<'EOF'
Valide la stabilite longue duree.
Le script maintient une charge sur plusieurs dimensions, surveille les services, les metriques Omega et les erreurs Proxmox/Ceph.
Il sert a detecter fuites, timeouts, instabilite daemon, degradation progressive ou decisions de migration incoherentes.
EOF
            ;;
        30) cat <<'EOF'
Valide la conformite des VMs de test Omega avant les tests lourds.
Le script controle hotplug, agent, balloon, vcpus, cores/sockets, -smp maxcpus, disque virtio-scsi, bridge reseau et metadata omega_*.
Si ce test echoue, il faut corriger ou recreer les VMs avant d'interpreter les echecs des tests CPU/RAM/GPU/disque.
EOF
            ;;
        31) cat <<'EOF'
Valide la scalabilite physique du cluster.
Le script inventorie les VMs, les demarre par lots, surveille Proxmox/Omega, puis peut nettoyer les VMs creees pour le test selon la configuration.
Il peut echouer si les VMs sont absentes, non conformes, si Ceph est lent, ou si le cluster manque de CPU/RAM/stockage.
EOF
            ;;
        M1) cat <<'EOF'
Scenario mixte RAM + CPU sur VM reelle.
Le script applique simultanement une pression memoire et CPU, puis observe si Omega arbitre correctement balloon, vCPU et partage local.
Il valide l'interaction entre politiques, pas seulement un composant isole.
EOF
            ;;
        M2) cat <<'EOF'
Scenario CPU + RAM pouvant mener a migration.
Le script met une VM sous pression mixte, observe si le noeud devient defavorable, puis verifie si une migration est proposee ou executee vers une cible meilleure.
Il peut echouer si aucune cible n'ameliore reellement l'etat global du cluster.
EOF
            ;;
        M3) cat <<'EOF'
Scenario GPU + CPU.
Le script combine pression CPU et demande GPU pour verifier que le scheduler ne donne pas un budget GPU incoherent a une VM deja mal placee.
Il depend fortement du support GPU reel sur le noeud.
EOF
            ;;
        M4) cat <<'EOF'
Scenario pression cluster globale.
Le script installe/cherche stress-ng sur les noeuds, lance une pression sur plusieurs VMs/noeuds, puis observe l'etat Omega, Proxmox et Ceph.
Il valide la reaction globale du cluster, pas seulement une VM; un noeud injoignable, Ceph lent ou un outil absent fait echouer le scenario.
EOF
            ;;
        M5) cat <<'EOF'
Scenario live migration sous pression.
Le script charge une VM pendant qu'une migration live est tentee, puis verifie que la VM reste running et que les ressources sont nettoyees apres deplacement.
Il depend du stockage partage, du reseau de migration et de la capacite de la cible a accueillir la VM.
EOF
            ;;
        M6) cat <<'EOF'
Scenario rafale de demarrages VM.
Le script demarre plusieurs VMs rapidement pour observer les limites Proxmox, Ceph, hooks Omega et admission de ressources.
Il peut echouer si les VMs manquent, si Ceph est lent ou si Proxmox refuse trop de starts simultanes.
EOF
            ;;
        M7) cat <<'EOF'
Scenario drain d'un noeud.
Le script considere un noeud source comme a vider, puis verifie si les VMs peuvent etre migrees vers les autres noeuds sans casser CPU/RAM/GPU/disque.
Il echoue normalement si les cibles ne peuvent pas absorber les VMs ou si la migration est interdite par Proxmox/Ceph.
EOF
            ;;
        *) cat <<'EOF'
Execute le script de test Omega correspondant avec la configuration courante.
Le test peut echouer si ses prerequis propres ne sont pas satisfaits; lire les etapes affichees juste apres cette description pour identifier le blocage exact.
EOF
            ;;
    esac
}

_explain_test() {
    local id="$1"
    echo ""
    echo -e "${BOLD}${CYAN}Ce que ce test va verifier${RESET}"
    _test_explanation "$id" | sed 's/^/  /'
}

_run_isolated() {
    local num="$1" name="$2" script="$3"; shift 3
    _hdr "  Test ${num} — ${name}  [isolé]"
    _sep
    _explain_test "$num"
    local t0=$SECONDS rc=0
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "systemctl stop omega-daemon 2>/dev/null || true" || true
    local args_str
    args_str="$(_quote_args "$@")"
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 -o BatchMode=yes "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "$(_remote_env) bash '/tmp/omega-tests/$(basename "$script")'${args_str}" || rc=$?
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "systemctl start omega-daemon 2>/dev/null || true; sleep 2" || true
    _record "$num" "$name" "$rc" "$(( SECONDS - t0 ))"
}

_run_local() {
    local num="$1" name="$2" script="$3"; shift 3
    _hdr "  Test ${num} — ${name}  [local]"
    _sep
    _explain_test "$num"
    local t0=$SECONDS rc=0
    REPO_ROOT="$ROOT_DIR" \
    OMEGA_BIN_DIR="$ROOT_DIR/target/release" \
    OMEGA_NODES="${OMEGA_NODES}" \
    bash "${TESTS_DIR}/$(basename "$script")" "$@" || rc=$?
    _record "$num" "$name" "$rc" "$(( SECONDS - t0 ))"
}

_run_cluster() {
    local num="$1" name="$2" script="$3"; shift 3
    _hdr "  Test ${num} — ${name}  [cluster]"
    _sep
    _explain_test "$num"
    local t0=$SECONDS rc=0
    local args_str target_node
    args_str="$(_quote_args "$@")"
    target_node="$CONTROLLER_NODE"
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        target_node="$(_vm_host_node "$1" || echo "$CONTROLLER_NODE")"
        [[ "$target_node" != "$CONTROLLER_NODE" ]] && \
            _info "VM $1 hébergée sur ${target_node}; test lancé sur ce nœud"
    fi
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 -o BatchMode=yes "${DEPLOY_USER}@${target_node}" \
        "$(_remote_env) bash '/tmp/omega-tests/$(basename "$script")'${args_str}" || rc=$?
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
        echo -e "    GPU/proxy   : nodes=${CYAN}${OMEGA_GPU_NODES:-auto}${RESET} · primary=${CYAN}${OMEGA_GPU_PRIMARY_NODE:-auto}${RESET} · ${CYAN}${OMEGA_GPU_PROXY_URL:-auto}${RESET} · vram=${CYAN}${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}${RESET}MiB"
        echo -e "    Timeouts    : ${CYAN}x${OMEGA_TEST_TIMEOUT_MULTIPLIER}, migration=${OMEGA_MIGRATION_TIMEOUT_SECS}s, ceph=${OMEGA_CEPH_TIMEOUT_SECS}s, disk=${OMEGA_DISK_TIMEOUT_SECS}s, scale=${OMEGA_SCALE_TIMEOUT_SECS}s${RESET}"
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

    echo ""
    echo -e "  VMIDs des VMs de test (séparés par virgule, doivent exister dans le cluster)."
    echo -e "  ${DIM}Exemple : 9001,9002,9003${RESET}"
    echo -e "  ${DIM}Tests qui ont besoin de 2 VMs (07-gpu-scheduler) utilisent les 2 premiers.${RESET}"
    echo -e "  ${DIM}Test M7 drain utilise toute la liste.${RESET}"
    echo ""
    _ask "VMIDs de test [défaut : ${OMEGA_TEST_VMIDS:-9001}]"
    read -r input_vmids
    input_vmids="${input_vmids:-${OMEGA_TEST_VMIDS:-9001}}"
    input_vmids="${input_vmids// /}"
    # Premier VMID = OMEGA_TEST_VMID (compat legacy)
    IFS=',' read -ra _tmp_vmids <<< "$input_vmids"
    input_vmid="${_tmp_vmids[0]}"

    echo ""
    echo -e "  VMIDs à créer par [p] provisioning."
    echo -e "  ${DIM}Peut être identique aux VMs de test, ou plus large pour scale.${RESET}"
    echo -e "  ${DIM}Formats acceptés : 9001,9002,9003 ou 9001-9150 ou 9001,9005-9010${RESET}"
    echo ""
    _ask "VMIDs à provisionner [défaut : ${OMEGA_PROVISION_VMIDS:-$input_vmids}]"
    read -r input_provision_vmids
    input_provision_vmids="${input_provision_vmids:-${OMEGA_PROVISION_VMIDS:-$input_vmids}}"
    if ! normalized_provision_vmids="$(_normalize_vmids_spec "$input_provision_vmids")"; then
        _warn "Format VMIDs provisioning invalide, fallback sur VMIDs de test"
        normalized_provision_vmids="$input_vmids"
    fi

    _ask "Utilisateur SSH [défaut : ${DEPLOY_USER}]"
    read -r input_user
    input_user="${input_user:-${DEPLOY_USER}}"

    echo ""
    echo -e "  ${BOLD}Timeouts des tests réels${RESET}"
    echo -e "  Ces valeurs évitent les faux échecs sur cluster lent, Ceph en recovery,"
    echo -e "  lien réseau à 100 Mbps, ou stockage chargé. Elles ne valident pas les"
    echo -e "  performances datacenter : elles donnent seulement plus de temps aux tests."
    echo -e "  ${DIM}Profil normal: multiplier=1, migration=120, ceph=60, disk=60, scale=1800.${RESET}"
    echo -e "  ${DIM}Profil lent recommandé: multiplier=3, migration=900, ceph=900, disk=600, scale=1200.${RESET}"
    echo ""

    _ask "Multiplicateur global timeouts [${OMEGA_TEST_TIMEOUT_MULTIPLIER}]"
    read -r input_timeout_multiplier
    input_timeout_multiplier="${input_timeout_multiplier:-${OMEGA_TEST_TIMEOUT_MULTIPLIER}}"

    _ask "Timeout migration secondes [${OMEGA_MIGRATION_TIMEOUT_SECS}]"
    read -r input_migration_timeout
    input_migration_timeout="${input_migration_timeout:-${OMEGA_MIGRATION_TIMEOUT_SECS}}"

    _ask "Timeout Ceph secondes [${OMEGA_CEPH_TIMEOUT_SECS}]"
    read -r input_ceph_timeout
    input_ceph_timeout="${input_ceph_timeout:-${OMEGA_CEPH_TIMEOUT_SECS}}"

    _ask "Timeout disque/I/O secondes [${OMEGA_DISK_TIMEOUT_SECS}]"
    read -r input_disk_timeout
    input_disk_timeout="${input_disk_timeout:-${OMEGA_DISK_TIMEOUT_SECS}}"

    _ask "Timeout/soak scale secondes [${OMEGA_SCALE_TIMEOUT_SECS}]"
    read -r input_scale_timeout
    input_scale_timeout="${input_scale_timeout:-${OMEGA_SCALE_TIMEOUT_SECS}}"

    for _timeout_value in "$input_timeout_multiplier" "$input_migration_timeout" "$input_ceph_timeout" "$input_disk_timeout" "$input_scale_timeout"; do
        if [[ ! "$_timeout_value" =~ ^[0-9]+$ || "$_timeout_value" -lt 1 ]]; then
            _err "Timeout invalide: $_timeout_value"
            return 1
        fi
    done

    echo ""
    echo -e "  ${BOLD}GPU/proxy applicatif Omega${RESET}"
    echo -e "  Ces valeurs restent portables: utilisez un hostname/IP de OMEGA_NODES."
    echo -e "  Nœuds GPU accepte une liste CSV. Vide = détection automatique par [d]/[I]."
    echo -e "  Nœud GPU principal reste un fallback/préférence; les proxys démarrent sur tous les nœuds GPU."
    echo ""

    _ask "Nœuds GPU CSV [${OMEGA_GPU_NODES:-auto}]"
    read -r input_gpu_nodes
    input_gpu_nodes="${input_gpu_nodes:-${OMEGA_GPU_NODES}}"

    _ask "Nœud GPU principal [${OMEGA_GPU_PRIMARY_NODE:-auto}]"
    read -r input_gpu_primary
    input_gpu_primary="${input_gpu_primary:-${OMEGA_GPU_PRIMARY_NODE}}"

    _ask "URL proxy GPU [${OMEGA_GPU_PROXY_URL:-auto}]"
    read -r input_gpu_proxy_url
    input_gpu_proxy_url="${input_gpu_proxy_url:-${OMEGA_GPU_PROXY_URL}}"

    _ask "Listen proxy GPU [${OMEGA_GPU_PROXY_LISTEN}]"
    read -r input_gpu_proxy_listen
    input_gpu_proxy_listen="${input_gpu_proxy_listen:-${OMEGA_GPU_PROXY_LISTEN}}"

    _ask "Concurrence jobs GPU [${OMEGA_GPU_PROXY_MAX_CONCURRENT}]"
    read -r input_gpu_proxy_max_concurrent
    input_gpu_proxy_max_concurrent="${input_gpu_proxy_max_concurrent:-${OMEGA_GPU_PROXY_MAX_CONCURRENT}}"

    _ask "VRAM totale proxy GPU MiB (0=auto/non forcé) [${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}]"
    read -r input_gpu_proxy_total_vram
    input_gpu_proxy_total_vram="${input_gpu_proxy_total_vram:-${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}}"

    _ask "Timeout worker GPU secondes [${OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS}]"
    read -r input_gpu_proxy_backend_timeout
    input_gpu_proxy_backend_timeout="${input_gpu_proxy_backend_timeout:-${OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS}}"

    _ask "Fichier token proxy GPU [${OMEGA_GPU_PROXY_API_TOKEN_FILE}]"
    read -r input_gpu_proxy_token_file
    input_gpu_proxy_token_file="${input_gpu_proxy_token_file:-${OMEGA_GPU_PROXY_API_TOKEN_FILE}}"

    _ask "Migrer vers nœud GPU si possible 1/0 [${OMEGA_GPU_MIGRATE_TO_GPU_NODE}]"
    read -r input_gpu_migrate
    input_gpu_migrate="${input_gpu_migrate:-${OMEGA_GPU_MIGRATE_TO_GPU_NODE}}"

    _ask "Fallback requêtes GPU réseau si migration impossible 1/0 [${OMEGA_GPU_FALLBACK_NETWORK}]"
    read -r input_gpu_fallback
    input_gpu_fallback="${input_gpu_fallback:-${OMEGA_GPU_FALLBACK_NETWORK}}"

    for _gpu_num in "$input_gpu_proxy_max_concurrent" "$input_gpu_proxy_total_vram" "$input_gpu_proxy_backend_timeout" "$input_gpu_migrate" "$input_gpu_fallback"; do
        if [[ ! "$_gpu_num" =~ ^[0-9]+$ ]]; then
            _err "Valeur GPU numérique invalide: $_gpu_num"
            return 1
        fi
    done

    echo ""
    echo -e "  ${BOLD}Profil de création VM pour l'option [p]${RESET}"
    echo -e "  Ces valeurs doivent produire des VMs Omega conformes: boot vCPU minimum,"
    echo -e "  max hotpluggable via cores*sockets, balloon initial et RAM max."
    echo ""

    _ask "Storage Proxmox cible [${OMEGA_VM_STORAGE}]"
    read -r input_vm_storage
    input_vm_storage="${input_vm_storage:-${OMEGA_VM_STORAGE}}"

    _ask "Bridge VM [${OMEGA_VM_BRIDGE}]"
    read -r input_vm_bridge
    input_vm_bridge="${input_vm_bridge:-${OMEGA_VM_BRIDGE}}"

    _ask "Image qcow2 distante [${OMEGA_VM_IMAGE_REMOTE}]"
    read -r input_vm_image_remote
    input_vm_image_remote="${input_vm_image_remote:-${OMEGA_VM_IMAGE_REMOTE}}"

    _ask "Image qcow2 locale à copier si absente [${OMEGA_VM_IMAGE_LOCAL:-vide}]"
    read -r input_vm_image_local
    input_vm_image_local="${input_vm_image_local:-${OMEGA_VM_IMAGE_LOCAL}}"

    _ask "Template VMID pour clones rapides (vide=désactivé) [${OMEGA_VM_TEMPLATE_ID}]"
    read -r input_vm_template_id
    input_vm_template_id="${input_vm_template_id:-${OMEGA_VM_TEMPLATE_ID}}"

    _ask "Clones liés rapides depuis template 1/0 [${OMEGA_VM_LINKED_CLONE}]"
    read -r input_vm_linked_clone
    input_vm_linked_clone="${input_vm_linked_clone:-${OMEGA_VM_LINKED_CLONE}}"

    _ask "Clé publique distante injectée cloud-init [${OMEGA_VM_SSHKEY_REMOTE}]"
    read -r input_vm_sshkey_remote
    input_vm_sshkey_remote="${input_vm_sshkey_remote:-${OMEGA_VM_SSHKEY_REMOTE}}"

    _ask "RAM max VM MiB [${OMEGA_VM_MEMORY}]"
    read -r input_vm_memory
    input_vm_memory="${input_vm_memory:-${OMEGA_VM_MEMORY}}"

    _ask "RAM initiale/balloon MiB [${OMEGA_VM_BALLOON}]"
    read -r input_vm_balloon
    input_vm_balloon="${input_vm_balloon:-${OMEGA_VM_BALLOON}}"

    _ask "Cores QEMU [${OMEGA_VM_CORES}]"
    read -r input_vm_cores
    input_vm_cores="${input_vm_cores:-${OMEGA_VM_CORES}}"

    _ask "Sockets QEMU [${OMEGA_VM_SOCKETS}]"
    read -r input_vm_sockets
    input_vm_sockets="${input_vm_sockets:-${OMEGA_VM_SOCKETS}}"

    _ask "vCPU au boot [${OMEGA_VM_VCPUS}]"
    read -r input_vm_vcpus
    input_vm_vcpus="${input_vm_vcpus:-${OMEGA_VM_VCPUS}}"

    _ask "Budget disque logique GiB [${OMEGA_VM_DISK_MAX_GIB}]"
    read -r input_vm_disk_max_gib
    input_vm_disk_max_gib="${input_vm_disk_max_gib:-${OMEGA_VM_DISK_MAX_GIB}}"

    _ask "Budget VRAM MiB [${OMEGA_VM_GPU_VRAM_MIB}]"
    read -r input_vm_gpu_vram_mib
    input_vm_gpu_vram_mib="${input_vm_gpu_vram_mib:-${OMEGA_VM_GPU_VRAM_MIB}}"

    _ask "Mot de passe root des VMs [${OMEGA_VM_ROOT_PASSWORD}]"
    read -r input_vm_root_password
    input_vm_root_password="${input_vm_root_password:-${OMEGA_VM_ROOT_PASSWORD}}"

    _ask "Randomiser les profils conformes Omega 1/0 [${OMEGA_PROVISION_RANDOMIZE}]"
    read -r input_provision_randomize
    input_provision_randomize="${input_provision_randomize:-${OMEGA_PROVISION_RANDOMIZE}}"

    _ask "Supprimer/recréer automatiquement les VMs non conformes 1/0 [${OMEGA_PROVISION_RECREATE_BAD}]"
    read -r input_provision_recreate_bad
    input_provision_recreate_bad="${input_provision_recreate_bad:-${OMEGA_PROVISION_RECREATE_BAD}}"

    _ask "Attente boot/cloud-init avant checks secondes [${OMEGA_PROVISION_BOOT_WAIT_SECS}]"
    read -r input_provision_boot_wait
    input_provision_boot_wait="${input_provision_boot_wait:-${OMEGA_PROVISION_BOOT_WAIT_SECS}}"

    for _vm_num in "$input_vm_memory" "$input_vm_balloon" "$input_vm_cores" "$input_vm_sockets" "$input_vm_vcpus" "$input_vm_disk_max_gib" "$input_vm_gpu_vram_mib" "$input_provision_randomize" "$input_provision_recreate_bad" "$input_provision_boot_wait" "$input_vm_linked_clone"; do
        if [[ ! "$_vm_num" =~ ^[0-9]+$ ]]; then
            _err "Valeur VM numérique invalide: $_vm_num"
            return 1
        fi
    done
    if [[ -n "$input_vm_template_id" && ! "$input_vm_template_id" =~ ^[0-9]+$ ]]; then
        _err "Template VMID invalide: $input_vm_template_id"
        return 1
    fi
    local input_vm_max_vcpus=$(( input_vm_cores * input_vm_sockets ))
    if [[ "$input_vm_balloon" -le 0 || "$input_vm_balloon" -ge "$input_vm_memory" ]]; then
        _err "RAM VM invalide: balloon=${input_vm_balloon} doit être > 0 et < memory=${input_vm_memory}"
        return 1
    fi
    if [[ "$input_vm_max_vcpus" -le 1 ]]; then
        _err "CPU VM invalide: cores*sockets=${input_vm_max_vcpus}; il faut au moins 2 vCPU max"
        return 1
    fi
    if [[ "$input_vm_vcpus" -ge "$input_vm_max_vcpus" ]]; then
        _err "CPU VM invalide: vcpus=${input_vm_vcpus} >= cores*sockets=${input_vm_max_vcpus}"
        return 1
    fi

    # Sauvegarder la section réseau avant écrasement
    cp "$CONF_FILE" "${CONF_FILE}.pre_c" 2>/dev/null || true

    # Sauvegarder dans cluster.conf
    cat > "$CONF_FILE" <<EOF
# Configuration du cluster omega-remote-paging.
# Généré par omega-lab.sh — $(date)

# Nœuds du cluster (IPs ou hostnames résolvables depuis tous les nœuds).
OMEGA_NODES="${input_nodes}"

# Nœud qui exécute le contrôleur (un seul au choix).
OMEGA_CONTROLLER="${input_ctrl}"

# VMIDs des VMs de test existantes dans le cluster (séparées par virgule).
# Ces VMs doivent être démarrées avant de lancer les tests cluster.
OMEGA_TEST_VMIDS="${input_vmids}"
OMEGA_TEST_VMID="${input_vmid}"

# VMIDs créés par l'action [p] provisioning.
# Peut être plus large que OMEGA_TEST_VMIDS pour les tests scale.
OMEGA_PROVISION_VMIDS="${normalized_provision_vmids}"

# Utilisateur SSH pour la connexion aux nœuds.
DEPLOY_USER="${input_user}"

# Ports (ne pas modifier sauf si conflit)
STORE_PORT=9100
STATUS_PORT=9200

# Timeouts pour tests réels.
# Augmenter ces valeurs sur cluster lent/degrade évite les faux échecs,
# mais ne rend pas les mesures de performance valides.
OMEGA_TEST_TIMEOUT_MULTIPLIER="${input_timeout_multiplier}"
OMEGA_MIGRATION_TIMEOUT_SECS="${input_migration_timeout}"
OMEGA_CEPH_TIMEOUT_SECS="${input_ceph_timeout}"
OMEGA_DISK_TIMEOUT_SECS="${input_disk_timeout}"
OMEGA_SCALE_TIMEOUT_SECS="${input_scale_timeout}"

# Tests flotte Omega lourds (40-50 VMs + chaos jusqu'à 75 VMs).
OMEGA_FLEET_VMIDS="${OMEGA_FLEET_VMIDS:-${normalized_provision_vmids}}"
OMEGA_FLEET_VM_COUNT="${OMEGA_FLEET_VM_COUNT:-50}"
OMEGA_FLEET_CHAOS_VM_COUNT="${OMEGA_FLEET_CHAOS_VM_COUNT:-75}"
OMEGA_FLEET_DURATION_SECS="${OMEGA_FLEET_DURATION_SECS:-900}"
OMEGA_FLEET_PHASE_SECS="${OMEGA_FLEET_PHASE_SECS:-180}"
OMEGA_FLEET_BATCH_SIZE="${OMEGA_FLEET_BATCH_SIZE:-10}"
OMEGA_FLEET_MIGRATIONS="${OMEGA_FLEET_MIGRATIONS:-12}"
OMEGA_FLEET_GPU_VM_COUNT="${OMEGA_FLEET_GPU_VM_COUNT:-12}"
OMEGA_FLEET_GPU_JOB_N="${OMEGA_FLEET_GPU_JOB_N:-1024}"
OMEGA_FLEET_GPU_JOB_VRAM_MIB="${OMEGA_FLEET_GPU_JOB_VRAM_MIB:-256}"

# GPU/proxy applicatif Omega.
# OMEGA_GPU_NODES vide = detection automatique au deploiement.
# OMEGA_GPU_PRIMARY_NODE vide = premier noeud GPU detecte.
# OMEGA_GPU_PROXY_URL vide = derivee depuis OMEGA_GPU_PRIMARY_NODE.
OMEGA_GPU_NODES="${input_gpu_nodes}"
OMEGA_GPU_PRIMARY_NODE="${input_gpu_primary}"
OMEGA_GPU_PROXY_URL="${input_gpu_proxy_url}"
OMEGA_GPU_PROXY_LISTEN="${input_gpu_proxy_listen}"
OMEGA_GPU_PROXY_MAX_CONCURRENT="${input_gpu_proxy_max_concurrent}"
OMEGA_GPU_PROXY_TOTAL_VRAM_MIB="${input_gpu_proxy_total_vram}"
OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS="${input_gpu_proxy_backend_timeout}"
OMEGA_GPU_PROXY_API_TOKEN_FILE="${input_gpu_proxy_token_file}"
OMEGA_GPU_MIGRATE_TO_GPU_NODE="${input_gpu_migrate}"
OMEGA_GPU_FALLBACK_NETWORK="${input_gpu_fallback}"

# Profil de création des VMs physiques par l'action [p].
OMEGA_VM_STORAGE="${input_vm_storage}"
OMEGA_VM_BRIDGE="${input_vm_bridge}"
OMEGA_VM_IMAGE_REMOTE="${input_vm_image_remote}"
OMEGA_VM_IMAGE_LOCAL="${input_vm_image_local}"
OMEGA_VM_TEMPLATE_ID="${input_vm_template_id}"
OMEGA_VM_LINKED_CLONE="${input_vm_linked_clone}"
OMEGA_VM_SSHKEY_REMOTE="${input_vm_sshkey_remote}"
OMEGA_VM_MEMORY="${input_vm_memory}"
OMEGA_VM_BALLOON="${input_vm_balloon}"
OMEGA_VM_CORES="${input_vm_cores}"
OMEGA_VM_SOCKETS="${input_vm_sockets}"
OMEGA_VM_VCPUS="${input_vm_vcpus}"
OMEGA_VM_DISK_MAX_GIB="${input_vm_disk_max_gib}"
OMEGA_VM_GPU_VRAM_MIB="${input_vm_gpu_vram_mib}"
OMEGA_VM_ROOT_PASSWORD="${input_vm_root_password}"
OMEGA_PROVISION_RANDOMIZE="${input_provision_randomize}"
OMEGA_PROVISION_RECREATE_BAD="${input_provision_recreate_bad}"
OMEGA_PROVISION_BOOT_WAIT_SECS="${input_provision_boot_wait}"
EOF

    # Réinjecter les sections personnalisées (réseau, etc.) qui survivent à [c]
    # Tout ce qui commence par "# ──" après la ligne SSH_KEY est préservé.
    if [[ -f "${CONF_FILE}.pre_c" ]]; then
        local preserved
        preserved="$(awk '/^# ── Réseau/,0' "${CONF_FILE}.pre_c" 2>/dev/null || true)"
        [[ -n "$preserved" ]] && printf '\n%s\n' "$preserved" >> "$CONF_FILE"
        rm -f "${CONF_FILE}.pre_c"
    fi

    _ok "Configuration sauvegardée dans ${CONF_FILE}"
    echo ""

    # Recharger
    _load_config

    echo -e "  ${GREEN}✓${RESET} Nœuds      : ${CYAN}${OMEGA_NODES}${RESET}"
    echo -e "  ${GREEN}✓${RESET} Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo -e "  ${GREEN}✓${RESET} VMs test   : ${CYAN}${OMEGA_TEST_VMIDS}${RESET}"
    echo -e "  ${GREEN}✓${RESET} VMs create : ${CYAN}${OMEGA_PROVISION_VMIDS}${RESET}"
    echo -e "  ${GREEN}✓${RESET} Profil VM  : ${CYAN}vCPU ${OMEGA_VM_VCPUS}/$(( OMEGA_VM_CORES * OMEGA_VM_SOCKETS )), RAM ${OMEGA_VM_BALLOON}/${OMEGA_VM_MEMORY} MiB, bridge ${OMEGA_VM_BRIDGE}, storage ${OMEGA_VM_STORAGE}, template=${OMEGA_VM_TEMPLATE_ID:-non}, linked=${OMEGA_VM_LINKED_CLONE}${RESET}"
    echo -e "  ${GREEN}✓${RESET} GPU/proxy  : nodes=${CYAN}${OMEGA_GPU_NODES:-auto}${RESET} · primary=${CYAN}${OMEGA_GPU_PRIMARY_NODE:-auto}${RESET} · ${CYAN}${OMEGA_GPU_PROXY_URL:-auto}${RESET} · listen=${CYAN}${OMEGA_GPU_PROXY_LISTEN}${RESET} · vram=${CYAN}${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}${RESET}MiB"
    echo -e "  ${GREEN}✓${RESET} User SSH   : ${CYAN}${DEPLOY_USER}${RESET}"
    echo -e "  ${GREEN}✓${RESET} Timeouts   : ${CYAN}x${OMEGA_TEST_TIMEOUT_MULTIPLIER}, migration=${OMEGA_MIGRATION_TIMEOUT_SECS}s, ceph=${OMEGA_CEPH_TIMEOUT_SECS}s, disk=${OMEGA_DISK_TIMEOUT_SECS}s, scale=${OMEGA_SCALE_TIMEOUT_SECS}s${RESET}"
    echo ""

    # ── Génération et déploiement de la clé SSH ───────────────────────────────
    local SSH_KEY="${HOME}/.ssh/omega_ed25519"
    if [[ ! -f "$SSH_KEY" ]]; then
        _info "Génération d'une clé SSH dédiée omega : ${SSH_KEY}"
        ssh-keygen -t ed25519 -C "omega-lab" -N "" -f "$SSH_KEY" -q
        _ok "Clé générée : ${SSH_KEY}.pub"
    else
        _info "Clé SSH existante : ${SSH_KEY}"
    fi

    # S'assurer que la clé est chargée dans ssh-agent si disponible
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        ssh-add "$SSH_KEY" &>/dev/null || true
    fi

    # Déployer la clé sur chaque nœud (demande le mot de passe si nécessaire)
    _info "Déploiement de la clé SSH sur les nœuds (le mot de passe peut être demandé)..."
    echo ""
    local ssh_ok=true
    for n in "${NODES_ARR[@]}"; do
        # Tester d'abord si la clé est déjà en place (connexion sans mot de passe)
        if ssh -o ConnectTimeout=5 -o BatchMode=yes \
               -i "$SSH_KEY" "${input_user}@${n}" "hostname" &>/dev/null; then
            _ok "  ${input_user}@${n} — clé déjà installée"
        else
            echo -e "  ${YELLOW}→${RESET}  Copie de la clé vers ${input_user}@${n} (entrez le mot de passe) :"
            if ssh-copy-id -i "${SSH_KEY}.pub" \
                           -o ConnectTimeout=10 \
                           "${input_user}@${n}"; then
                _ok "  ${input_user}@${n} — clé installée"
            else
                _warn "  ${input_user}@${n} — échec (vérifier IP, user et que sshd est démarré)"
                ssh_ok=false
            fi
        fi
    done
    echo ""

    # Écrire l'identité SSH dans cluster.conf pour que deploy.sh et les tests l'utilisent
    if ! grep -q "SSH_KEY=" "$CONF_FILE" 2>/dev/null; then
        echo "" >> "$CONF_FILE"
        echo "# Clé SSH dédiée omega (générée par omega-lab.sh)" >> "$CONF_FILE"
        echo "SSH_KEY=\"${SSH_KEY}\"" >> "$CONF_FILE"
    else
        sed -i "s|^SSH_KEY=.*|SSH_KEY=\"${SSH_KEY}\"|" "$CONF_FILE"
    fi

    # ── Test de connectivité finale ───────────────────────────────────────────
    _info "Test de connectivité SSH finale..."
    local ok=true
    for n in "${NODES_ARR[@]}"; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes \
               -i "$SSH_KEY" "${input_user}@${n}" "hostname" &>/dev/null; then
            _ok "  ${input_user}@${n} — OK"
        else
            _warn "  ${input_user}@${n} — ÉCHEC"
            ok=false
        fi
    done
    echo ""
    $ok && _ok "Tous les nœuds sont joignables sans mot de passe" || \
          _warn "Certains nœuds sont injoignables — l'installation peut échouer"

    # Recharger pour que SSH_OPTS soit à jour pour le reste de la session
    _load_config
}

# ── Opérations d'installation ─────────────────────────────────────────────────
_write_or_replace_conf_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONF_FILE"
    else
        echo "${key}=\"${value}\"" >> "$CONF_FILE"
    fi
}

do_provision_vms() {
    _need_config || return
    _hdr "══ Provisioning VMs physiques Omega ══"
    echo -e "  Cette étape crée de vraies VMs Proxmox sur le cluster."
    echo -e "  Elle utilise ${CYAN}${CONTROLLER_NODE}${RESET} comme nœud contrôleur et ${CYAN}${OMEGA_PROVISION_VMIDS}${RESET} comme VMIDs."
    echo ""

    local provision_vmids="${OMEGA_PROVISION_VMIDS:-$OMEGA_TEST_VMIDS}"
    local storage="${OMEGA_VM_STORAGE}"
    local bridge="${OMEGA_VM_BRIDGE}"
    local image_remote="${OMEGA_VM_IMAGE_REMOTE}"
    local image_local="${OMEGA_VM_IMAGE_LOCAL}"
    local template_id="${OMEGA_VM_TEMPLATE_ID:-}"
    local image_prepared="${OMEGA_VM_IMAGE_PREPARED:-0}"
    local linked_clone="${OMEGA_VM_LINKED_CLONE:-1}"
    local sshkey_remote="${OMEGA_VM_SSHKEY_REMOTE}"
    local memory="${OMEGA_VM_MEMORY}"
    local balloon="${OMEGA_VM_BALLOON}"
    local cores="${OMEGA_VM_CORES}"
    local sockets="${OMEGA_VM_SOCKETS}"
    local vcpus="${OMEGA_VM_VCPUS}"
    local disk_max_gib="${OMEGA_VM_DISK_MAX_GIB}"
    local gpu_vram_mib="${OMEGA_VM_GPU_VRAM_MIB}"
    local root_password="${OMEGA_VM_ROOT_PASSWORD:-root}"
    local randomize="${OMEGA_PROVISION_RANDOMIZE:-1}"
    local recreate_bad="${OMEGA_PROVISION_RECREATE_BAD:-1}"
    local resource_only="${OMEGA_PROVISION_RESOURCE_ONLY:-0}"
    local net_bridge="${OMEGA_NET_VM_BRIDGE:-}"
    local net_vlan_tag="${OMEGA_NET_VM_VLAN_TAG:-}"
    local net_ip_prefix="${OMEGA_NET_VM_IP_PREFIX:-}"
    local net_ip_start="${OMEGA_NET_VM_IP_START:-101}"
    local net_vmid_base="${OMEGA_NET_VM_VMID_BASE:-3000}"
    local net_gateway="${OMEGA_NET_VM_GATEWAY:-}"
    local net_netmask="${OMEGA_NET_VM_NETMASK:-24}"
    local net_dns_ip="${OMEGA_NET_VM_DNS_IP:-}"
    # Le bridge réseau privé (OMEGA_NET_VM_BRIDGE) prend le dessus sur OMEGA_VM_BRIDGE quand défini
    [[ -n "$net_bridge" ]] && bridge="$net_bridge"

    if ! $AUTO; then
        _ask "VMIDs à créer [${provision_vmids}]"
        read -r input
        provision_vmids="${input:-$provision_vmids}"
        if ! provision_vmids="$(_normalize_vmids_spec "$provision_vmids")"; then
            _err "Format VMIDs invalide. Exemples valides: 9001,9002,9003 ou 9001-9150"
            return 1
        fi

        _ask "Storage Proxmox cible [${storage}]"
        read -r input
        storage="${input:-$storage}"

        _ask "Bridge VM [${bridge}]"
        read -r input
        bridge="${input:-$bridge}"

        _ask "Image qcow2 distante [${image_remote}]"
        read -r input
        image_remote="${input:-$image_remote}"

        echo -e "  ${DIM}Si l'image existe déjà sur le cluster, laissez vide.${RESET}"
        _ask "Image qcow2 locale à copier [${image_local:-aucune}]"
        read -r input
        image_local="${input:-$image_local}"

        _ask "Template VMID pour clones rapides (vide=désactivé) [${template_id:-aucun}]"
        read -r input
        template_id="${input:-$template_id}"

        _ask "Image déjà préparée, sans virt-customize 1/0 [${image_prepared}]"
        read -r input
        image_prepared="${input:-$image_prepared}"

        _ask "Clones liés rapides depuis template 1/0 [${linked_clone}]"
        read -r input
        linked_clone="${input:-$linked_clone}"

        _ask "Clé publique distante injectée par cloud-init [${sshkey_remote}]"
        read -r input
        sshkey_remote="${input:-$sshkey_remote}"

        _ask "RAM max VM MiB [${memory}]"
        read -r input
        memory="${input:-$memory}"

        _ask "RAM initiale/balloon MiB [${balloon}]"
        read -r input
        balloon="${input:-$balloon}"

        _ask "Max vCPU hotpluggable / cores [${cores}]"
        read -r input
        cores="${input:-$cores}"

        _ask "Sockets QEMU [${sockets}]"
        read -r input
        sockets="${input:-$sockets}"

        _ask "vCPU au boot [${vcpus}]"
        read -r input
        vcpus="${input:-$vcpus}"

        _ask "Budget disque logique GiB [${disk_max_gib}]"
        read -r input
        disk_max_gib="${input:-$disk_max_gib}"

        _ask "Budget VRAM MiB [${gpu_vram_mib}]"
        read -r input
        gpu_vram_mib="${input:-$gpu_vram_mib}"

        _ask "Mot de passe root à imposer dans les VMs [${root_password}]"
        read -r input
        root_password="${input:-$root_password}"

        _ask "Randomiser les profils conformes Omega 1/0 [${randomize}]"
        read -r input
        randomize="${input:-$randomize}"

        _ask "Supprimer/recréer automatiquement les VMs non conformes 1/0 [${recreate_bad}]"
        read -r input
        recreate_bad="${input:-$recreate_bad}"

        _ask "Validation ressources uniquement, sans QGA/ping/stress-ng 1/0 [${resource_only}]"
        read -r input
        resource_only="${input:-$resource_only}"

    fi

    [[ -n "$storage" ]] || { _err "Storage vide"; return 1; }
    [[ -n "$image_remote" || -n "$template_id" ]] || { _err "Image distante vide (ou configurer OMEGA_VM_TEMPLATE_ID)"; return 1; }
    [[ -n "$provision_vmids" ]] || { _err "VMIDs provisioning vides"; return 1; }
    [[ "$cores" =~ ^[0-9]+$ && "$sockets" =~ ^[0-9]+$ && "$vcpus" =~ ^[0-9]+$ && "$randomize" =~ ^[0-9]+$ && "$recreate_bad" =~ ^[0-9]+$ && "$resource_only" =~ ^[0-9]+$ && "$image_prepared" =~ ^[0-9]+$ && "$linked_clone" =~ ^[0-9]+$ ]] || { _err "cores/sockets/vcpus/randomize/recreate/resource_only/image_prepared/linked doivent être numériques"; return 1; }
    if [[ -n "$template_id" && ! "$template_id" =~ ^[0-9]+$ ]]; then
        _err "Template VMID invalide: $template_id"
        return 1
    fi
    local max_vcpus=$(( cores * sockets ))
    if [[ "$max_vcpus" -le 1 ]]; then
        _err "cores*sockets=$max_vcpus invalide pour les VMs Omega: il faut au moins 2 vCPU max pour tester le scale-up"
        return 1
    fi
    if [[ "$vcpus" -ge "$max_vcpus" ]]; then
        _err "vcpus=$vcpus >= cores*sockets=$max_vcpus: la VM démarrerait déjà au plafond et ne pourrait pas tester le scale-up"
        return 1
    fi

    _write_or_replace_conf_var "OMEGA_PROVISION_VMIDS" "$provision_vmids"
    _write_or_replace_conf_var "OMEGA_VM_STORAGE" "$storage"
    _write_or_replace_conf_var "OMEGA_VM_BRIDGE" "$bridge"
    _write_or_replace_conf_var "OMEGA_VM_IMAGE_REMOTE" "$image_remote"
    _write_or_replace_conf_var "OMEGA_VM_IMAGE_LOCAL" "$image_local"
    _write_or_replace_conf_var "OMEGA_VM_TEMPLATE_ID" "$template_id"
    _write_or_replace_conf_var "OMEGA_VM_IMAGE_PREPARED" "$image_prepared"
    _write_or_replace_conf_var "OMEGA_VM_LINKED_CLONE" "$linked_clone"
    _write_or_replace_conf_var "OMEGA_VM_SSHKEY_REMOTE" "$sshkey_remote"
    _write_or_replace_conf_var "OMEGA_VM_MEMORY" "$memory"
    _write_or_replace_conf_var "OMEGA_VM_BALLOON" "$balloon"
    _write_or_replace_conf_var "OMEGA_VM_CORES" "$cores"
    _write_or_replace_conf_var "OMEGA_VM_SOCKETS" "$sockets"
    _write_or_replace_conf_var "OMEGA_VM_VCPUS" "$vcpus"
    _write_or_replace_conf_var "OMEGA_VM_DISK_MAX_GIB" "$disk_max_gib"
    _write_or_replace_conf_var "OMEGA_VM_GPU_VRAM_MIB" "$gpu_vram_mib"
    _write_or_replace_conf_var "OMEGA_VM_ROOT_PASSWORD" "$root_password"
    _write_or_replace_conf_var "OMEGA_PROVISION_RANDOMIZE" "$randomize"
    _write_or_replace_conf_var "OMEGA_PROVISION_RECREATE_BAD" "$recreate_bad"
    _write_or_replace_conf_var "OMEGA_PROVISION_RESOURCE_ONLY" "$resource_only"
    _load_config

    echo ""
    echo -e "  ${BOLD}Résumé provisioning${RESET}"
    echo -e "    Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo -e "    VMIDs      : ${CYAN}${provision_vmids}${RESET}"
    echo -e "    Storage    : ${CYAN}${storage}${RESET}"
    echo -e "    Bridge     : ${CYAN}${bridge}${RESET}"
    echo -e "    Image dist : ${CYAN}${image_remote}${RESET}"
    [[ -n "$image_local" ]] && echo -e "    Image loc  : ${CYAN}${image_local}${RESET}"
    echo -e "    Template   : ${CYAN}${template_id:-désactivé}${RESET} ${DIM}(linked=${linked_clone}, image_prepared=${image_prepared})${RESET}"
    echo -e "    vCPU       : ${CYAN}${vcpus}/${max_vcpus}${RESET} ${DIM}(cores=${cores}, sockets=${sockets})${RESET}"
    echo -e "    RAM        : ${CYAN}${balloon}/${memory} MiB${RESET}"
    echo -e "    Post-check : ${CYAN}validation immédiate par VM: resource_only=${resource_only}, root/${root_password}, QGA, stress-ng, random=${randomize}, recreate=${recreate_bad}${RESET}"
    echo ""

    if ! $AUTO; then
        read -rp "  Créer ces VMs réelles maintenant ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Provisioning annulé."; return; }
    fi

    local args=(
        --controller "$CONTROLLER_NODE"
        --user "$DEPLOY_USER"
        --vmids "$provision_vmids"
        --storage "$storage"
        --bridge "$bridge"
        --image-remote "$image_remote"
        --sshkey-remote "$sshkey_remote"
        --memory "$memory"
        --balloon "$balloon"
        --cores "$cores"
        --sockets "$sockets"
        --vcpus "$vcpus"
        --disk-max-gib "$disk_max_gib"
        --gpu-vram-mib "$gpu_vram_mib"
        --nodes "$OMEGA_NODES"
        --root-password "$root_password"
    )
    [[ -n "$template_id" ]] && args+=(--template-id "$template_id")
    [[ "$linked_clone" == "1" ]] && args+=(--linked-clone)
    [[ "$image_prepared" == "1" ]] && args+=(--image-prepared)
    [[ "$randomize" == "1" ]] && args+=(--randomize)
    [[ "$recreate_bad" == "1" ]] && args+=(--recreate-bad)
    [[ "$resource_only" == "1" ]] && args+=(--resource-only)
    [[ -n "$image_local" ]] && args+=(--image-local "$image_local")
    [[ -f "${SSH_KEY:-}" ]] && args+=(--ssh-key "$SSH_KEY")
    [[ -n "$net_vlan_tag" ]] && args+=(--vm-vlan-tag "$net_vlan_tag")
    [[ -n "$net_ip_prefix" ]] && args+=(--vm-ip-prefix "$net_ip_prefix" --vm-ip-start "$net_ip_start" --vm-netmask "$net_netmask" --vm-vmid-base "$net_vmid_base")
    [[ -n "$net_gateway" ]] && args+=(--vm-gateway "$net_gateway")
    [[ -n "$net_dns_ip" ]] && args+=(--vm-dns-ip "$net_dns_ip")

    OMEGA_VM_NODE_DISTRIBUTION="${OMEGA_VM_NODE_DISTRIBUTION}" \
    OMEGA_VM_NODE_DEFAULT_MAX="${OMEGA_VM_NODE_DEFAULT_MAX}" \
    bash "${SCRIPT_DIR}/provision-omega-vms-remote.sh" "${args[@]}"
    _ok "Provisioning VM terminé"

    # ── Enregistrement DNS automatique des VMs provisionnées ─────────────────
    # Chaque VM omega reçoit son nom dans la zone pfSense Unbound (idempotent).
    # Évite l'oubli manuel qui laissait des VMs (ex. omega-test-3001) non résolvables.
    # Best-effort : n'échoue jamais le provisioning. Le DNS suit le NOM réel de la VM.
    if [[ -n "${OMEGA_NET_PFSENSE_WAN_IP:-}" ]]; then
        _info "Enregistrement DNS automatique (zone ${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal})..."
        local _dns_list dns_vmid v_node v_name v_ip v_label
        _dns_list="$(_normalize_vmids_spec "$provision_vmids" 2>/dev/null || echo "$provision_vmids")"
        local _dns_vmids; IFS=',' read -ra _dns_vmids <<< "$_dns_list"
        for dns_vmid in "${_dns_vmids[@]}"; do
            [[ "$dns_vmid" =~ ^[0-9]+$ ]] || continue
            v_node="$(_vm_host_node "$dns_vmid" || true)"
            [[ -n "$v_node" ]] || { _warn "DNS: VM ${dns_vmid} introuvable, ignorée"; continue; }
            v_name="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
                "${DEPLOY_USER}@${v_node}" "qm config ${dns_vmid} 2>/dev/null | sed -n 's/^name: //p'" 2>/dev/null)"
            [[ -n "$v_name" ]] || v_name="omega-${dns_vmid}"
            v_ip="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
                "${DEPLOY_USER}@${v_node}" "qm config ${dns_vmid} 2>/dev/null | sed -n 's/^ipconfig0:.*ip=\([0-9.]*\).*/\1/p'" 2>/dev/null | head -1)"
            if [[ -z "$v_ip" && -n "${OMEGA_NET_VM_IP_PREFIX:-}" ]]; then
                v_ip="${OMEGA_NET_VM_IP_PREFIX}.$(( ${OMEGA_NET_VM_IP_START:-101} + dns_vmid - ${OMEGA_NET_VM_VMID_BASE:-3000} ))"
            fi
            [[ -n "$v_ip" ]] || { _warn "DNS: pas d'IP pour VM ${dns_vmid} (DHCP ?), ignorée"; continue; }
            v_label="$(_dns_label "$v_name")"
            if _dns_pf_a_register "$v_label" "$v_ip"; then
                _ok "DNS: ${v_label}.${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal} → ${v_ip}"
            else
                _warn "DNS: échec enregistrement ${v_label} (${v_ip}) — réessayer via [D]"
            fi
        done
    else
        _info "DNS: pfSense non configuré (OMEGA_NET_PFSENSE_WAN_IP vide) — enregistrement ignoré"
    fi

    # Isolation automatique sur tous les nœuds (backend OVS ou iptables auto-détecté).
    # On déploie d'abord vm-isolation.sh pour ne dépendre d'aucune étape manuelle.
    _info "Initialisation automatique de l'isolation sur les nœuds (OVS/iptables auto)..."
    local subnet="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}.0/${OMEGA_NET_VM_NETMASK:-24}"
    local iso_gw="${OMEGA_NET_VM_GATEWAY:-10.50.30.1}"
    local iso_bridge="${OMEGA_NET_VM_BRIDGE:-${OMEGA_VM_BRIDGE:-vmbr1}}"
    _deploy_isolation_script   # déploie vm-isolation.sh sur tous les nœuds
    local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    for node in "${nodes_arr[@]}"; do
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
            script=/opt/omega-remote-paging/scripts/vm-isolation.sh
            [[ -x \"\$script\" ]] || script=/opt/vm-isolation.sh
            if [[ -x \"\$script\" ]]; then
                bash \"\$script\" --action init --subnet '${subnet}' --gateway '${iso_gw}' --bridge '${iso_bridge}' 2>/dev/null || true
                bash \"\$script\" --action save --bridge '${iso_bridge}' 2>/dev/null || true
            fi
        " 2>/dev/null || true
    done

    # Synchroniser automatiquement /etc/hosts + routes + pfSense Unbound
    _info "Synchronisation DNS/hosts automatique après provisioning..."
    AUTO=true do_sync_hosts

    # Placement automatique (migration hors nœud sans KVM) : assuré en continu par
    # le contrôleur Omega (migration_daemon + policy_engine, éligibilité kvm_capable).
}

do_build() {
    _hdr "══ Build ══"
    cd "$ROOT_DIR"
    _info "make build-bridge"
    make build-bridge
    _info "cargo build --release --workspace"
    cargo build --release --workspace
    _ok "Build terminé"
    if [[ -f "${ROOT_DIR}/omega-uffd-bridge/omega-uffd-bridge.so" ]]; then
        _ok "  omega-uffd-bridge.so  $(ls -lh "${ROOT_DIR}/omega-uffd-bridge/omega-uffd-bridge.so" | awk '{print $5}')"
    else
        _warn "  omega-uffd-bridge.so absent"
    fi
    for bin in omega-daemon node-a-agent node-bc-store omega-qemu-launcher omega-gpu-proxy; do
        local b="${ROOT_DIR}/target/release/${bin}"
        [[ -x "$b" ]] && _ok "  ${bin}  $(ls -lh "$b" | awk '{print $5}')" || \
                          _warn "  ${bin} absent"
    done
    cd - &>/dev/null
}


do_install_qga_watchdog() {
    _need_config || return
    _hdr "══ Installation watchdog QGA ══"
    local nodes="${OMEGA_QGA_WATCHDOG_NODES:-$OMEGA_NODES}"
    # Par défaut on garde les VMs de test prêtes (conformes + démarrées).
    local vmids="${OMEGA_QGA_WATCHDOG_VMIDS:-${OMEGA_TEST_VMIDS:-}}"
    local root_password="${OMEGA_QGA_WATCHDOG_ROOT_PASSWORD:-${OMEGA_VM_ROOT_PASSWORD:-root}}"
    local reset_stuck="${OMEGA_QGA_WATCHDOG_RESET_STUCK:-0}"
    local interval="${OMEGA_QGA_WATCHDOG_INTERVAL_SECS:-60}"
    local ensure_conformant="${OMEGA_QGA_WATCHDOG_ENSURE_CONFORMANT:-1}"
    local autostart="${OMEGA_QGA_WATCHDOG_AUTOSTART:-}"
    local vcpu_max="${OMEGA_QGA_WATCHDOG_VCPU_MAX:-${OMEGA_VM_CORES:-4}}"
    local balloon_min="${OMEGA_QGA_WATCHDOG_BALLOON_MIN:-${OMEGA_VM_BALLOON:-512}}"
    # VMs d'infra (pfSense/DNS) : autostart-only — gardées allumées, config jamais touchée.
    # Tout le réseau OMEGA (gateway/DNS/internet) en dépend.
    local infra_vmids="${OMEGA_QGA_WATCHDOG_INFRA_VMIDS:-}"
    if [[ -z "$infra_vmids" ]]; then
        local _iv=()
        [[ -n "${OMEGA_NET_PFSENSE_VMID:-}" ]] && _iv+=("$OMEGA_NET_PFSENSE_VMID")
        [[ -n "${OMEGA_NET_DNS_VMID:-}" ]] && _iv+=("$OMEGA_NET_DNS_VMID")
        infra_vmids="$(IFS=,; echo "${_iv[*]}")"
    fi

    echo -e "  Agent systemd installé sur les nœuds Proxmox ciblés."
    echo -e "  Il vérifie QGA périodiquement et répare l'invité via SSH si une IP est visible."
    echo -e "  ${DIM}VMIDs vide = toutes les VMs locales taguées omega.${RESET}"
    echo ""

    if ! $AUTO; then
        _ask "Nœuds où installer le watchdog [${nodes}]"
        read -r input
        nodes="${input:-$nodes}"

        _ask "Limiter à des VMIDs précis, vide=tags omega [${vmids:-vide}]"
        read -r input
        vmids="${input:-$vmids}"
        if [[ -n "$vmids" ]] && ! vmids="$(_normalize_vmids_spec "$vmids")"; then
            _err "Format VMIDs invalide. Exemples valides: 2304,2306,2309 ou 2301-2310"
            return 1
        fi

        _ask "Mot de passe root invité pour réparation SSH [${root_password}]"
        read -r input
        root_password="${input:-$root_password}"

        _ask "Reset automatique VM bloquée sans QGA/IP après 3 échecs 1/0 [${reset_stuck}]"
        read -r input
        reset_stuck="${input:-$reset_stuck}"

        _ask "Intervalle watchdog secondes [${interval}]"
        read -r input
        interval="${input:-$interval}"
    fi

    [[ -n "$nodes" ]] || { _err "Nœuds watchdog vides"; return 1; }
    [[ "$reset_stuck" =~ ^[01]$ ]] || { _err "reset_stuck doit valoir 0 ou 1"; return 1; }
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 10 ]] || { _err "intervalle invalide: $interval"; return 1; }

    _write_or_replace_conf_var "OMEGA_QGA_WATCHDOG_NODES" "$nodes"
    _write_or_replace_conf_var "OMEGA_QGA_WATCHDOG_VMIDS" "$vmids"
    _write_or_replace_conf_var "OMEGA_QGA_WATCHDOG_ROOT_PASSWORD" "$root_password"
    _write_or_replace_conf_var "OMEGA_QGA_WATCHDOG_RESET_STUCK" "$reset_stuck"
    _write_or_replace_conf_var "OMEGA_QGA_WATCHDOG_INTERVAL_SECS" "$interval"
    _load_config

    echo ""
    echo -e "  ${BOLD}Résumé watchdog QGA${RESET}"
    echo -e "    Nœuds      : ${CYAN}${nodes}${RESET}"
    echo -e "    VMIDs      : ${CYAN}${vmids:-tags omega locaux}${RESET}"
    echo -e "    Infra      : ${CYAN}${infra_vmids:-aucune}${RESET} ${DIM}(autostart-only — pfSense/DNS)${RESET}"
    echo -e "    Intervalle : ${CYAN}${interval}s${RESET}"
    echo -e "    Reset auto : ${CYAN}${reset_stuck}${RESET}"
    echo ""

    if ! $AUTO; then
        read -rp "  Installer/mettre à jour le watchdog QGA maintenant ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Installation watchdog annulée."; return; }
    fi

    local wd_args=(
        --nodes "$nodes"
        --user "$DEPLOY_USER"
        --root-password "$root_password"
        --vmids "$vmids"
        --infra-vmids "$infra_vmids"
        --reset-stuck "$reset_stuck"
        --interval "$interval"
        --ensure-conformant "$ensure_conformant"
        --vcpu-max "$vcpu_max"
        --balloon-min "$balloon_min"
    )
    [[ -n "$autostart" ]] && wd_args+=(--autostart "$autostart")
    [[ -f "${SSH_KEY:-}" ]] && wd_args+=(--ssh-key "$SSH_KEY")
    bash "${SCRIPT_DIR}/install-qga-watchdog-remote.sh" "${wd_args[@]}"
    _ok "Watchdog readiness/conformité installé (VMs: ${vmids:-auto omega}, conformant=${ensure_conformant}, vcpu_max=${vcpu_max})"

    # Agent CLUSTER-GLOBAL de répartition (1 instance sur le contrôleur) : maintient
    # la distribution cible (OMEGA_VM_NODE_DISTRIBUTION) par live-migration, en continu.
    local rc_args=(
        --controller "$CONTROLLER_NODE"
        --user "$DEPLOY_USER"
        --interval "${OMEGA_RECONCILE_INTERVAL_SECS:-120}"
        --distribution "${OMEGA_VM_NODE_DISTRIBUTION:-}"
        --default-max "${OMEGA_VM_NODE_DEFAULT_MAX:-2}"
        --max-per-tick "${OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK:-1}"
        --pin-vmids "${OMEGA_RECONCILE_PIN_VMIDS:-}"
    )
    [[ "${OMEGA_RECONCILE_DRY_RUN:-0}" == "1" ]] && rc_args+=(--dry-run)
    [[ -f "${SSH_KEY:-}" ]] && rc_args+=(--ssh-key "$SSH_KEY")
    bash "${SCRIPT_DIR}/install-distribution-reconciler-remote.sh" "${rc_args[@]}"
    _ok "Réconciliateur de distribution installé sur ${CONTROLLER_NODE} (cible: ${OMEGA_VM_NODE_DISTRIBUTION:-défaut})"
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
    SSH_KEY="${SSH_KEY:-}" \
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
    SSH_KEY="${SSH_KEY:-}" \
    OMEGA_GPU_PROXY_ENABLED="$($DO_GPU && echo 1 || echo 0)" \
    OMEGA_GPU_PROXY_LISTEN="${OMEGA_GPU_PROXY_LISTEN}" \
    OMEGA_GPU_PROXY_MAX_CONCURRENT="${OMEGA_GPU_PROXY_MAX_CONCURRENT}" \
    OMEGA_GPU_PROXY_TOTAL_VRAM_MIB="${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}" \
    OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS="${OMEGA_GPU_PROXY_BACKEND_TIMEOUT_SECS}" \
    OMEGA_GPU_NODES="${OMEGA_GPU_NODES:-}" \
    OMEGA_GPU_PRIMARY_NODE="${OMEGA_GPU_PRIMARY_NODE:-}" \
    OMEGA_GPU_PROXY_URL="${OMEGA_GPU_PROXY_URL:-}" \
    OMEGA_GPU_PROXY_API_TOKEN_FILE="${OMEGA_GPU_PROXY_API_TOKEN_FILE:-/etc/omega/gpu-proxy.token}" \
    OMEGA_GPU_PROXY_API_TOKEN="${OMEGA_GPU_PROXY_API_TOKEN:-}" \
    OMEGA_GPU_MIGRATE_TO_GPU_NODE="${OMEGA_GPU_MIGRATE_TO_GPU_NODE}" \
    OMEGA_GPU_FALLBACK_NETWORK="${OMEGA_GPU_FALLBACK_NETWORK}" \
    bash "${SCRIPT_DIR}/deploy.sh"
    _ok "Déploiement terminé"
    _sync
}

do_vm_internet() {
    _need_config || return
    _hdr "══ Accès internet d'une VM ══"
    echo -e "  pfSense : ${CYAN}${OMEGA_NET_PFSENSE_WAN_IP:-?}${RESET}"
    echo ""
    local action vmid
    _ask "Action [enable/disable/list]"
    read -r action
    action="${action:-list}"
    case "$action" in
        list)
            bash "${SCRIPT_DIR}/vm-internet.sh" --list ;;
        enable|disable)
            _ask "VMID de la VM (ex: 2300) ou IP directe"
            read -r vmid
            if [[ "$vmid" =~ ^[0-9]{1,4}$ ]]; then
                bash "${SCRIPT_DIR}/vm-internet.sh" --vmid "$vmid" "--${action}"
            else
                bash "${SCRIPT_DIR}/vm-internet.sh" --ip "$vmid" "--${action}"
            fi ;;
        *) _warn "Action invalide : $action" ;;
    esac
}

do_vm_link() {
    _need_config || return
    _hdr "══ Liens entre VMs ══"
    echo -e "  ${BOLD}Paire${RESET}  : A↔B sans que A↔C ou B↔C ne soient affectés."
    echo -e "  ${BOLD}Groupe${RESET} : maillage complet entre N VMs (toutes les paires du groupe)."
    echo -e "  pfSense : ${CYAN}${OMEGA_NET_PFSENSE_WAN_IP:-?}${RESET}"
    echo ""
    local action mode
    _ask "Action [enable/disable/list]"
    read -r action
    action="${action:-list}"

    case "$action" in
        list)
            _ask "Filtrer par VMID (laisser vide = tout) ou nom de groupe"
            read -r filter
            if [[ -z "$filter" ]]; then
                bash "${SCRIPT_DIR}/vm-link.sh" --list
            elif [[ "$filter" =~ ^[0-9] ]]; then
                bash "${SCRIPT_DIR}/vm-link.sh" --list --vmid "$filter"
            else
                bash "${SCRIPT_DIR}/vm-link.sh" --list --group-name "$filter"
            fi ;;

        enable|disable)
            _ask "Mode [paire/groupe]"
            read -r mode
            mode="${mode:-paire}"
            local args=("--${action}")

            case "$mode" in
                groupe|group)
                    _ask "VMIDs ou IPs séparés par virgule (ex: 2300,2301,2302)"
                    read -r members
                    args+=(--group "$members")
                    _ask "Nom du groupe (optionnel, recommandé pour le désactiver plus tard)"
                    read -r gname
                    [[ -n "$gname" ]] && args+=(--group-name "$gname")
                    bash "${SCRIPT_DIR}/vm-link.sh" "${args[@]}"
                    ;;
                paire|pair|*)
                    _ask "VMID ou IP de la VM A"
                    read -r a
                    _ask "VMID ou IP de la VM B"
                    read -r b
                    [[ "$a" =~ ^[0-9]+\. ]] && args+=(--ip-a "$a") || args+=(--vmid-a "$a")
                    [[ "$b" =~ ^[0-9]+\. ]] && args+=(--ip-b "$b") || args+=(--vmid-b "$b")
                    bash "${SCRIPT_DIR}/vm-link.sh" "${args[@]}"
                    ;;
            esac ;;

        *) _warn "Action invalide : $action" ;;
    esac
}

# ── Modifier les caractéristiques d'une VM existante ──────────────────────────
# Reconfigure vCPU max (cores), RAM max, balloon, disque, VRAM GPU, nom — et
# RÉÉCRIT les métadonnées omega_* de la description de façon cohérente, sinon le
# watchdog de conformité (ensure_conformant) réverterait les changements.
do_vm_reconfigure() {
    _need_config || return
    _hdr "══ Modifier les caractéristiques d'une VM ══"

    local vmid node cfg
    _ask "VMID de la VM à modifier"
    read -r vmid
    [[ "$vmid" =~ ^[0-9]+$ ]] || { _warn "VMID invalide : '$vmid'"; return; }

    node="$(_vm_host_node "$vmid" || true)"
    [[ -n "$node" ]] || { _warn "VM $vmid introuvable dans le cluster."; return; }

    cfg="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "${DEPLOY_USER}@${node}" \
        "qm config $vmid" 2>/dev/null || true)"
    [[ -n "$cfg" ]] || { _warn "Impossible de lire la config de la VM $vmid sur $node."; return; }

    # ── Valeurs actuelles ─────────────────────────────────────────────────────
    local cur_name cur_cores cur_sockets cur_mem cur_balloon cur_desc cur_status
    cur_name="$(printf '%s\n' "$cfg"    | awk -F': ' '$1=="name"{print $2; exit}')"
    cur_cores="$(printf '%s\n' "$cfg"   | awk '/^cores:/{print $2; exit}')";     cur_cores="${cur_cores:-1}"
    cur_sockets="$(printf '%s\n' "$cfg" | awk '/^sockets:/{print $2; exit}')";   cur_sockets="${cur_sockets:-1}"
    cur_mem="$(printf '%s\n' "$cfg"     | awk '/^memory:/{print $2; exit}')";    cur_mem="${cur_mem:-2048}"
    cur_balloon="$(printf '%s\n' "$cfg" | awk '/^balloon:/{print $2; exit}')";   cur_balloon="${cur_balloon:-0}"
    cur_desc="$(printf '%s\n' "$cfg"    | awk -F': ' '$1=="description"{print $2; exit}')"
    local cur_maxvcpu=$(( cur_cores * cur_sockets ))
    local cur_disk cur_vram
    cur_disk="$(printf '%s\n' "$cur_desc" | grep -o 'omega_disk_max_gib=[0-9]*' | head -1 | cut -d= -f2)"; cur_disk="${cur_disk:-20}"
    cur_vram="$(printf '%s\n' "$cur_desc" | grep -o 'omega_gpu_vram_mib=[0-9]*' | head -1 | cut -d= -f2)"; cur_vram="${cur_vram:-0}"
    cur_status="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 "${DEPLOY_USER}@${node}" \
        "qm status $vmid" 2>/dev/null | awk '{print $2}')"

    echo ""
    echo -e "  VM ${CYAN}${vmid}${RESET} (${cur_name:-sans-nom}) sur nœud ${CYAN}${node}${RESET} — état ${CYAN}${cur_status:-?}${RESET}"
    echo -e "    vCPU max   : ${CYAN}${cur_maxvcpu}${RESET} ${DIM}(cores=${cur_cores} × sockets=${cur_sockets})${RESET}"
    echo -e "    RAM max    : ${CYAN}${cur_mem} MiB${RESET}    balloon (min) : ${CYAN}${cur_balloon} MiB${RESET}"
    echo -e "    Disque max : ${CYAN}${cur_disk} GiB${RESET}   VRAM GPU : ${CYAN}${cur_vram} MiB${RESET}"
    echo -e "  ${DIM}Laisser vide = conserver la valeur actuelle.${RESET}"
    echo ""

    local new_name new_maxvcpu new_mem new_balloon new_disk new_vram
    _ask "Nom [${cur_name:-—}]";                 read -r new_name;    new_name="${new_name:-$cur_name}"
    _ask "vCPU max / cores [${cur_maxvcpu}]";     read -r new_maxvcpu; new_maxvcpu="${new_maxvcpu:-$cur_maxvcpu}"
    _ask "RAM max MiB [${cur_mem}]";              read -r new_mem;     new_mem="${new_mem:-$cur_mem}"
    _ask "Balloon min MiB [${cur_balloon}]";      read -r new_balloon; new_balloon="${new_balloon:-$cur_balloon}"
    _ask "Disque max GiB (≥ actuel, ${cur_disk})";read -r new_disk;    new_disk="${new_disk:-$cur_disk}"
    _ask "VRAM GPU MiB [${cur_vram}]";            read -r new_vram;    new_vram="${new_vram:-$cur_vram}"

    # Validation numérique.
    local v
    for v in new_maxvcpu new_mem new_balloon new_disk new_vram; do
        [[ "${!v}" =~ ^[0-9]+$ ]] || { _warn "Valeur non numérique pour $v : '${!v}'"; return; }
    done
    [[ "$new_maxvcpu" -ge 1 ]] || { _warn "vCPU max doit être ≥ 1."; return; }
    [[ "$new_balloon" -le "$new_mem" ]] || { _warn "balloon ($new_balloon) > RAM max ($new_mem) — impossible."; return; }
    if [[ "$new_disk" -lt "$cur_disk" ]]; then
        _warn "Le disque ne peut que grandir (actuel ${cur_disk} GiB, demandé ${new_disk} GiB). Réduction ignorée."
        new_disk="$cur_disk"
    fi

    # Description omega_* cohérente (consommée par le watchdog de conformité + test 30).
    local new_desc="omega_min_vcpus=1 omega_max_vcpus=${new_maxvcpu} omega_memory_min_mib=${new_balloon} omega_memory_max_mib=${new_mem} omega_disk_max_gib=${new_disk} omega_gpu_vram_mib=${new_vram}"

    echo ""
    echo -e "  ${BOLD}Nouvelle configuration :${RESET}"
    echo -e "    Nom        : ${CYAN}${new_name:-—}${RESET}"
    echo -e "    vCPU max   : ${CYAN}${new_maxvcpu}${RESET}  RAM max : ${CYAN}${new_mem} MiB${RESET}  balloon : ${CYAN}${new_balloon} MiB${RESET}"
    echo -e "    Disque max : ${CYAN}${new_disk} GiB${RESET}  VRAM GPU : ${CYAN}${new_vram} MiB${RESET}"
    echo -e "    ${DIM}(hotplug cpu,disk,network conservé · vcpus=1 au boot · description omega_* réécrite)${RESET}"
    echo ""
    if [[ "$new_maxvcpu" != "$cur_maxvcpu" || "$new_mem" != "$cur_mem" ]] && [[ "$cur_status" == "running" ]]; then
        echo -e "  ${YELLOW}Note :${RESET} changer vCPU max / RAM max prend effet au ${BOLD}prochain démarrage${RESET} (un redémarrage sera proposé)."
        echo ""
    fi

    if ! $AUTO; then
        read -rp "  Appliquer ces changements sur VM ${vmid} (${node}) ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Modification annulée."; return; }
    fi

    # qm set : on impose hotplug + vcpus=1 + agent, comme le profil omega standard.
    local set_args=(set "$vmid"
        --cores "$new_maxvcpu" --sockets 1 --vcpus 1
        --hotplug cpu,disk,network --numa 0
        --memory "$new_mem" --balloon "$new_balloon"
        --agent enabled=1
        --description "$new_desc")
    [[ -n "$new_name" ]] && set_args+=(--name "$new_name")

    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=20 "${DEPLOY_USER}@${node}" \
        "qm $(printf '%q ' "${set_args[@]}")" >/dev/null 2>&1; then
        _ok "Caractéristiques mises à jour (cores=${new_maxvcpu} mem=${new_mem} balloon=${new_balloon})."
    else
        _warn "Échec de qm set sur ${node}. Vérifier l'état de la VM."
        return
    fi

    # ── Synchronisation DNS sur changement de nom ─────────────────────────────
    # L'IP de la VM est stable (ipconfig0 / dérivée du VMID) : on déplace le
    # A-record <ancien-nom> → <nouveau-nom> vers la même IP, et on met à jour
    # registre + /etc/hosts sur tous les nœuds.
    if [[ -n "$new_name" && "$new_name" != "$cur_name" ]]; then
        local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
        local vm_ip old_label new_label
        vm_ip="$(printf '%s\n' "$cfg" | sed -n 's/^ipconfig0:.*ip=\([0-9.]*\).*/\1/p' | head -1)"
        if [[ -z "$vm_ip" && -n "${OMEGA_NET_VM_IP_PREFIX:-}" ]]; then
            local last=$(( ${OMEGA_NET_VM_IP_START:-101} + vmid - ${OMEGA_NET_VM_VMID_BASE:-3000} ))
            vm_ip="${OMEGA_NET_VM_IP_PREFIX}.${last}"
        fi
        new_label="$(_dns_label "$new_name")"
        old_label="$(_dns_label "${cur_name:-}")"
        if [[ -z "$vm_ip" ]]; then
            _warn "IP de la VM indéterminée — DNS non synchronisé (enregistrer à la main via [D])."
        elif [[ -z "$new_label" ]]; then
            _warn "Nouveau nom non convertible en label DNS — DNS non synchronisé."
        else
            [[ "$new_label" != "$new_name" ]] && _info "Nom DNS normalisé : ${new_name} → ${new_label}"
            [[ -n "$old_label" && "$old_label" != "$new_label" ]] && _dns_pf_a_delete "$old_label"
            if _dns_pf_a_register "$new_label" "$vm_ip"; then
                _ok "DNS synchronisé : ${new_label}.${domain} → ${vm_ip}"
            else
                _warn "Sync DNS échouée (pfSense joignable ? SSH configuré via [F] ?)."
            fi
        fi
    fi

    # Resize disque (croissance uniquement) si demandé.
    if [[ "$new_disk" -gt "$cur_disk" ]]; then
        if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=30 "${DEPLOY_USER}@${node}" \
            "qm resize $vmid scsi0 ${new_disk}G" >/dev/null 2>&1; then
            _ok "Disque scsi0 agrandi à ${new_disk} GiB."
        else
            _warn "Échec du resize disque (scsi0 → ${new_disk}G). À vérifier manuellement."
        fi
    fi

    # Redémarrage si nécessaire pour appliquer maxcpus/maxmem.
    if [[ "$new_maxvcpu" != "$cur_maxvcpu" || "$new_mem" != "$cur_mem" ]] && [[ "$cur_status" == "running" ]] && ! $AUTO; then
        read -rp "  Redémarrer la VM ${vmid} maintenant pour appliquer vCPU/RAM max ? [oui/N] " reboot
        if [[ "$reboot" =~ ^[Oo]([Uu][Ii])?$ ]]; then
            ssh "${SSH_OPTS[@]}" -o ConnectTimeout=30 "${DEPLOY_USER}@${node}" \
                "qm reboot $vmid" >/dev/null 2>&1 \
                && _ok "Redémarrage demandé." \
                || _warn "Échec du reboot — redémarrer manuellement (qm reboot $vmid)."
        else
            _info "Changements vCPU/RAM max actifs au prochain démarrage."
        fi
    fi
}

do_build_images() {
    _need_config || return
    _hdr "══ Construction du template VM base (VMID ${OMEGA_VM_TEMPLATE_ID:-9001}) ══"
    echo -e "  Télécharge Debian 12 cloud image sur le contrôleur, patch QGA/cloud-init, crée template RBD."
    echo -e "  Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo -e "  Template   : ${CYAN}VMID ${OMEGA_VM_TEMPLATE_ID:-9001}${RESET} → clone en ~4s, QGA en ~50s"
    echo ""

    local tmpl_id="${OMEGA_VM_TEMPLATE_ID:-9001}"
    local storage="${OMEGA_VM_STORAGE:-local}"
    local img_remote="${OMEGA_VM_IMAGE_REMOTE:-/var/lib/vz/template/iso/omega-base-debian12.qcow2}"
    local img_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

    # Vérifier si le template existe déjà
    if ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "qm status ${tmpl_id} 2>/dev/null" >/dev/null 2>&1; then
        if ! $AUTO; then
            read -rp "  Template ${tmpl_id} déjà présent. Reconstruire ? [o/N] " rebuild
            [[ "${rebuild,,}" =~ ^o ]] || { _info "Template conservé."; return; }
        fi
    fi

    if ! $AUTO; then
        read -rp "  Lancer la construction du template ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi

    _info "Construction du template sur ${CONTROLLER_NODE}..."
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER_NODE}" "
set -e
IMG='${img_remote}'
TMPL_ID='${tmpl_id}'
STORAGE='${storage}'

# 1. Télécharger l'image si absente
if [ ! -f \"\$IMG\" ]; then
    echo '[1/5] Téléchargement Debian 12 cloud image...'
    wget -q -O \"\$IMG\" '${img_url}' && echo 'Téléchargé ✓' || { echo 'ERREUR téléchargement'; exit 1; }
else
    echo '[1/5] Image Debian 12 déjà présente'
fi

# 2. libguestfs
echo '[2/5] Vérification libguestfs...'
command -v virt-customize >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y libguestfs-tools -qq

# 3. Télécharger .deb bookworm compatibles et patcher l'image
echo '[3/5] Patch image (QGA + cloud-init + sr_mod + net.ifnames=0)...'
mkdir -p /tmp/omega-bookworm-debs && cd /tmp/omega-bookworm-debs
[ -f qemu-guest-agent*.deb ] || wget -q \"\$(curl -s 'https://packages.debian.org/bookworm/amd64/qemu-guest-agent/download' | grep -o 'http://[^\"]*amd64.deb' | head -1)\" -O qga.deb
[ -f cloud-init*.deb ] || wget -q \"\$(curl -s 'https://packages.debian.org/bookworm/all/cloud-init/download' | grep -o 'http://[^\"]*all.deb' | head -1)\" -O cloud-init.deb
tar -cf /tmp/omega-bookworm-debs.tar -C /tmp/omega-bookworm-debs .

LIBGUESTFS_BACKEND=direct virt-customize -a \"\$IMG\" \\
    --upload /tmp/omega-bookworm-debs.tar:/tmp/debs.tar \\
    --run-command 'mkdir -p /tmp/debs && tar -xf /tmp/debs.tar -C /tmp/debs' \\
    --run-command 'dpkg -i /tmp/debs/qga.deb || true' \\
    --run-command 'dpkg -i /tmp/debs/cloud-init.deb || true' \\
    --run-command 'systemctl enable qemu-guest-agent' \\
    --run-command 'ln -sf /lib/systemd/system/qemu-guest-agent.service /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service 2>/dev/null || true' \\
    --run-command 'echo sr_mod >> /etc/initramfs-tools/modules; echo cdrom >> /etc/initramfs-tools/modules; update-initramfs -u -k all 2>/dev/null || true' \\
    --edit '/etc/default/grub:s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"net.ifnames=0 biosdevname=0 /' \\
    --run-command 'update-grub 2>/dev/null || true' \\
    --run-command 'mkdir -p /etc/cloud/cloud.cfg.d && echo \"datasource_list: [NoCloud, None]\" > /etc/cloud/cloud.cfg.d/99-proxmox.cfg' \\
    --run-command 'rm -rf /tmp/debs /tmp/debs.tar' \\
    2>&1 | grep -E 'Finishing|error|Error' || true
echo 'Image patchée ✓'

# 4. Créer le template Proxmox
echo '[4/5] Création template Proxmox VMID \$TMPL_ID...'
qm destroy \$TMPL_ID --purge --destroy-unreferenced-disks 1 2>/dev/null || true
qm create \$TMPL_ID \\
    --name omega-template-base --ostype l26 --machine q35 \\
    --agent enabled=1 --cpu kvm64 --cores 2 --memory 2048 \\
    --scsihw virtio-scsi-single \\
    --net0 'virtio,bridge=vmbr1,firewall=0' \\
    --serial0 socket --vga serial0 --tags 'omega,template' --ciupgrade 0
qm importdisk \$TMPL_ID \"\$IMG\" \$STORAGE 2>&1 | tail -1
qm set \$TMPL_ID --scsi0 \"\$STORAGE:vm-\${TMPL_ID}-disk-0,discard=on,iothread=1\" \\
    --boot order=scsi0
# Marquer comme préparé pour provision-omega-vms-remote.sh
qm set \$TMPL_ID --description 'omega_template_prepared=1'
qm template \$TMPL_ID
echo '[5/5] Template \$TMPL_ID prêt ✓'
qm list | grep \$TMPL_ID
" 2>&1 | grep -v "% complete" | grep -v "^$"

    local rc=$?
    [[ $rc -eq 0 ]] && _ok "Template ${tmpl_id} opérationnel — clones via [p]" || _err "Échec construction template (rc=$rc)"
}

do_sync_hosts() {
    _need_config || return
    _hdr "══ Sync /etc/hosts + routes Omega sur tous les nœuds ══"

    local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
    local prefix="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}"
    local netmask="${OMEGA_NET_VM_NETMASK:-24}"
    local pfsense_wan="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local vmid_base="${OMEGA_NET_VM_VMID_BASE:-3000}"
    local ip_start="${OMEGA_NET_VM_IP_START:-101}"
    local vmids_str="${OMEGA_PROVISION_VMIDS:-}"
    local storage="${OMEGA_VM_STORAGE:-stockage.ceph}"

    # Découvrir les VMs omega réellement présentes dans le cluster
    _info "Découverte des VMs omega dans le cluster..."
    local vm_list
    vm_list="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER_NODE}" "
pvesh get /cluster/resources --type vm --output-format json 2>/dev/null
" 2>/dev/null | python3 -c "
import json,sys
vms=json.load(sys.stdin)
for v in sorted(vms, key=lambda x:x.get('vmid',0)):
    if v.get('tags','') and 'omega' in v.get('tags','') and v.get('vmid',0) >= 3000:
        print(v['vmid'], v.get('name','?'))
" 2>/dev/null || true)"

    if [[ -z "$vm_list" ]]; then
        _warn "Aucune VM omega trouvée dans le cluster (tags:omega, VMID>=3000)"
        return
    fi

    echo -e "  VMs omega détectées :"
    local hosts_block="# omega-${domain}-begin"
    while IFS=' ' read -r vmid name; do
        local ip_last=$(( ip_start + vmid - vmid_base ))
        local ip="${prefix}.${ip_last}"
        echo -e "    ${CYAN}${vmid}${RESET}  ${name}.${domain}  →  ${ip}"
        hosts_block+=$'\n'"${ip}  ${name}.${domain}  ${name}"
    done <<< "$vm_list"
    hosts_block+=$'\n'"# omega-${domain}-end"

    echo ""
    if ! $AUTO; then
        read -rp "  Mettre à jour /etc/hosts sur tous les nœuds Proxmox ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi

    # Pousser sur tous les nœuds
    local nodes_arr
    IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    for node in "${nodes_arr[@]}"; do
        echo -n "  ${node} : "
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
# Supprimer ancienne section omega
sed -i '/# omega-${domain}-begin/,/# omega-${domain}-end/d' /etc/hosts 2>/dev/null || true
# Ajouter nouvelle section
printf '%s\n' '${hosts_block}' >> /etc/hosts
# Route vers VMs omega via pfSense
ip route replace ${prefix}.0/${netmask} via ${pfsense_wan} 2>/dev/null || true
# Persister la route
grep -q '${prefix}.0' /etc/network/interfaces 2>/dev/null || \
    printf '\nup ip route add ${prefix}.0/${netmask} via ${pfsense_wan} 2>/dev/null || true\n' \
    >> /etc/network/interfaces 2>/dev/null || true
echo OK
" 2>/dev/null && echo -e "${GREEN}OK${RESET}" || echo -e "${RED}ECHEC${RESET}"
    done

    # Mettre aussi à jour pfSense Unbound
    _info "Mise à jour pfSense Unbound host overrides..."
    local pf_script="/tmp/omega_pf_hosts_$$.php"
    {
    echo "<?php"
    echo "require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');"
    echo "if (!isset(\$config['unbound']['hosts'])) \$config['unbound']['hosts'] = array();"
    echo "\$domain = '${domain}';"
    echo "\$added = 0;"
    while IFS=' ' read -r vmid name; do
        local ip_last=$(( ip_start + vmid - vmid_base ))
        local ip="${prefix}.${ip_last}"
        echo "\$vms[] = array('host'=>'${name}','ip'=>'${ip}');"
    done <<< "$vm_list"
    cat << 'PHPEOF'
foreach ($vms as $vm) {
    $exists = false;
    foreach ($config['unbound']['hosts'] as $h) {
        if ($h['host']===$vm['host'] && $h['domain']===$domain) { $exists=true; break; }
    }
    if (!$exists) {
        $config['unbound']['hosts'][] = array(
            'host'=>$vm['host'],'domain'=>$domain,'ip'=>$vm['ip'],
            'descr'=>'Omega VM '.$vm['host'],'aliases'=>'');
        $added++;
        echo "Ajouté: ".$vm['host'].".".$domain." -> ".$vm['ip']."\n";
    }
}
if ($added>0) { write_config("Omega VM hosts"); services_unbound_configure(); echo "Unbound rechargé\n"; }
else { echo "Déjà à jour\n"; }
PHPEOF
    } > "$pf_script"
    scp "${SSH_OPTS[@]/#-i/-i}" "$pf_script" \
        "${OMEGA_NET_PFSENSE_SSH_USER:-admin}@${pfsense_wan}:/tmp/omega_pf_hosts.php" 2>/dev/null && \
    ssh "${SSH_OPTS[@]}" "${OMEGA_NET_PFSENSE_SSH_USER:-admin}@${pfsense_wan}" \
        "php /tmp/omega_pf_hosts.php && rm /tmp/omega_pf_hosts.php" 2>/dev/null \
        && _ok "pfSense Unbound mis à jour" \
        || _warn "pfSense Unbound non mis à jour (SSH non configuré ? → [F])"
    rm -f "$pf_script"

    _ok "Synchronisation terminée — nœuds Proxmox peuvent résoudre les VMs omega par nom"
}

do_setup_pfsense_ssh() {
    _need_config || return
    _hdr "══ Configuration SSH pfSense (clé omega) ══"
    local pfsense_ip="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local pfsense_user="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    local pub_key="${SSH_KEY}.pub"
    [[ -f "$pub_key" ]] || fail "Clé publique introuvable : $pub_key"
    echo -e "  pfSense : ${CYAN}${pfsense_ip}${RESET}"
    echo -e "  Clé     : ${CYAN}${pub_key}${RESET}"
    echo ""
    echo -e "  ${BOLD}Prérequis${RESET} : SSH doit être activé sur pfSense."
    echo -e "  Console pfSense → option ${BOLD}14${RESET} (Enable Secure Shell)"
    echo ""
    _ask "Mot de passe admin pfSense"
    read -rs pf_pass
    echo ""
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$pf_pass" ssh-copy-id \
            -i "$pub_key" \
            -o StrictHostKeyChecking=accept-new \
            -p "${OMEGA_NET_PFSENSE_SSH_PORT:-22}" \
            "${pfsense_user}@${pfsense_ip}" 2>/dev/null \
            && _ok "Clé SSH copiée sur pfSense" \
            || _err "Échec — vérifier que SSH est activé sur pfSense (option 14)"
    else
        # Sans sshpass : copie manuelle via pipe
        local key_content; key_content="$(cat "$pub_key")"
        echo "$pf_pass" | ssh \
            -o StrictHostKeyChecking=accept-new \
            -o PasswordAuthentication=yes \
            -p "${OMEGA_NET_PFSENSE_SSH_PORT:-22}" \
            "${pfsense_user}@${pfsense_ip}" \
            "mkdir -p /root/.ssh && echo '${key_content}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null \
            && _ok "Clé SSH copiée sur pfSense" \
            || {
                _warn "sshpass absent — copie manuelle."
                echo -e "  Lance dans pfSense console (option 8 Shell) :"
                echo -e "  ${CYAN}mkdir -p /root/.ssh && echo '$(cat "$pub_key")' >> /root/.ssh/authorized_keys${RESET}"
            }
    fi
    # Tester la connexion
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -p "${OMEGA_NET_PFSENSE_SSH_PORT:-22}" \
        "${pfsense_user}@${pfsense_ip}" "hostname" 2>/dev/null \
        && _ok "Connexion SSH pfSense fonctionnelle — [w] et [k] opérationnels" \
        || _warn "Test SSH échoué — relancer après avoir activé SSH sur pfSense"
}

# Normalise une chaîne en label DNS valide (minuscules, [a-z0-9-], pas de tiret en bord).
_dns_label() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
        | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'
}

# Crée/met à jour un A-record <name> → <ip> sur pfSense Unbound + registre + /etc/hosts.
# Idempotent (retire d'abord tout A-record existant pour ce host). Réutilisé par [m].
_dns_pf_a_register() {  # <name> <ip>
    local name="$1" ip="$2"
    [[ -n "$name" && -n "$ip" ]] || return 1
    local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
    local pfsense_ip="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local pfsense_user="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    local registry="/etc/omega/dns-registry.json"
    local pf; pf=$(mktemp)
    cat > "$pf" << PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
if (!isset(\$config['unbound']['hosts'])) \$config['unbound']['hosts'] = [];
\$domain='${domain}'; \$host='${name}'; \$ip='${ip}';
\$config['unbound']['hosts'] = array_values(array_filter(\$config['unbound']['hosts'],
    fn(\$h) => !(\$h['host']===\$host && \$h['domain']===\$domain)));
\$config['unbound']['hosts'][] = ['host'=>\$host,'domain'=>\$domain,'ip'=>\$ip,
    'descr'=>'Omega VM '.\$host,'aliases'=>''];
write_config("DNS sync \$host.\$domain");
services_unbound_configure();
echo "A: \$host.\$domain -> \$ip\n";
PHPEOF
    local rc=1
    scp "${SSH_OPTS[@]/#-i/-i}" "$pf" "${pfsense_user}@${pfsense_ip}:/tmp/dns_sync.php" 2>/dev/null \
        && ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" \
            "php /tmp/dns_sync.php && rm -f /tmp/dns_sync.php" >/dev/null 2>&1 && rc=0
    rm -f "$pf"
    local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    local node
    for node in "${nodes_arr[@]}"; do
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
            mkdir -p /etc/omega
            python3 -c \"
import json,os
f='${registry}'
reg=json.load(open(f)) if os.path.exists(f) else []
reg=[e for e in reg if e.get('name')!='${name}']
reg.append({'name':'${name}','ip':'${ip}','port':None,'proto':'tcp'})
json.dump(reg,open(f,'w'),indent=2)
\" 2>/dev/null || true
            sed -i '/ ${name}\$/d; /${name}\\.${domain}/d' /etc/hosts 2>/dev/null || true
            echo '${ip}  ${name}.${domain}  ${name}' >> /etc/hosts
        " 2>/dev/null || true
    done
    return $rc
}

# Supprime un A-record <name> de pfSense Unbound + registre + /etc/hosts. Réutilisé par [m].
_dns_pf_a_delete() {  # <name>
    local name="$1"
    [[ -n "$name" ]] || return 0
    local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
    local pfsense_ip="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local pfsense_user="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    local registry="/etc/omega/dns-registry.json"
    local pf; pf=$(mktemp)
    cat > "$pf" << PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
\$domain='${domain}'; \$host='${name}';
\$config['unbound']['hosts'] = array_values(array_filter(\$config['unbound']['hosts']??[],
    fn(\$h) => !(\$h['host']===\$host && \$h['domain']===\$domain)));
write_config("DNS unsync \$host.\$domain");
services_unbound_configure();
echo "del A: \$host.\$domain\n";
PHPEOF
    scp "${SSH_OPTS[@]/#-i/-i}" "$pf" "${pfsense_user}@${pfsense_ip}:/tmp/dns_unsync.php" 2>/dev/null \
        && ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" \
            "php /tmp/dns_unsync.php && rm -f /tmp/dns_unsync.php" >/dev/null 2>&1 || true
    rm -f "$pf"
    local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    local node
    for node in "${nodes_arr[@]}"; do
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
            sed -i '/${name}\\.${domain}/d; / ${name}\$/d' /etc/hosts 2>/dev/null || true
            python3 -c \"
import json,os
f='${registry}'
if os.path.exists(f):
    reg=[e for e in json.load(open(f)) if e.get('name')!='${name}']
    json.dump(reg,open(f,'w'),indent=2)
\" 2>/dev/null || true
        " 2>/dev/null || true
    done
}

do_vm_autostart() {
    # Rend une VM "always-on" : onboot=1 (démarre au boot du nœud) + ajout au
    # watchdog Omega (la relance si elle s'arrête/plante EN COURS de vie, après grâce).
    # off = désactive les deux. Le VMID est mis sur TOUS les nœuds (le watchdog n'agit
    # qu'en local → où qu'elle migre, elle reste surveillée).
    _need_config || return
    _hdr "══ Redémarrage automatique d'une VM (always-on) ══"
    local vmid action
    if ${AUTO:-false}; then
        vmid="${OMEGA_AUTOSTART_VMID:-}"; action="${OMEGA_AUTOSTART_ACTION:-on}"
    else
        _ask "VMID de la VM"; read -r vmid
        _ask "Activer ou désactiver le redémarrage auto ? [on/off] (on)"; read -r action
        action="${action:-on}"
    fi
    [[ "$vmid" =~ ^[0-9]+$ ]] || { _err "VMID invalide"; return 1; }
    local node_ip; node_ip="$(_vm_host_node "$vmid" || true)"
    [[ -n "$node_ip" ]] || { _err "VM $vmid introuvable dans le cluster"; return 1; }

    local wd_key=(); [[ -f "${SSH_KEY:-}" ]] && wd_key=(--ssh-key "$SSH_KEY")
    if [[ "$action" == "off" ]]; then
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node_ip}" "qm set $vmid --onboot 0" >/dev/null 2>&1 \
            && _ok "onboot=0" || _warn "échec onboot=0"
        bash "${SCRIPT_DIR}/install-qga-watchdog-remote.sh" --nodes "$OMEGA_NODES" \
            --user "$DEPLOY_USER" "${wd_key[@]}" --remove-vmid "$vmid" \
            && _ok "retirée du watchdog" || _warn "échec retrait watchdog"
        _info "VM $vmid : redémarrage automatique DÉSACTIVÉ."
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node_ip}" "qm set $vmid --onboot 1" >/dev/null 2>&1 \
        && _ok "onboot=1 (démarre au boot du nœud)" || _warn "échec onboot=1"
    bash "${SCRIPT_DIR}/install-qga-watchdog-remote.sh" --nodes "$OMEGA_NODES" \
        --user "$DEPLOY_USER" "${wd_key[@]}" --add-vmid "$vmid" \
        && _ok "ajoutée au watchdog (relance si arrêtée/plantée)" || _warn "échec ajout watchdog"
    _info "VM $vmid est maintenant ${GREEN}always-on${RESET} (onboot + watchdog)."
}

do_dns_reconcile() {
    # Filet de sécurité DNS (côté orchestrateur, choix design juin 2026).
    # Scanne toutes les VMs omega du cluster et (ré)enregistre dans pfSense Unbound
    # celles qui manquent ou dont l'IP a dérivé. Rattrape les VMs créées hors
    # omega-lab. Les nœuds ne pouvant pas joindre pfSense, la réconciliation vit ici.
    #
    # Conception en 2 phases pour robustesse :
    #   1. COLLECTE : pour chaque VM omega, lire le NOM (qm config, autoritaire) +
    #      l'IP (ipconfig0 sinon formule). Si le nom est illisible (ssh transitoire),
    #      on SKIP la VM (jamais de nom inventé type omega-<vmid>).
    #   2. APPLICATION : un SEUL appel pfSense applique tous les ajouts/màj puis
    #      write_config + services_unbound_configure UNE fois (pas de tempête de
    #      reload Unbound, pas de dig pendant que le DNS redémarre).
    _need_config || return
    _hdr "══ Réconciliation DNS (zone ${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}) ══"
    if [[ -z "${OMEGA_NET_PFSENSE_WAN_IP:-}" ]]; then
        _err "pfSense non configuré (OMEGA_NET_PFSENSE_WAN_IP vide)"; return 1
    fi
    local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
    local pfip="${OMEGA_NET_PFSENSE_WAN_IP}"
    local pfuser="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    _info "Inventaire des VMs omega du cluster (via ${CONTROLLER_NODE})..."
    local inv
    inv="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 -o BatchMode=yes "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null | python3 -c '
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in rows:
    if v.get("type") != "qemu":
        continue
    if v.get("template"):
        continue
    tags = (v.get("tags", "") or "").replace(";", " ").replace(",", " ").split()
    if "omega" not in tags:
        continue
    print("%s\t%s\t%s" % (v.get("vmid"), v.get("node", ""), v.get("name", "") or ""))
' 2>/dev/null)"
    if [[ -z "$inv" ]]; then
        _warn "Aucune VM omega trouvée dans le cluster"; return 0
    fi
    # ── Phase 1 : collecte (tableau AVANT boucle : les ssh internes mangeraient
    # le stdin d'un while-read et n'itéreraient qu'une VM). ──
    local _rows; mapfile -t _rows <<< "$inv"
    local n_skip=0 vmid pve_name vname node_ip label ip cfg qname _row
    local -a want_labels=() want_ips=()
    for _row in "${_rows[@]}"; do
        IFS=$'\t' read -r vmid pve_name vname <<< "$_row"
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        node_ip="$(_node_ip_for_pve_name "$pve_name" || true)"
        [[ -n "$node_ip" ]] || { _warn "VM $vmid : nœud '$pve_name' introuvable, ignorée"; n_skip=$((n_skip+1)); continue; }
        cfg="$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes "${DEPLOY_USER}@${node_ip}" \
            "qm config ${vmid} 2>/dev/null" 2>/dev/null)"
        qname="$(printf '%s\n' "$cfg" | sed -n 's/^name: //p' | head -1)"
        # Nom autoritaire requis : si illisible (ssh transitoire), on SKIP (jamais inventer).
        if [[ -z "$qname" ]]; then
            _warn "VM $vmid : nom illisible (qm config vide ?), ignorée ce passage"; n_skip=$((n_skip+1)); continue
        fi
        label="$(_dns_label "$qname")"
        [[ -n "$label" ]] || { _warn "VM $vmid : nom '$qname' sans label DNS, ignorée"; n_skip=$((n_skip+1)); continue; }
        ip="$(printf '%s\n' "$cfg" | sed -n 's/^ipconfig0:.*ip=\([0-9.]*\).*/\1/p' | head -1)"
        if [[ -z "$ip" && -n "${OMEGA_NET_VM_IP_PREFIX:-}" ]]; then
            ip="${OMEGA_NET_VM_IP_PREFIX}.$(( ${OMEGA_NET_VM_IP_START:-101} + vmid - ${OMEGA_NET_VM_VMID_BASE:-3000} ))"
        fi
        [[ -n "$ip" ]] || { _warn "VM $vmid ($label) : pas d'IP (DHCP ?), ignorée"; n_skip=$((n_skip+1)); continue; }
        want_labels+=("$label"); want_ips+=("$ip")
    done
    if [[ "${#want_labels[@]}" -eq 0 ]]; then
        _warn "Aucune entrée à réconcilier (toutes ignorées). ${n_skip} skip."; return 0
    fi
    # ── Phase 2 : application atomique côté pfSense (1 write_config + 1 reload). ──
    local pf; pf="$(mktemp)"
    {
        echo "<?php"
        echo "require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');"
        echo "\$domain='${domain}';"
        echo "if (!isset(\$config['unbound']['hosts'])) \$config['unbound']['hosts']=[];"
        echo "\$want=["
        local i
        for i in "${!want_labels[@]}"; do
            echo "  ['${want_labels[$i]}','${want_ips[$i]}'],"
        done
        cat <<'PHPBODY'
];
$hosts =& $config['unbound']['hosts'];
$changed=0;
foreach ($want as $w) {
  list($h,$ip)=$w; $found=false;
  foreach ($hosts as $k=>$e) {
    if (($e['host']??'')===$h && ($e['domain']??'')===$domain) {
      $found=true;
      if (($e['ip']??'')!==$ip) { $hosts[$k]['ip']=$ip; echo "UPD $h -> $ip\n"; $changed++; }
      else echo "OK $h -> $ip\n";
      break;
    }
  }
  if (!$found) { $hosts[]=['host'=>$h,'domain'=>$domain,'ip'=>$ip,'descr'=>'Omega VM '.$h,'aliases'=>'']; echo "ADD $h -> $ip\n"; $changed++; }
}
if ($changed>0) { write_config("DNS reconcile bulk ($changed)"); services_unbound_configure(); }
echo "CHANGED $changed\n";
PHPBODY
    } > "$pf"
    _info "Application de ${#want_labels[@]} entrée(s) sur pfSense (1 reload)..."
    local out
    if out="$(scp "${SSH_OPTS[@]}" -o ConnectTimeout=8 -o BatchMode=yes "$pf" "${pfuser}@${pfip}:/tmp/dns_reconcile.php" 2>/dev/null \
        && ssh "${SSH_OPTS[@]}" -n -o ConnectTimeout=12 -o BatchMode=yes "${pfuser}@${pfip}" \
            "php /tmp/dns_reconcile.php && rm -f /tmp/dns_reconcile.php" 2>/dev/null)"; then
        local n_add n_upd
        n_add="$(grep -c '^ADD ' <<< "$out" || true)"
        n_upd="$(grep -c '^UPD ' <<< "$out" || true)"
        grep -E '^(ADD|UPD) ' <<< "$out" | sed 's/^ADD /  + /; s/^UPD /  ~ /' | while read -r l; do _ok "$l"; done
        _info "Réconciliation : ${n_add} ajoutée(s) · ${n_upd} corrigée(s) · $(( ${#want_labels[@]} - n_add - n_upd )) déjà OK · ${n_skip} ignorée(s)"
    else
        _err "échec application pfSense (${pfuser}@${pfip}) — vérifier SSH"; rm -f "$pf"; return 1
    fi
    rm -f "$pf"
}

do_dns_register() {
    _need_config || return
    local domain="${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}"
    local pfsense_ip="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local pfsense_user="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    local registry="/etc/omega/dns-registry.json"
    _hdr "══ DNS pfSense Unbound — zone ${domain} ══"
    echo -e "  Assigne un nom à une IP (et un port optionnel)."
    echo -e "  Le domaine ${CYAN}${domain}${RESET} est ajouté automatiquement."
    echo -e "  Ex: ${DIM}monapp.${domain} → 10.50.30.110${RESET}"
    echo -e "      ${DIM}api.${domain}   → 10.50.30.110:8080${RESET}"
    echo ""

    local action name ip port proto
    _ask "Action [register/delete/list]"
    read -r action
    action="${action:-list}"

    case "$action" in
        list)
            _info "Entrées DNS pour ${domain} :"
            # Depuis le registre local
            local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
            ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${nodes_arr[0]}" "
cat '${registry}' 2>/dev/null | python3 -c \"
import json,sys
try:
    reg=json.load(sys.stdin)
    for e in reg:
        port_str=(':'+str(e['port'])) if e.get('port') else ''
        proto_str='('+e.get('proto','tcp')+')' if e.get('port') else ''
        print(f\\\"  {e['name']}.${domain}{port_str}  →  {e['ip']}{port_str}  {proto_str}\\\")
    print(f\\\"Total: {len(reg)} entrée(s)\\\")
except: print('  (registre vide ou absent)')
\"" 2>/dev/null || _warn "Nœud non accessible — SSH pfSense :"
            # Depuis pfSense Unbound aussi
            ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" "
php -r \"
require_once('config.inc');
\\\$d='${domain}';
foreach (\\\$config['unbound']['hosts']??[] as \\\$h) {
    if (\\\$h['domain']===\\\$d) echo '  A  '.\\\$h['host'].'.'.\\\$d.' -> '.\\\$h['ip'].PHP_EOL;
}
\\\$opts=base64_decode(\\\$config['unbound']['custom_options']??'');
foreach (explode(PHP_EOL,\\\$opts) as \\\$line) {
    if (str_contains(\\\$line,'SRV') && str_contains(\\\$line,\\\$d)) echo '  SRV '.\\\$line.PHP_EOL;
}
\"" 2>/dev/null || true ;;

        register)
            _ask "Nom du service (ex: monapp, api, database)"
            read -r name
            [[ -n "$name" ]] || { _err "Nom requis"; return 1; }

            _ask "IP (ex: 10.50.30.110)"
            read -r ip

            _ask "Port (laisser vide si aucun, ex: 8080)"
            read -r port
            port="${port//[^0-9]/}"

            proto="tcp"
            if [[ -n "$port" ]]; then
                _ask "Protocole [tcp/udp] (défaut: tcp)"
                read -r proto_input
                [[ "$proto_input" == "udp" ]] && proto="udp" || proto="tcp"
            fi
            [[ -n "$name" && -n "$ip" ]] || { _err "Nom et IP requis"; return 1; }

            # Préparer le script PHP
            local pf_script; pf_script=$(mktemp)
            local srv_line=""
            if [[ -n "$port" ]]; then
                # SRV: _nom._proto.domaine. SRV priorité poids port cible.
                srv_line="local-data: \\\"_${name}._${proto}.${domain}. SRV 0 0 ${port} ${name}.${domain}.\\\""
            fi

            cat > "$pf_script" << PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
if (!isset(\$config['unbound']['hosts'])) \$config['unbound']['hosts'] = [];
\$domain='${domain}'; \$host='${name}'; \$ip='${ip}';

// Enregistrement A
\$exists=false;
foreach (\$config['unbound']['hosts'] as \$h) {
    if (\$h['host']===\$host && \$h['domain']===\$domain) { \$exists=true; break; }
}
if (!\$exists) {
    \$config['unbound']['hosts'][] = ['host'=>\$host,'domain'=>\$domain,'ip'=>\$ip,
        'descr'=>'Omega service '.(\$port??\$host),'aliases'=>''];
    echo "A: \$host.\$domain -> \$ip\n";
}

// Enregistrement SRV si port fourni
// NB: pfSense stocke custom_options encodé base64 (unbound.inc fait base64_decode).
\$srv='${srv_line}';
if (\$srv) {
    \$opts = base64_decode(\$config['unbound']['custom_options'] ?? '');
    if (strpos(\$opts, \$srv) === false) {
        \$merged = (trim(\$opts) === '') ? \$srv : trim(\$opts)."\n".\$srv;
        \$config['unbound']['custom_options'] = base64_encode(\$merged);
        echo "SRV: _${name}._${proto}.${domain} -> \$ip:${port}\n";
    }
}

write_config("DNS register \$host.\$domain");
services_unbound_configure();
echo "OK\n";
PHPEOF
            scp "${SSH_OPTS[@]/#-i/-i}" "$pf_script" "${pfsense_user}@${pfsense_ip}:/tmp/dns_reg.php" 2>/dev/null && \
            ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" "php /tmp/dns_reg.php && rm /tmp/dns_reg.php" 2>/dev/null \
                && _ok "${name}.${domain}${port:+:$port} → ${ip}${port:+:$port} enregistré" \
                || _err "Échec pfSense — SSH configuré ? Lancer [F] d'abord."
            rm -f "$pf_script"

            # /etc/hosts sur les nœuds (IP uniquement, le port est dans le SRV)
            local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
            for node in "${nodes_arr[@]}"; do
                ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
                    mkdir -p /etc/omega
                    grep -q '\"${name}\"' '${registry}' 2>/dev/null && true || {
                        python3 -c \"
import json,os
f='${registry}'
reg=json.load(open(f)) if os.path.exists(f) else []
reg=[e for e in reg if e.get('name')!='${name}']
reg.append({'name':'${name}','ip':'${ip}','port':${port:-null},'proto':'${proto}'})
json.dump(reg,open(f,'w'),indent=2)
print('registre mis à jour')
\"
                    }
                    grep -q '${ip}.*${name}' /etc/hosts || echo '${ip}  ${name}.${domain}  ${name}' >> /etc/hosts
                " 2>/dev/null || true
            done ;;

        delete)
            _ask "Nom à supprimer (sans le domaine)"
            read -r name
            [[ -n "$name" ]] || { _err "Nom requis"; return 1; }

            local pf_del; pf_del=$(mktemp)
            cat > "$pf_del" << PHPEOF
<?php
require_once('config.inc'); require_once('unbound.inc'); require_once('util.inc');
\$domain='${domain}'; \$host='${name}';
// Supprimer A record
\$config['unbound']['hosts'] = array_values(array_filter(
    \$config['unbound']['hosts']??[],
    fn(\$h) => !(\$h['host']===\$host && \$h['domain']===\$domain)
));
// Supprimer SRV dans custom_options (stocké base64 par pfSense)
\$opts = base64_decode(\$config['unbound']['custom_options'] ?? '');
\$lines = array_filter(explode("\n", \$opts), fn(\$l) => strpos(\$l, "_\$host.") === false);
\$config['unbound']['custom_options'] = base64_encode(implode("\n", \$lines));
write_config("DNS delete \$host.\$domain");
services_unbound_configure();
echo "Supprimé: \$host.\$domain\n";
PHPEOF
            scp "${SSH_OPTS[@]/#-i/-i}" "$pf_del" "${pfsense_user}@${pfsense_ip}:/tmp/dns_del.php" 2>/dev/null && \
            ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" "php /tmp/dns_del.php && rm /tmp/dns_del.php" 2>/dev/null \
                && _ok "${name}.${domain} supprimé" || _warn "pfSense non accessible"
            rm -f "$pf_del"

            # Retirer des /etc/hosts et du registre sur les nœuds
            local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
            for node in "${nodes_arr[@]}"; do
                ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
                    sed -i '/${name}\\.${domain}/d; / ${name}$/d' /etc/hosts 2>/dev/null || true
                    python3 -c \"
import json,os
f='${registry}'
if os.path.exists(f):
    reg=[e for e in json.load(open(f)) if e.get('name')!='${name}']
    json.dump(reg,open(f,'w'),indent=2)
\" 2>/dev/null || true
                " 2>/dev/null || true
            done ;;

        *) _warn "Action invalide : '$action' — utiliser register / delete / list" ;;
    esac
}

do_clean_infra_vms() {
    _need_config || return
    _hdr "══ Nettoyage VMs infra réseau existantes ══"

    # VMIDs infra à supprimer (depuis cluster.conf + valeurs par défaut)
    local infra_vmids=(
        "${OMEGA_NET_PFSENSE_VMID:-2290}"
        "${OMEGA_NET_DNS_VMID:-2291}"
        "${OMEGA_NET_ROUTER_VMID:-}"
        "${OMEGA_NET_GW_VMID:-}"
        "${OMEGA_NET_DHCP_VMID:-}"
    )
    # Filtrer les vides
    local to_check=()
    for v in "${infra_vmids[@]}"; do
        [[ -n "$v" ]] && to_check+=("$v")
    done

    echo -e "  Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo -e "  VMIDs à vérifier/supprimer : ${CYAN}${to_check[*]}${RESET}"
    echo -e "  ${RED}ATTENTION${RESET} : cette action arrête et supprime ces VMs définitivement."
    echo ""

    # Découvrir les VMs infra qui existent réellement dans le cluster
    local existing=()
    local existing_info
    existing_info="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER_NODE}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null \
        | python3 -c "
import json,sys
vms={str(v['vmid']):(v.get('node','?'),v.get('name','?')) for v in json.load(sys.stdin)}
for vmid in sys.argv[1:]:
    if vmid in vms:
        print(vmid, vms[vmid][0], vms[vmid][1])
" "${to_check[@]}" 2>/dev/null || true)"

    if [[ -z "$existing_info" ]]; then
        _info "Aucune VM infra trouvée dans le cluster — rien à supprimer."
        return 0
    fi

    echo -e "  VMs infra présentes dans le cluster :"
    while IFS=' ' read -r vmid node name; do
        echo -e "    ${RED}✗${RESET}  VMID ${CYAN}${vmid}${RESET}  nœud=${CYAN}${node}${RESET}  nom=${CYAN}${name}${RESET}"
        existing+=("${vmid}:${node}")
    done <<< "$existing_info"
    echo ""

    if ! $AUTO; then
        read -rp "  Supprimer ces VMs ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi

    for entry in "${existing[@]}"; do
        local vmid="${entry%%:*}"
        local node="${entry##*:}"
        local node_ip
        node_ip="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER_NODE}" \
            "getent hosts '${node}' | awk '{print \$1; exit}'" 2>/dev/null || echo "$node")"
        echo -n "  Suppression VM ${vmid} sur ${node}… "
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node_ip}" bash <<SSHEOF 2>/dev/null
qm stop ${vmid} --skiplock 2>/dev/null || true
sleep 2
# Détacher le disque cloudinit avant destroy pour éviter les erreurs Ceph
qm set ${vmid} --delete scsi1 2>/dev/null || true
qm destroy ${vmid} --purge --destroy-unreferenced-disks 1 2>/dev/null \
    || qm destroy ${vmid} --purge 2>/dev/null \
    || qm destroy ${vmid} 2>/dev/null \
    || echo "WARN: destroy échoué pour VMID ${vmid}"
SSHEOF
        echo -e "${GREEN}OK${RESET}"
    done

    _ok "VMs infra supprimées — prêt pour [N] Créer VMs infra"
}

do_setup_network() {
    _need_config || return
    _hdr "══ Setup réseau privé VMs (vmbr1) ══"
    echo -e "  Crée ${CYAN}vmbr1${RESET} (bridge VLAN-aware, sans port physique) sur chaque nœud Proxmox."
    echo -e "  ${BOLD}Ne touche pas${RESET} à vmbr0 ni au réseau de gestion Proxmox."
    echo -e "  Nœuds cibles : ${CYAN}${OMEGA_NODES}${RESET}"
    echo ""

    local dry_run=false
    if ! $AUTO; then
        read -rp "  Mode dry-run (voir les commandes sans appliquer) ? [o/N] " dr
        [[ "${dr,,}" =~ ^o ]] && dry_run=true
        read -rp "  Confirmer le setup réseau ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi

    local args=(--nodes "$OMEGA_NODES" --user "$DEPLOY_USER")
    [[ -f "${SSH_KEY:-}" ]] && args+=(--ssh-key "$SSH_KEY")
    $dry_run && args+=(--dry-run)
    bash "${SCRIPT_DIR}/setup-network.sh" "${args[@]}"
    _ok "Setup réseau terminé — vmbr1 présent sur tous les nœuds"

    # Initialiser l'isolation sur tous les nœuds (backend OVS ou iptables auto-détecté)
    _info "Initialisation isolation sur tous les nœuds (OVS/iptables auto)..."
    local subnet="${OMEGA_NET_VM_IP_PREFIX:-10.50.30}.0/${OMEGA_NET_VM_NETMASK:-24}"
    local iso_gw="${OMEGA_NET_VM_GATEWAY:-10.50.30.1}"
    local iso_bridge="${OMEGA_NET_VM_BRIDGE:-${OMEGA_VM_BRIDGE:-vmbr1}}"
    _deploy_isolation_script
    local nodes_arr; IFS=',' read -ra nodes_arr <<< "$OMEGA_NODES"
    for node in "${nodes_arr[@]}"; do
        echo -n "  ${node} isolation : "
        ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
            script=/opt/omega-remote-paging/scripts/vm-isolation.sh
            [[ -x \"\$script\" ]] || script=/opt/vm-isolation.sh
            [[ -x \"\$script\" ]] || exit 1
            bash \"\$script\" --action init --subnet '${subnet}' --gateway '${iso_gw}' --bridge '${iso_bridge}' 2>/dev/null
            # iptables-persistent seulement utile pour le backend Linux bridge
            command -v iptables-save >/dev/null && \
            (DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent -qq 2>/dev/null || true)
            bash \"\$script\" --action save --bridge '${iso_bridge}' 2>/dev/null
        " 2>/dev/null && echo -e "${GREEN}OK${RESET}" || echo -e "${RED}ECHEC${RESET}"
    done

    # Pfizer : ajouter règle pfSense pour accès 192.168.123.x → VMs omega
    _info "Règle pfSense accès management → VMs..."
    _add_pfsense_mgmt_rule 2>/dev/null || _warn "pfSense non configuré — accès management via [F] + [N]"

    echo ""
    _info "Étape suivante : [N] Créer les VMs infra (pfSense)"
}

# Ajoute la règle pfSense WAN → OMEGA pour le réseau de management
_add_pfsense_mgmt_rule() {
    local pfsense_ip="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
    local pfsense_user="${OMEGA_NET_PFSENSE_SSH_USER:-admin}"
    local pf_script; pf_script=$(mktemp)
    cat > "$pf_script" << 'PHPEOF'
<?php
require_once('config.inc'); require_once('filter.inc'); require_once('util.inc');
$descr = 'omega-mgmt-to-vms';
foreach ($config['filter']['rule'] ?? [] as $r) {
    if (($r['descr'] ?? '') === $descr) { echo "exists\n"; exit(0); }
}
if (!isset($config['filter']['rule'])) $config['filter']['rule'] = [];
array_unshift($config['filter']['rule'], [
    'type'=>'pass','interface'=>'wan','ipprotocol'=>'inet','protocol'=>'any',
    'source'=>['network'=>'192.168.123.0/24'],
    'destination'=>['network'=>'10.50.30.0/24'],
    'descr'=>$descr,'tracker'=>(string)time(),
]);
write_config("Allow mgmt to omega VMs"); filter_configure();
echo "added\n";
PHPEOF
    scp "${SSH_OPTS[@]/#-i/-i}" "$pf_script" "${pfsense_user}@${pfsense_ip}:/tmp/pf_mgmt.php" 2>/dev/null && \
    ssh "${SSH_OPTS[@]}" "${pfsense_user}@${pfsense_ip}" "php /tmp/pf_mgmt.php && rm /tmp/pf_mgmt.php" 2>/dev/null
    rm -f "$pf_script"
}

do_create_infra_vms() {
    _need_config || return
    _hdr "══ Création VMs infra réseau ══"
    echo -e "  ${BOLD}pfSense${RESET} VMID ${CYAN}${OMEGA_NET_PFSENSE_VMID:-2290}${RESET} — routeur/firewall (WAN=vmbr0, LAN=vmbr1)"
    echo -e "  ${BOLD}DNS${RESET} : pfSense Unbound — zone ${CYAN}${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal}${RESET} (pas de VM DNS séparée)"
    echo -e "  Contrôleur : ${CYAN}${CONTROLLER_NODE}${RESET}"
    echo ""

    local do_pf=false
    if ! $AUTO; then
        read -rp "  Créer VM pfSense ${OMEGA_NET_PFSENSE_VMID:-2290} ? [o/N] " pf
        [[ "${pf,,}" =~ ^o ]] && do_pf=true
    else
        do_pf=true
    fi
    $do_pf || { _info "Rien à créer."; return; }

    local args=(--pfsense --controller "$CONTROLLER_NODE" --user "$DEPLOY_USER")
    [[ -f "${SSH_KEY:-}" ]] && args+=(--ssh-key "$SSH_KEY")

    bash "${SCRIPT_DIR}/create-infra-vms.sh" "${args[@]}"
    _ok "VM pfSense créée"
    echo ""
    _info "Configurer pfSense : VLANs, interfaces, règles firewall."
    _info "Voir docs/architecture-reseau.md pour les étapes détaillées."
    _info "DNS omega.local → pfSense Unbound : Services → DNS Resolver → Host Overrides"
    _info "Une fois pfSense configuré, lancer [H] pour synchroniser /etc/hosts + routes."
}

do_install_full() {
    _need_config || return
    _hdr "══ Installation complète ══"
    echo -e "  Étapes : ${CYAN}désinstallation → build → déploiement → watchdog QGA${RESET}"
    echo -e "  Nœuds  : ${CYAN}${OMEGA_NODES}${RESET} (${#NODES_ARR[@]} nœud(s))"
    echo ""
    if ! $AUTO; then
        read -rp "  Lancer l'installation complète ? [oui/N] " confirm
        [[ "$confirm" =~ ^[Oo]([Uu][Ii])?$ ]] || { _info "Annulé."; return; }
    fi
    do_uninstall
    do_build
    do_deploy
    do_install_qga_watchdog
}

# ── Sections de tests ─────────────────────────────────────────────────────────
run_section_1() {
    _need_config || return
    _hdr "══ Section 1 — Tests isolés (smoke, réplication, failover, éviction) ══"
    _sync
    _run_local    "00" "Tests unitaires Rust"  "00-unit-tests.sh"
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
    _run_isolated "18" "Recall LIFO"         "18-recall-lifo.sh"
    _run_isolated "20" "Prefetch stride"     "20-prefetch-stride.sh"
    _run_isolated "21" "TLS TOFU"            "21-tls-tofu.sh"
    _run_local    "23" "Disk I/O scheduler"  "23-disk-io-scheduler.sh"
}

run_section_3() {
    _need_config || return
    _hdr "══ Section 3 — Tests cluster (vCPU, migration, balloon, compaction) ══"
    _sync
    _run_cluster "05" "vCPU élastique"            "05-vcpu-elastic.sh"         "${TEST_VMIDS_ARR[0]}"
    _run_cluster "08" "Migration RAM"             "08-migration-ram.sh"        "${TEST_VMIDS_ARR[0]}"
    _run_cluster "09" "Orphan cleaner"            "09-orphan-cleaner.sh"
    _run_cluster "19" "Compaction cluster"        "19-compaction.sh"           "${TEST_VMIDS_ARR[0]}"
    _run_cluster "22" "Balloon thin-provisioning" "22-balloon-thinprov.sh"     "${TEST_VMIDS_ARR[0]}"
    _run_cluster "23C" "Disk I/O scheduler cluster" "23-disk-io-scheduler.sh"  "${TEST_VMIDS_ARR[0]}"
}

run_section_4() {
    _need_config || return
    _hdr "══ Section 4 — Tests GPU ══"
    if ! $DO_GPU; then
        _warn "GPU non activé — relancez avec --gpu pour activer ces tests"
        for t in 06 07 32 34 35 36; do RESULTS["$t"]="SKIP"; ((TOTAL_SKIP++)) || true; done
        return
    fi
    _sync
    _run_cluster "06" "GPU placement"  "06-gpu-placement.sh"  "${TEST_VMIDS_ARR[0]}"
    if [[ -n "${TEST_VMIDS_ARR[1]:-}" ]]; then
        _run_cluster "07" "GPU scheduler"  "07-gpu-scheduler.sh"  "${TEST_VMIDS_ARR[0]}" "${TEST_VMIDS_ARR[1]}"
    else
        _warn "Test 07 ignoré — OMEGA_TEST_VMIDS doit contenir au moins 2 VMs"
        RESULTS["07"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    _run_cluster "32" "GPU proxy applicatif" "32-gpu-proxy.sh" "${TEST_VMIDS_ARR[0]}"
    _run_cluster "34" "GPU placement global" "34-gpu-placement-global.sh" "${TEST_VMIDS_ARR[0]}"
    _run_cluster "35" "GPU fallback réseau"  "35-gpu-network-fallback.sh" "${TEST_VMIDS_ARR[0]}"
    _run_cluster "36" "GPU concurrence CUDA" "36-gpu-concurrency-cuda.sh" "${TEST_VMIDS_ARR[0]}"
}

run_section_5() {
    _need_config || return
    _hdr "══ Section 5 — Tests mixtes (stress, pression cluster) ══"
    _sync
    local nc="${#NODES_ARR[@]}"
    _run_cluster "M1" "RAM + CPU simultanés"        "11-mixed-ram-cpu.sh"               "${TEST_VMIDS_ARR[0]}"
    _run_cluster "M2" "CPU+RAM → migration"         "12-mixed-cpu-ram-migration.sh"     "${TEST_VMIDS_ARR[0]}"
    if $DO_GPU; then
        _run_cluster "M3" "GPU+CPU multi"           "13-mixed-gpu-cpu.sh"               "${TEST_VMIDS_ARR[0]}"
    else
        RESULTS["M3"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    _run_cluster "M4" "Stress cluster complet"      "14-mixed-cluster-pressure.sh"      "$nc" 60
    _run_cluster "M5" "Live migration pression"     "15-mixed-live-migration-pressure.sh" "${TEST_VMIDS_ARR[0]}"
    _run_cluster "M6" "Rafale démarrages"           "16-mixed-burst-starts.sh"          6
    _run_cluster "M7" "Drain nœud"                  "17-mixed-drain-node.sh"            "${CONTROLLER_NODE}"
    if $DO_GPU; then
        _run_cluster "M8" "Placement GPU intelligent" "34-gpu-placement-global.sh"       "${TEST_VMIDS_ARR[0]}"
        _run_cluster "M9" "Fallback GPU réseau"       "35-gpu-network-fallback.sh"       "${TEST_VMIDS_ARR[0]}"
    else
        for t in M8 M9; do RESULTS["$t"]="SKIP"; ((TOTAL_SKIP++)) || true; done
    fi
}

run_section_6() {
    _need_config || return
    _hdr "══ Section 6 — Production physique (install, réseau, Ceph/GPU réel, panne, soak) ══"
    _sync
    _run_cluster "30" "Conformité VMs Omega"      "30-vm-conformity.sh" "${OMEGA_TEST_VMIDS}"
    _run_cluster "24" "Installation doctor"       "24-install-doctor.sh"
    _run_cluster "25" "Réseau VM invitée"         "25-vm-network.sh"       "${TEST_VMIDS_ARR[0]}"
    if $DO_CEPH; then
        _run_cluster "26" "Ceph réel"             "26-ceph-real.sh"
    else
        _warn "Test 26 ignoré — relancer avec --ceph"
        RESULTS["26"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    if $DO_GPU; then
        _run_cluster "27" "GPU réel / rendu"      "27-gpu-real-render.sh"  "${TEST_VMIDS_ARR[0]}"
        _run_cluster "32" "GPU proxy applicatif"  "32-gpu-proxy.sh"        "${TEST_VMIDS_ARR[0]}"
        _run_cluster "34" "GPU placement global"  "34-gpu-placement-global.sh" "${TEST_VMIDS_ARR[0]}"
        _run_cluster "35" "GPU fallback réseau"   "35-gpu-network-fallback.sh" "${TEST_VMIDS_ARR[0]}"
        _run_cluster "36" "GPU concurrence CUDA"  "36-gpu-concurrency-cuda.sh" "${TEST_VMIDS_ARR[0]}"
    else
        _warn "Tests 27/32/34/35/36 ignorés — relancer avec --gpu"
        for t in 27 32 34 35 36; do RESULTS["$t"]="SKIP"; ((TOTAL_SKIP++)) || true; done
    fi
    if $DO_DESTRUCTIVE; then
        _run_cluster "28" "Partition réseau"      "28-network-partition.sh" "${NODES_ARR[1]:-}"
    else
        _warn "Test 28 ignoré — relancer avec --destructive"
        RESULTS["28"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    if $DO_LONG; then
        _run_cluster "29" "Soak long physique"    "29-long-run-soak.sh"    "${TEST_VMIDS_ARR[0]}" "${OMEGA_SOAK_SECS:-1800}"
    else
        _warn "Test 29 ignoré — relancer avec --long"
        RESULTS["29"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    if $DO_SCALE; then
        _run_cluster "31" "Scalabilité VMs physiques" "31-scale-vms.sh" \
            "${OMEGA_SCALE_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}" \
            "${OMEGA_SCALE_TARGET:-500}" \
            "${OMEGA_SCALE_BATCH_SIZE:-20}" \
            "${OMEGA_SCALE_SOAK_SECS:-1800}"
    else
        _warn "Test 31 ignoré — relancer avec --scale"
        RESULTS["31"]="SKIP"; ((TOTAL_SKIP++)) || true
    fi
    _run_cluster "33" "Métriques production" "33-production-metrics.sh"
}

run_section_7() {
    _need_config || return
    _hdr "══ Section 7 — Puissance flotte Omega (50 VMs + chaos 75 VMs) ══"
    if ! $DO_FLEET; then
        _warn "Fleet non activé — relancez avec --fleet ou appuyez sur [f] pour activer"
        RESULTS["37"]="SKIP"; ((TOTAL_SKIP++)) || true
        return
    fi
    _sync
    _run_cluster "37" "Puissance Omega flotte" "37-fleet-omega-power.sh" \
        "${OMEGA_FLEET_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}" \
        "${OMEGA_FLEET_VM_COUNT:-50}" \
        "${OMEGA_FLEET_CHAOS_VM_COUNT:-75}" \
        "${OMEGA_FLEET_DURATION_SECS:-900}"
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
    run_section_5; _pause_section "5 — Mixtes"          || return
    run_section_6; _pause_section "6 — Production"      || return
    run_section_7
    show_results
}

run_production_full() {
    _need_config || return
    if ! $AUTO; then
        echo ""
        _warn "Validation production stricte: GPU, Ceph, longs, scale et destructifs seront activés."
        _warn "Aucun SKIP n'est accepté. Les tests destructifs peuvent perturber temporairement réseau/services."
        read -rp "  Taper OUI pour lancer : " confirm
        [[ "$confirm" == "OUI" ]] || { _warn "Validation production annulée"; return 1; }
    fi

    reset_results
    DO_GPU=true
    DO_CEPH=true
    DO_LONG=true
    DO_SCALE=true
    DO_FLEET=true
    DO_DESTRUCTIVE=true
    export OMEGA_GPU_PROXY_REQUIRE_CUDA=1
    export OMEGA_GPU_PROXY_REQUIRE_PARALLEL=1
    export OMEGA_STRICT_FULL=1
    export OMEGA_REQUIRE_NO_SKIP=1

    local prev_auto="$AUTO"
    AUTO=true
    _hdr "Mode production strict — toutes les sections, aucun skip"
    run_all
    AUTO="$prev_auto"

    if [[ "$TOTAL_SKIP" -ne 0 ]]; then
        _err "Validation production refusée: $TOTAL_SKIP test(s) ignoré(s)."
        return 1
    fi
    if [[ "$TOTAL_FAIL" -ne 0 ]]; then
        _err "Validation production refusée: $TOTAL_FAIL test(s) en échec."
        return 1
    fi
    _ok "Validation production complète OK: aucun échec, aucun skip."
}

# ── Test individuel ───────────────────────────────────────────────────────────
# _dispatch_one : lance UN test par ID, sans (re)synchroniser — appelé par run_one
# (qui sync une fois) ET par run_category (qui sync une fois pour toute la catégorie).
_dispatch_one() {
    case "${1^^}" in
        00) _run_local    "00" "Tests unitaires Rust"       "00-unit-tests.sh" ;;
        01) _run_isolated "01" "Smoke test"                 "01-smoke-test.sh" ;;
        02) _run_isolated "02" "Réplication 2 stores"       "02-replication.sh" ;;
        03) _run_isolated "03" "Failover store"             "03-failover.sh" ;;
        04) _run_isolated "04" "Éviction daemon"            "04-eviction-daemon.sh" 20 ;;
        10) _run_isolated "10" "Multi-VM 3 agents"          "10-multi-vm.sh" ;;
        18) _run_isolated "18" "Recall LIFO"                "18-recall-lifo.sh" ;;
        20) _run_isolated "20" "Prefetch stride"            "20-prefetch-stride.sh" ;;
        21) _run_isolated "21" "TLS TOFU"                   "21-tls-tofu.sh" ;;
        23) _run_local    "23" "Disk I/O scheduler"          "23-disk-io-scheduler.sh" ;;
        30) _run_cluster  "30" "Conformité VMs Omega"         "30-vm-conformity.sh"      "${OMEGA_TEST_VMIDS}" ;;
        05) _run_cluster  "05" "vCPU élastique"             "05-vcpu-elastic.sh"          "${TEST_VMIDS_ARR[0]}" ;;
        06) _run_cluster  "06" "GPU placement"              "06-gpu-placement.sh"         "${TEST_VMIDS_ARR[0]}" ;;
        07) if [[ -n "${TEST_VMIDS_ARR[1]:-}" ]]; then
                _run_cluster  "07" "GPU scheduler"          "07-gpu-scheduler.sh"         "${TEST_VMIDS_ARR[0]}" "${TEST_VMIDS_ARR[1]}"
            else
                _warn "Test 07 ignoré — OMEGA_TEST_VMIDS doit contenir au moins 2 VMs"
                RESULTS["07"]="SKIP"; ((TOTAL_SKIP++)) || true
            fi ;;
        08) _run_cluster  "08" "Migration RAM"              "08-migration-ram.sh"         "${TEST_VMIDS_ARR[0]}" ;;
        09) _run_cluster  "09" "Orphan cleaner"             "09-orphan-cleaner.sh" ;;
        19) _run_cluster  "19" "Compaction cluster"         "19-compaction.sh"            "${TEST_VMIDS_ARR[0]}" ;;
        22) _run_cluster  "22" "Balloon thin-provisioning"  "22-balloon-thinprov.sh"      "${TEST_VMIDS_ARR[0]}" ;;
        24) _run_cluster  "24" "Installation doctor"        "24-install-doctor.sh" ;;
        25) _run_cluster  "25" "Réseau VM invitée"          "25-vm-network.sh"            "${TEST_VMIDS_ARR[0]}" ;;
        26) _run_cluster  "26" "Ceph réel"                  "26-ceph-real.sh" ;;
        27) _run_cluster  "27" "GPU réel / rendu"           "27-gpu-real-render.sh"       "${TEST_VMIDS_ARR[0]}" ;;
        32) _run_cluster  "32" "GPU proxy applicatif"        "32-gpu-proxy.sh"             "${TEST_VMIDS_ARR[0]}" ;;
        33) _run_cluster  "33" "Métriques production"        "33-production-metrics.sh" ;;
        34) _run_cluster  "34" "GPU placement global"        "34-gpu-placement-global.sh"  "${TEST_VMIDS_ARR[0]}" ;;
        35) _run_cluster  "35" "GPU fallback réseau"         "35-gpu-network-fallback.sh"  "${TEST_VMIDS_ARR[0]}" ;;
        36) _run_cluster  "36" "GPU concurrence CUDA"        "36-gpu-concurrency-cuda.sh"  "${TEST_VMIDS_ARR[0]}" ;;
        37) _run_cluster  "37" "Puissance Omega flotte"      "37-fleet-omega-power.sh"     "${OMEGA_FLEET_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}" "${OMEGA_FLEET_VM_COUNT:-50}" "${OMEGA_FLEET_CHAOS_VM_COUNT:-75}" "${OMEGA_FLEET_DURATION_SECS:-900}" ;;
        28) _run_cluster  "28" "Partition réseau"           "28-network-partition.sh"     "${NODES_ARR[1]:-}" ;;
        29) _run_cluster  "29" "Soak long physique"         "29-long-run-soak.sh"         "${TEST_VMIDS_ARR[0]}" "${OMEGA_SOAK_SECS:-1800}" ;;
        31) _run_cluster  "31" "Scalabilité VMs physiques"   "31-scale-vms.sh"            "${OMEGA_SCALE_VMIDS:-${OMEGA_PROVISION_VMIDS:-${OMEGA_TEST_VMIDS}}}" "${OMEGA_SCALE_TARGET:-500}" "${OMEGA_SCALE_BATCH_SIZE:-20}" "${OMEGA_SCALE_SOAK_SECS:-1800}" ;;
        M1) _run_cluster  "M1" "RAM + CPU simultanés"       "11-mixed-ram-cpu.sh"         "${TEST_VMIDS_ARR[0]}" ;;
        M2) _run_cluster  "M2" "CPU+RAM → migration"        "12-mixed-cpu-ram-migration.sh" "${TEST_VMIDS_ARR[0]}" ;;
        M3) _run_cluster  "M3" "GPU+CPU multi"              "13-mixed-gpu-cpu.sh"         "${TEST_VMIDS_ARR[0]}" ;;
        M4) _run_cluster  "M4" "Stress cluster"             "14-mixed-cluster-pressure.sh" "${#NODES_ARR[@]}" 60 ;;
        M5) _run_cluster  "M5" "Live migration pression"    "15-mixed-live-migration-pressure.sh" "${TEST_VMIDS_ARR[0]}" ;;
        M6) _run_cluster  "M6" "Rafale démarrages"          "16-mixed-burst-starts.sh"        6 ;;
        M7) _run_cluster  "M7" "Drain nœud"                 "17-mixed-drain-node.sh"          "${CONTROLLER_NODE}" ;;
        M8) _run_cluster  "M8" "Placement GPU intelligent"  "34-gpu-placement-global.sh"      "${TEST_VMIDS_ARR[0]}" ;;
        M9) _run_cluster  "M9" "Fallback GPU réseau"        "35-gpu-network-fallback.sh"      "${TEST_VMIDS_ARR[0]}" ;;
        *)  _warn "ID de test inconnu : $1" ;;
    esac
}

run_one() {
    _need_config || return
    _sync
    _dispatch_one "$1"
}

# ── Tests classés par catégorie de ressource (RAM / CPU / DISK / GPU / …) ──────
# Regroupe les tests EXISTANTS par capacité Omega testée, pour valider un domaine
# à la fois. Un même test peut appartenir à plusieurs catégories (ex. la migration
# RAM valide à la fois le paging et la migration). Les IDs sont ceux de _dispatch_one.
declare -A CATEGORY_TESTS=(
    [UNIT]="00"
    [CPU]="05"
    [RAM]="02 04 08 18 19 20 22"
    [DISK]="23 26"
    [GPU]="06 07 27 32 34 35 36"
    [NETWORK]="21 25 28"
    [MIGRATION]="03 M2 M5 M7"
    [MIXED]="M1 M3 M4 M6"
    [OPS]="01 09 10 24 30 33 31"
)
CATEGORY_ORDER=(UNIT CPU RAM DISK GPU NETWORK MIGRATION MIXED OPS)

_category_label() {
    case "$1" in
        UNIT)      echo "Tests unitaires Rust/Python (aucune VM requise)";;
        CPU)       echo "CPU — vCPU élastique (hotplug/downscale sous charge)";;
        RAM)       echo "RAM — paging distant, réplication, éviction, recall, compaction, prefetch, balloon, migration mémoire";;
        DISK)      echo "DISK — scheduler I/O local (cgroups v2/PSI), Ceph réel";;
        GPU)       echo "GPU — proxy jobs CUDA, placement global, fallback réseau, concurrence, rendu réel";;
        NETWORK)   echo "RÉSEAU — TLS TOFU, réseau VM invitée, partition réseau";;
        MIGRATION) echo "MIGRATION — failover store, CPU+RAM→migration, live-migration sous pression, drain de nœud";;
        MIXED)     echo "MIXTE — pression combinée RAM+CPU+GPU (rafales, stress cluster)";;
        OPS)       echo "OPS — smoke, orphelins, multi-VM, install-doctor, conformité, métriques, scale";;
        *)         echo "$1";;
    esac
}

# Affiche la classification (menu / --list-categories)
list_categories() {
    _hdr "Tests classés par catégorie de ressource"
    echo ""
    local c
    for c in "${CATEGORY_ORDER[@]}"; do
        printf "  ${BOLD}%-10s${RESET} %s\n" "$c" "$(_category_label "$c")"
        printf "  ${DIM}%-10s → tests : %s${RESET}\n\n" "" "${CATEGORY_TESTS[$c]}"
    done
    echo -e "  Lancer une catégorie : ${CYAN}omega-lab.sh --category RAM${RESET}"
    echo -e "  Plusieurs            : ${CYAN}omega-lab.sh --category \"CPU GPU\"${RESET}"
    echo -e "  Toutes (dans l'ordre): ${CYAN}omega-lab.sh --category all${RESET}"
}

# Lance tous les tests d'une ou plusieurs catégories, puis affiche le résumé.
run_category() {
    _need_config || return
    _sync
    local cats=("$@") cat ids id
    if [[ "${#cats[@]}" -eq 1 && ( "${cats[0],,}" == "all" ) ]]; then
        cats=("${CATEGORY_ORDER[@]}")
    fi
    reset_results
    for cat in "${cats[@]}"; do
        cat="${cat^^}"
        ids="${CATEGORY_TESTS[$cat]:-}"
        if [[ -z "$ids" ]]; then
            _warn "Catégorie inconnue : $cat (disponibles : ${CATEGORY_ORDER[*]})"
            continue
        fi
        _hdr "══ Catégorie ${cat} — $(_category_label "$cat") ══"
        for id in $ids; do
            _dispatch_one "$id"
        done
    done
    show_results
}

# ── GPU LLM : Ollama sur chaque nœud GPU + gateway unifiée (1 commande) ────────
# Déploie/assure un serveur Ollama-GPU (Docker --gpus all) sur chaque nœud doté
# d'un GPU, puis une gateway LiteLLM OpenAI-compatible qui route par modèle
# (gros modèles → grosses cartes) avec load-balancing + fallback santé.
# Met à jour cluster.env (VRAM réelle, primaire, URL gateway). Idempotent.
do_gpu_llm() {
    _need_config || return
    _hdr "GPU LLM — Ollama par nœud GPU + gateway unifiée"

    local gateway_node="${OMEGA_LLM_GATEWAY_NODE:-${CONTROLLER_NODE}}"
    local gateway_port="${OMEGA_LLM_GATEWAY_PORT:-4000}"

    # 1. Résoudre les nœuds GPU (OMEGA_GPU_NODES sinon auto-détection nvidia-smi)
    local gpu_nodes=() n
    if [[ -n "${OMEGA_GPU_NODES:-}" ]]; then
        IFS=',' read -r -a gpu_nodes <<< "$OMEGA_GPU_NODES"
        _info "Nœuds GPU (cluster.conf) : ${OMEGA_GPU_NODES}"
    else
        _info "Détection des nœuds GPU (nvidia-smi)…"
        for n in "${NODES_ARR[@]}"; do
            if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes "${DEPLOY_USER}@${n}" \
                 "nvidia-smi -L >/dev/null 2>&1"; then
                gpu_nodes+=("$n"); _ok "GPU détecté sur ${n}"
            fi
        done
    fi
    [[ ${#gpu_nodes[@]} -gt 0 ]] || { _err "Aucun nœud GPU détecté (seuls les nœuds avec carte NVIDIA peuvent servir Ollama)"; return 1; }

    # 2. Assurer un serveur Ollama-GPU sur chaque nœud GPU (réutilise un conteneur existant)
    for n in "${gpu_nodes[@]}"; do
        _info "Ollama-GPU sur ${n}…"
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=12 "${DEPLOY_USER}@${n}" bash -s <<'REOL' || _warn "Ollama-GPU: souci sur ce nœud"
set -e
if curl -sf --max-time 4 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  echo "  ollama déjà présent (réutilisé)"
else
  command -v docker >/dev/null || { echo "  docker absent — installez-le"; exit 1; }
  docker rm -f omega-ollama >/dev/null 2>&1 || true
  docker run -d --name omega-ollama --restart unless-stopped --gpus all \
    -p 11434:11434 -v omega_ollama_models:/root/.ollama \
    -e OLLAMA_HOST=0.0.0.0 -e OLLAMA_KEEP_ALIVE=5m -e OLLAMA_MAX_LOADED_MODELS=2 -e OLLAMA_NUM_PARALLEL=2 \
    ollama/ollama:latest >/dev/null
  echo "  omega-ollama démarré"
fi
cname=$(docker ps --format '{{.Names}}' | grep -iE 'ollama' | head -1)
if [ -n "$cname" ]; then
  docker exec "$cname" nvidia-smi -L >/dev/null 2>&1 && echo "  GPU OK dans le conteneur ($cname)" \
    || { echo "  NVML KO → restart $cname"; docker restart "$cname" >/dev/null; }
fi
REOL
    done

    # 3. Générer la config gateway depuis les modèles réels + déployer LiteLLM
    local gpu_csv; gpu_csv=$(IFS=,; echo "${gpu_nodes[*]}")
    _info "Gateway LiteLLM sur ${gateway_node}:${gateway_port} (config depuis les modèles réels)…"
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 "${DEPLOY_USER}@${gateway_node}" \
        "OMEGA_GPU_NODES='${gpu_csv}' OMEGA_GW_PORT='${gateway_port}' bash -s" <<'RGW' || { _err "Échec déploiement gateway"; return 1; }
set -e
mkdir -p /opt/omega-llm /etc/omega
CFG=/opt/omega-llm/config.yaml
echo "model_list:" > "$CFG"
IFS=',' read -r -a NODES <<< "$OMEGA_GPU_NODES"
for node in "${NODES[@]}"; do
  models=$(curl -sf --max-time 6 "http://${node}:11434/api/tags" 2>/dev/null | \
    python3 -c 'import sys,json;[print(m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2>/dev/null || true)
  for m in $models; do
    printf '  - model_name: %s\n    litellm_params: {model: ollama_chat/%s, api_base: http://%s:11434}\n' "$m" "$m" "$node" >> "$CFG"
  done
done
cat >> "$CFG" <<'YML'
router_settings:
  routing_strategy: least-busy
  num_retries: 2
  allowed_fails: 2
  cooldown_time: 30
litellm_settings:
  drop_params: true
  request_timeout: 600
YML
[ -f /etc/omega/llm-gateway.token ] || echo "sk-omega-$(openssl rand -hex 16)" > /etc/omega/llm-gateway.token
KEY=$(cat /etc/omega/llm-gateway.token)
docker pull ghcr.io/berriai/litellm:main-latest >/dev/null 2>&1 || true
docker rm -f omega-llm-gateway >/dev/null 2>&1 || true
docker run -d --name omega-llm-gateway --restart unless-stopped -p ${OMEGA_GW_PORT}:4000 \
  -e LITELLM_MASTER_KEY="$KEY" -v /opt/omega-llm/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main-latest --config /app/config.yaml --port 4000 >/dev/null
for i in $(seq 1 30); do sleep 3; curl -sf "http://127.0.0.1:${OMEGA_GW_PORT}/health/liveliness" >/dev/null 2>&1 && break; done
echo "  $(grep -c model_name "$CFG") déploiements de modèles configurés"
RGW

    # 4. Mettre à jour cluster.env (VRAM réelle, primaire, URL gateway) + relancer le proxy
    local primary="${OMEGA_GPU_PRIMARY_NODE:-${gpu_nodes[0]}}"
    for n in "${gpu_nodes[@]}"; do
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 "${DEPLOY_USER}@${n}" \
            "PRIMARY='${primary}' GW='http://${gateway_node}:${gateway_port}' bash -s" <<'RENV' || true
f=/etc/omega/cluster.env; mkdir -p /etc/omega; touch "$f"
vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
set_kv(){ grep -q "^$1=" "$f" && sed -i "s|^$1=.*|$1=$2|" "$f" || echo "$1=$2" >> "$f"; }
[ -n "$vram" ] && set_kv OMEGA_GPU_PROXY_TOTAL_VRAM_MIB "$vram"
set_kv OMEGA_GPU_PRIMARY_NODE "$PRIMARY"
set_kv OMEGA_LLM_GATEWAY_URL "$GW"
set_kv OMEGA_LLM_GATEWAY_TOKEN_FILE /etc/omega/llm-gateway.token
systemctl restart omega-gpu-proxy 2>/dev/null || true
RENV
    done

    # 5. Récapitulatif
    local key; key=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=6 "${DEPLOY_USER}@${gateway_node}" "cat /etc/omega/llm-gateway.token" 2>/dev/null || true)
    _ok "GPU LLM prêt (${#gpu_nodes[@]} nœud(s) GPU + gateway unifiée)"
    echo -e "    Endpoint OpenAI : ${CYAN}http://${gateway_node}:${gateway_port}/v1${RESET}"
    echo -e "    Token gateway   : ${CYAN}${key:-/etc/omega/llm-gateway.token}${RESET}"
    echo -en "    Ollama directs  : ${CYAN}"; for n in "${gpu_nodes[@]}"; do echo -n "http://${n}:11434  "; done; echo -e "${RESET}"
    echo -e "    Test            : ${DIM}curl -s http://${gateway_node}:${gateway_port}/v1/models -H \"Authorization: Bearer ${key:-\$TOKEN}\"${RESET}"
    echo -e "    Console GANDAL  : ${DIM}OPENAI_BASE_URL=http://${gateway_node}:${gateway_port}/v1  OPENAI_API_KEY=<token>${RESET}"
}

# ── Accès LLM : ouvrir l'accès des VMs isolées à la gateway (1 commande) ───────
# Ajoute une règle pfSense étroite : la VM (ou tout le réseau OMEGA) ne peut
# joindre QUE l'hôte de la gateway LLM, en restant isolée du reste. Réversible.
do_llm_access() {
    _need_config || return
    _hdr "Accès LLM — ouvrir l'accès des VMs isolées à la gateway"
    local gw_node="${OMEGA_LLM_GATEWAY_NODE:-${CONTROLLER_NODE}}"
    local gw_port="${OMEGA_LLM_GATEWAY_PORT:-4000}"
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        _ask "VMID, 'all' (réseau OMEGA), ou 'reconcile' (auto: vram>0) [reconcile]"
        read -r target; target="${target:-reconcile}"
    fi
    # 'reconcile' : règle l'accès de TOUTES les VMs vram>0 (sur le contrôleur).
    if [[ "$target" == "reconcile" ]]; then
        local extra="${2:-}"   # ex: --dry-run / --prune
        _info "Réconciliation accès LLM (vram>0 → gateway) sur ${CONTROLLER_NODE}…"
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 "${DEPLOY_USER}@${CONTROLLER_NODE}" "mkdir -p /tmp/omega-llm-recon" 2>/dev/null
        local rdir="/tmp/omega-llm-recon"
        rsync "${RSYNC_OPTS[@]}" "${SCRIPT_DIR}/llm-access.sh" "${SCRIPT_DIR}/omega-llm-access-reconciler.sh" \
            "${CONF_FILE}" "${DEPLOY_USER}@${CONTROLLER_NODE}:${rdir}/" 2>/dev/null
        ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 "${DEPLOY_USER}@${CONTROLLER_NODE}" \
            "OMEGA_LLM_GATEWAY_IP='${gw_node}' OMEGA_LLM_GATEWAY_PORT='${gw_port}' OMEGA_CONTROLLER='${CONTROLLER_NODE}' bash ${rdir}/omega-llm-access-reconciler.sh ${extra}"
        return
    fi
    export SSH_KEY DEPLOY_USER OMEGA_CONTROLLER="${CONTROLLER_NODE}" \
           OMEGA_LLM_GATEWAY_IP="${gw_node}" OMEGA_LLM_GATEWAY_PORT="${gw_port}"
    if [[ "$target" == "all" ]]; then
        bash "${SCRIPT_DIR}/llm-access.sh" --all --enable --gateway "$gw_node" --gw-port "$gw_port"
    else
        bash "${SCRIPT_DIR}/llm-access.sh" --vmid "$target" --enable --gateway "$gw_node" --gw-port "$gw_port"
    fi
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
        echo -e "    VMs test          : ${CYAN}${OMEGA_TEST_VMIDS}${RESET}  ${DIM}(${#TEST_VMIDS_ARR[@]} VM(s))${RESET}"
        echo -e "    VMs provisioning  : ${CYAN}${OMEGA_PROVISION_VMIDS}${RESET}"
        echo -e "    VM provisioning   : ${CYAN}${OMEGA_VM_STORAGE}${RESET} · ${CYAN}${OMEGA_VM_BRIDGE}${RESET} · ${DIM}${OMEGA_VM_IMAGE_REMOTE}${RESET}"
        echo -e "    GPU               : $(${DO_GPU} && echo "${GREEN}activé${RESET}" || echo "${DIM}non (--gpu)${RESET}") · nodes=${CYAN}${OMEGA_GPU_NODES:-auto}${RESET} · primary=${CYAN}${OMEGA_GPU_PRIMARY_NODE:-auto}${RESET} · proxy=${CYAN}${OMEGA_GPU_PROXY_URL:-auto}${RESET} · vram=${CYAN}${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:-0}${RESET}MiB"
        echo -e "    Long/scale/fleet  : $(${DO_LONG} && echo "${GREEN}long${RESET}" || echo "${DIM}long off${RESET}") / $(${DO_SCALE} && echo "${GREEN}scale${RESET}" || echo "${DIM}scale off${RESET}") / $(${DO_FLEET} && echo "${GREEN}fleet${RESET}" || echo "${DIM}fleet off${RESET}")"
        echo -e "    Scale config      : ${CYAN}${OMEGA_SCALE_STEPS:-auto 50..target}${RESET} · cleanup=${CYAN}${OMEGA_SCALE_CLEANUP_SCOPE}${RESET} · stop=${CYAN}${OMEGA_SCALE_STOP_AFTER}${RESET} · destroy=${CYAN}${OMEGA_SCALE_DESTROY_AFTER}${RESET}"
        echo -e "    Fleet config      : ${CYAN}${OMEGA_FLEET_VMIDS:-${OMEGA_PROVISION_VMIDS}}${RESET} · charge=${CYAN}${OMEGA_FLEET_VM_COUNT}${RESET} · chaos=${CYAN}${OMEGA_FLEET_CHAOS_VM_COUNT}${RESET} · durée=${CYAN}${OMEGA_FLEET_DURATION_SECS}s${RESET}"
        echo -e "    Destructif        : $(${DO_DESTRUCTIVE} && echo "${RED}activé${RESET}" || echo "${DIM}off${RESET}")"
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

    # ── Réseau privé VMs ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Réseau privé VMs (10.50.0.0/16) ──────────────────────────${RESET}"
    if [[ -n "${OMEGA_NET_VM_IP_PREFIX:-}" ]]; then
        echo -e "   ${GREEN}●${RESET} Réseau activé : bridge=${CYAN}${OMEGA_NET_VM_BRIDGE:-vmbr1}${RESET} vlan=${CYAN}${OMEGA_NET_VM_VLAN_TAG:-30}${RESET} préfixe=${CYAN}${OMEGA_NET_VM_IP_PREFIX}.x${RESET} gw=${CYAN}${OMEGA_NET_VM_GATEWAY:-?}${RESET}"
    else
        echo -e "   ${YELLOW}●${RESET} Réseau désactivé ${DIM}(OMEGA_NET_VM_IP_PREFIX vide → DHCP)${RESET}"
    fi
    echo -e "   ${BOLD}[n]${RESET}  Setup réseau           (vmbr1 VLAN-aware + isolation iptables + règle pfSense mgmt)"
    echo -e "   ${BOLD}[v]${RESET}  ${RED}Supprimer VMs infra${RESET}    (pfSense + toutes VMs infra)"
    echo -e "   ${BOLD}[N]${RESET}  Créer VM pfSense       (VMID ${OMEGA_NET_PFSENSE_VMID:-2290} — routeur/firewall WAN+OMEGA)"
    echo -e "   ${BOLD}[G]${RESET}  Construire template    (Debian 12 + QGA + cloud-init → template RBD VMID ${OMEGA_VM_TEMPLATE_ID:-9001})"
    echo -e "   ${BOLD}[F]${RESET}  Setup SSH pfSense      (copier la clé omega sur pfSense — à faire une fois)"
    echo -e "   ${BOLD}[H]${RESET}  Sync hosts/DNS         (/etc/hosts + routes sur tous les nœuds + pfSense Unbound)"
    echo -e "   ${BOLD}[w]${RESET}  Internet VM            (${GREEN}ISOLÉE PAR DÉFAUT${RESET} — activer/désactiver/lister accès WAN d'une VM)"
    echo -e "   ${BOLD}[k]${RESET}  Lier des VMs           (${GREEN}ISOLÉES PAR DÉFAUT${RESET} — créer canal A↔B ou groupe — C reste isolée de A,B)"
    echo -e "   ${BOLD}[m]${RESET}  Modifier une VM        (vCPU max · RAM/balloon · disque · VRAM GPU · nom → ${GREEN}DNS suivi${RESET} — métadonnées omega_* réécrites)"
    echo -e "   ${BOLD}[o]${RESET}  Redémarrage auto VM    (${GREEN}always-on${RESET} : onboot=1 + watchdog la relance si arrêtée/plantée — on/off)"
    echo -e "   ${BOLD}[D]${RESET}  DNS                    (enregistrer/supprimer/lister un nom ${OMEGA_NET_DNS_DOMAIN:-enspy-gi.gandal})"
    echo -e "   ${BOLD}[R]${RESET}  Réconcilier DNS        (scan VMs omega → ${GREEN}enregistre les manquantes/divergentes${RESET} — filet de sécurité)"
    echo -e "   ${DIM}Placement KVM auto : assuré par le contrôleur Omega (migration_daemon + policy_engine).${RESET}"
    echo ""

    # ── Installation ──────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Installation Omega ────────────────────────────────────────${RESET}"
    echo -e "   ${BOLD}[I]${RESET}  Installation complète  (désinstaller → build → déployer → watchdog QGA)"
    echo -e "   ${BOLD}[u]${RESET}  Désinstaller           (arrêter services + supprimer fichiers + dpkg purge + sysctl)"
    echo -e "   ${BOLD}[b]${RESET}  Build                  (cargo build --release --workspace)"
    echo -e "   ${BOLD}[d]${RESET}  Déployer               (copier binaires + démarrer services)"
    echo -e "   ${BOLD}[p]${RESET}  Créer les VMs physiques Omega  (IP fixe + VLAN si configurés)"
    echo -e "   ${BOLD}[L]${RESET}  GPU LLM (Ollama + gateway)     (serveur Ollama GPU sur chaque nœud + gateway OpenAI unifiée :${OMEGA_LLM_GATEWAY_PORT:-4000} — ${GREEN}1 commande${RESET})"
    echo -e "   ${BOLD}[W]${RESET}  Accès LLM VMs isolées          (VM / 'all' / ${GREEN}'reconcile' auto vram>0${RESET} → gateway uniquement, reste isolée)"
    echo ""

    # ── Tests par section ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Tests ─────────────────────────────────────────────────────${RESET}"
    echo -e "   ${BOLD}[A]${RESET}  Tout — sections 1→7 avec pause entre chaque"
    echo -e "   ${BOLD}[P]${RESET}  Production stricte — tout le projet, aucun skip, GPU/Ceph/long/scale/destructif"
    echo -e "   ${BOLD}[k]${RESET}  Par catégorie de ressource — RAM · CPU · DISK · GPU · RÉSEAU · MIGRATION · MIXTE · OPS"
    echo -e "   ${BOLD}[1]${RESET}  Section 1 — Isolés    : smoke · réplication · failover · éviction"
    echo -e "   ${BOLD}[2]${RESET}  Section 2 — Store+    : recall LIFO · prefetch · TLS TOFU"
    echo -e "   ${BOLD}[3]${RESET}  Section 3 — Cluster   : vCPU · migration · balloon · compaction"
    echo -e "   ${BOLD}[4]${RESET}  Section 4 — GPU       : placement · scheduler · proxy · CUDA$(${DO_GPU} && echo '' || echo '  (--gpu requis)')"
    echo -e "   ${BOLD}[5]${RESET}  Section 5 — Mixtes    : stress · live migration · drain · GPU"
    echo -e "   ${BOLD}[6]${RESET}  Section 6 — Physique  : install · réseau VM · Ceph/GPU réel · panne · soak"
    echo -e "   ${BOLD}[7]${RESET}  Section 7 — Fleet     : 50 VMs charge · 75 VMs chaos · perf host vs VM"
    echo ""

    # ── Tests individuels ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}${MAG}── Test individuel (entrer le numéro) ───────────────────────${RESET}"
    echo -e "   ${DIM}Isolés  :${RESET}  00  01  02  03  04  10  18  20  21  23"
    echo -e "   ${DIM}Cluster :${RESET}  05  06  07  08  09  19  22  24  25  26  27  28  29  30  31  32  33  34  35  36  37"
    echo -e "   ${DIM}Mixtes  :${RESET}  M1  M2  M3  M4  M5  M6  M7  M8  M9"
    echo ""

    echo -e "   ${BOLD}[g]${RESET}  GPU tests : $(${DO_GPU} && echo "${GREEN}activé  ${RESET}→ [g] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [g] pour activer")"
    echo -e "   ${BOLD}[l]${RESET}  Long tests : $(${DO_LONG} && echo "${GREEN}activé  ${RESET}→ [l] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [l] pour activer")"
    echo -e "   ${BOLD}[s]${RESET}  Scale 500 : $(${DO_SCALE} && echo "${GREEN}activé  ${RESET}→ [s] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [s] pour activer")"
    echo -e "   ${BOLD}[f]${RESET}  Fleet 75 : $(${DO_FLEET} && echo "${GREEN}activé  ${RESET}→ [f] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [f] pour activer")"
    echo -e "   ${BOLD}[x]${RESET}  Destructif : $(${DO_DESTRUCTIVE} && echo "${RED}activé  ${RESET}→ [x] pour désactiver" || echo "${YELLOW}désactivé${RESET} → [x] pour activer")"
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
            n)   do_setup_network ;;
            v)   do_clean_infra_vms ;;
            N)   do_create_infra_vms ;;
            G)   do_build_images ;;
            F)   do_setup_pfsense_ssh ;;
            H)   do_sync_hosts ;;
            w)   do_vm_internet ;;
            k)   do_vm_link ;;
            m)   do_vm_reconfigure ;;
            o)   do_vm_autostart ;;
            D)   do_dns_register ;;
            R)   do_dns_reconcile ;;
            I)   do_install_full ;;
            u|U) do_uninstall ;;
            b|B) do_build ;;
            d|D) do_deploy ;;
            p)   do_provision_vms ;;
            L)   do_gpu_llm ;;
            W)   do_llm_access ;;
            P)   run_production_full ;;
            A)   run_all ;;
            k|K) list_categories
                 read -rp "  Catégorie(s) à lancer (ex: RAM, ou \"CPU GPU\", ou all) : " _kcat
                 if [[ -n "$_kcat" ]]; then
                     read -r -a _kcats <<< "${_kcat//,/ }"
                     run_category "${_kcats[@]}"
                 fi ;;
            1)   run_section_1 ;;
            2)   run_section_2 ;;
            3)   run_section_3 ;;
            4)   run_section_4 ;;
            5)   run_section_5 ;;
            6)   run_section_6 ;;
            7)   run_section_7 ;;
            g|G) if $DO_GPU; then DO_GPU=false; _info "Tests GPU désactivés"
                 else DO_GPU=true; _info "Tests GPU activés"
                 fi ;;
            l)   if $DO_LONG; then DO_LONG=false; _info "Tests longue durée désactivés"
                 else DO_LONG=true; _info "Tests longue durée activés"
                 fi ;;
            s|S) if $DO_SCALE; then DO_SCALE=false; _info "Tests scalabilité désactivés"
                 else DO_SCALE=true; _info "Tests scalabilité activés"
                 fi ;;
            f|F) if $DO_FLEET; then DO_FLEET=false; _info "Tests fleet désactivés"
                 else DO_FLEET=true; _info "Tests fleet activés"
                 fi ;;
            x|X) if $DO_DESTRUCTIVE; then DO_DESTRUCTIVE=false; _info "Tests destructifs désactivés"
                 else DO_DESTRUCTIVE=true; _warn "Tests destructifs activés"
                 fi ;;
            r|R) show_results ;;
            q|Q) echo "Au revoir."; exit 0 ;;
            "")  continue ;;
            # Tests individuels : 00-37 ou M1-M9 (insensible casse)
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

# ── Commande directe : catégories de tests (RAM/CPU/DISK/GPU/…) ───────────────
if $LIST_CATEGORIES; then
    list_categories
    exit 0
fi
if [[ -n "$RUN_CATEGORY" ]]; then
    # accepte "RAM", "CPU GPU", ou "all" ; découpe sur espaces/virgules
    read -r -a _cats <<< "${RUN_CATEGORY//,/ }"
    run_category "${_cats[@]}"
    [[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
fi

# ── Commande directe : GPU LLM (non-interactif) ───────────────────────────────
if $DO_LLM; then
    do_gpu_llm
    exit $?
fi
if $DO_LLM_ACCESS; then
    do_llm_access all
    exit $?
fi
if $DO_LLM_ACCESS_RECONCILE; then
    $OMEGA_LAB_DRYRUN && do_llm_access reconcile --dry-run || do_llm_access reconcile
    exit $?
fi

# ── Mode auto (CI) ────────────────────────────────────────────────────────────
if $AUTO; then
    if ! $CONFIGURED; then
        echo "Mode --auto : OMEGA_NODES requis (cluster.conf ou variable d'environnement)"
        exit 1
    fi
    _hdr "Mode automatique — installation + toutes les sections"
    do_install_full
    $DO_PROVISION && do_provision_vms
    if $DO_PRODUCTION; then
        run_production_full
        [[ $TOTAL_FAIL -eq 0 && $TOTAL_SKIP -eq 0 ]] && exit 0 || exit 1
    else
        run_all
        show_results
        [[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
    fi
fi

main_loop
