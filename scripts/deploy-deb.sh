#!/usr/bin/env bash
# deploy-deb.sh — Déploie omega-remote-paging via paquet Debian (.deb) sur les nœuds.
#
# Préféré à deploy.sh : un seul fichier transféré, installation atomique avec dpkg,
# rollback trivial via `apt remove`, traçable par `dpkg -l`.
#
# Variables d'environnement :
#   OMEGA_NODES      : nœuds séparés par virgule (défaut : lire cluster.conf)
#   OMEGA_CONTROLLER : nœud contrôleur                 (défaut : lire cluster.conf)
#   DEPLOY_USER      : utilisateur SSH                 (défaut : root)
#   SSH_KEY          : clé privée SSH                  (défaut : agent)
#   DEB_PATH         : chemin du .deb local            (défaut : auto-build)
#   SKIP_BUILD       : 1 = ne pas (re)builder le .deb
#   OMEGA_INSTALL_VMIDS, OMEGA_GPU_*  : passés à omega-node-install
#
# Exemple :
#   OMEGA_NODES=10.10.0.11,10.10.0.12,10.10.0.13 \
#   OMEGA_CONTROLLER=10.10.0.11 \
#       bash scripts/deploy-deb.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Toujours sourcer cluster.conf si présent, pour récupérer SSH_KEY, GPU_*, etc.
# (l'env override est appliqué par les `: "${VAR:=default}"` plus bas)
if [[ -f "${SCRIPT_DIR}/cluster.conf" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/cluster.conf"
fi

: "${OMEGA_NODES:?Variable OMEGA_NODES requise}"
: "${OMEGA_CONTROLLER:?Variable OMEGA_CONTROLLER requise}"
: "${DEPLOY_USER:=root}"
: "${SSH_KEY:=}"
: "${SKIP_BUILD:=0}"
: "${STORE_PORT:=9100}"
: "${STATUS_PORT:=9200}"
: "${OMEGA_INSTALL_VMIDS:=${OMEGA_TEST_VMIDS:-}}"
: "${OMEGA_GPU_NODES:=}"
: "${OMEGA_GPU_PRIMARY_NODE:=}"
: "${OMEGA_GPU_PROXY_URL:=}"
: "${OMEGA_GPU_PROXY_LISTEN:=0.0.0.0:9400}"
: "${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB:=0}"
: "${OMEGA_GPU_PROXY_ENABLED:=0}"
: "${OMEGA_GPU_MIGRATE_TO_GPU_NODE:=1}"
: "${OMEGA_GPU_FALLBACK_NETWORK:=1}"
: "${OMEGA_GPU_PROXY_API_TOKEN_FILE:=/etc/omega/gpu-proxy.token}"
: "${OMEGA_GPU_PROXY_API_TOKEN:=}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
    SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")
    SCP_OPTS=(-i "$SSH_KEY" "${SCP_OPTS[@]}")
fi

info()    { echo -e "\033[32m[INFO]\033[0m  $*"; }
success() { echo -e "\033[32m[OK]\033[0m    $*"; }
fail()    { echo -e "\033[31m[FAIL]\033[0m  $*" >&2; exit 1; }

# ─── 1. Construire le .deb si nécessaire ──────────────────────────────────────

if [[ -z "${DEB_PATH:-}" ]]; then
    PKG_VERSION="$(grep -m1 '^version' "${ROOT_DIR}/omega-daemon/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
    DEB_PATH="${ROOT_DIR}/target/deb/omega-remote-paging_${PKG_VERSION}_amd64.deb"
fi

if [[ "$SKIP_BUILD" != "1" || ! -f "$DEB_PATH" ]]; then
    info "Construction du paquet (.deb)…"
    bash "${SCRIPT_DIR}/build-deb.sh"
fi

[[ -f "$DEB_PATH" ]] || fail ".deb introuvable: ${DEB_PATH}"
info "Paquet : $(basename "$DEB_PATH") ($(du -h "$DEB_PATH" | cut -f1))"

# ─── 2. Détecter les nœuds GPU si non fournis ─────────────────────────────────

IFS=',' read -ra NODES_ARR <<< "$OMEGA_NODES"

if [[ -z "$OMEGA_GPU_NODES" ]]; then
    for candidate in "${NODES_ARR[@]}"; do
        if ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${candidate}" \
            "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1" \
            >/dev/null 2>&1; then
            OMEGA_GPU_NODES="${OMEGA_GPU_NODES:+$OMEGA_GPU_NODES,}${candidate}"
        fi
    done
fi

[[ -z "$OMEGA_GPU_PRIMARY_NODE" ]] && OMEGA_GPU_PRIMARY_NODE="${OMEGA_GPU_NODES%%,*}"
[[ -z "$OMEGA_GPU_PRIMARY_NODE" ]] && OMEGA_GPU_PRIMARY_NODE="$OMEGA_CONTROLLER"
[[ -z "$OMEGA_GPU_PROXY_URL" ]] && OMEGA_GPU_PROXY_URL="http://${OMEGA_GPU_PRIMARY_NODE}:9400"
[[ -z "$OMEGA_GPU_PROXY_API_TOKEN" ]] && \
    OMEGA_GPU_PROXY_API_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

node_in_csv() {
    local needle="$1" csv="$2" item
    IFS=',' read -ra _items <<< "$csv"
    for item in "${_items[@]}"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

info "=== Déploiement .deb omega-remote-paging ==="
info "Nœuds        : ${NODES_ARR[*]}"
info "Contrôleur   : ${OMEGA_CONTROLLER}"
info "Nœuds GPU    : ${OMEGA_GPU_NODES:-aucun}"
info "GPU primaire : ${OMEGA_GPU_PRIMARY_NODE}"
echo

# ─── 3. Déploiement par nœud ──────────────────────────────────────────────────

DEB_NAME="$(basename "$DEB_PATH")"
REMOTE_DEB="/tmp/${DEB_NAME}"

for node in "${NODES_ARR[@]}"; do
    info "── Nœud ${node} ──"

    # Stores distants (tous les autres nœuds)
    node_stores=""
    node_peers=""
    for s in "${NODES_ARR[@]}"; do
        [[ "$s" == "$node" ]] && continue
        node_stores="${node_stores:+$node_stores,}${s}:${STORE_PORT}"
        node_peers="${node_peers:+$node_peers,}${s}:${STATUS_PORT}"
    done

    node_id="$(ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "hostname -s" | tr -d '\r' | head -1)"
    [[ -n "$node_id" ]] || node_id="$node"

    node_gpu_proxy_enabled=0
    if [[ "${OMEGA_GPU_PROXY_ENABLED}" == "1" ]] && node_in_csv "$node" "$OMEGA_GPU_NODES"; then
        node_gpu_proxy_enabled=1
    fi

    info "Transfert ${DEB_NAME} → ${node}…"
    scp "${SCP_OPTS[@]}" "$DEB_PATH" "${DEPLOY_USER}@${node}:${REMOTE_DEB}" >/dev/null

    info "Pré-config /etc/omega/cluster.env sur ${node}…"
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
        mkdir -p /etc/omega
        cat > /etc/omega/cluster.env <<'ENVEOF'
OMEGA_NODES=${OMEGA_NODES}
OMEGA_CONTROLLER=${OMEGA_CONTROLLER}
OMEGA_NODE_ID=${node_id}
OMEGA_NODE_ADDR=${node}
OMEGA_STORE_PORT=${STORE_PORT}
OMEGA_API_PORT=${STATUS_PORT}
OMEGA_PEERS=${node_peers}
OMEGA_GPU_NODES=${OMEGA_GPU_NODES}
OMEGA_GPU_PRIMARY_NODE=${OMEGA_GPU_PRIMARY_NODE}
OMEGA_GPU_PROXY_URL=${OMEGA_GPU_PROXY_URL}
OMEGA_GPU_PROXY_LISTEN=${OMEGA_GPU_PROXY_LISTEN}
OMEGA_GPU_PROXY_TOTAL_VRAM_MIB=${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB}
OMEGA_GPU_PROXY_API_TOKEN_FILE=${OMEGA_GPU_PROXY_API_TOKEN_FILE}
OMEGA_GPU_MIGRATE_TO_GPU_NODE=${OMEGA_GPU_MIGRATE_TO_GPU_NODE}
OMEGA_GPU_FALLBACK_NETWORK=${OMEGA_GPU_FALLBACK_NETWORK}
ENVEOF
        # Token GPU proxy (un seul partagé pour le cluster)
        umask 077
        printf '%s\n' '${OMEGA_GPU_PROXY_API_TOKEN}' > '${OMEGA_GPU_PROXY_API_TOKEN_FILE}'
        chmod 600 '${OMEGA_GPU_PROXY_API_TOKEN_FILE}'
        # userfaultfd non privilégié (persistant via sysctl.d, neutre si sysctl.conf absent)
        sysctl -w vm.unprivileged_userfaultfd=1 >/dev/null
        mkdir -p /etc/sysctl.d
        echo 'vm.unprivileged_userfaultfd=1' > /etc/sysctl.d/99-omega.conf
    "

    info "Installation paquet sur ${node} (apt + dpkg)…"
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
        # Arrêter services avant upgrade pour éviter de réécrire un binaire actif
        systemctl stop omega-daemon.service 2>/dev/null || true
        systemctl stop omega-gpu-proxy.service 2>/dev/null || true
        # apt gère les deps mieux que dpkg -i nu
        apt-get install -y --reinstall '${REMOTE_DEB}' || {
            echo '[FALLBACK] apt install -y'
            DEBIAN_FRONTEND=noninteractive apt-get install -y -f
            dpkg -i '${REMOTE_DEB}'
        }
    "

    info "Activation hookscript Proxmox + wrapper QEMU sur ${node}…"
    # Les binaires sont déjà installés par le .deb dans /opt/omega-remote-paging/bin/
    # On passe les *_SRC explicites pour que omega-proxmox-install.sh ne tente pas
    # de les chercher dans target/release/ (qui n'existe pas après install par .deb).
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
        OMEGA_STORES='${node_stores}' \
        OMEGA_VMIDS='${OMEGA_INSTALL_VMIDS}' \
        OMEGA_GPU_NODES='${OMEGA_GPU_NODES}' \
        OMEGA_GPU_PRIMARY_NODE='${OMEGA_GPU_PRIMARY_NODE}' \
        OMEGA_GPU_PROXY_URL='${OMEGA_GPU_PROXY_URL}' \
        OMEGA_GPU_PROXY_ENABLED='${node_gpu_proxy_enabled}' \
        OMEGA_GPU_PROXY_LISTEN='${OMEGA_GPU_PROXY_LISTEN}' \
        OMEGA_GPU_PROXY_TOTAL_VRAM_MIB='${OMEGA_GPU_PROXY_TOTAL_VRAM_MIB}' \
        OMEGA_GPU_PROXY_API_TOKEN_FILE='${OMEGA_GPU_PROXY_API_TOKEN_FILE}' \
        OMEGA_GPU_PROXY_API_TOKEN='${OMEGA_GPU_PROXY_API_TOKEN}' \
        OMEGA_GPU_MIGRATE_TO_GPU_NODE='${OMEGA_GPU_MIGRATE_TO_GPU_NODE}' \
        OMEGA_GPU_FALLBACK_NETWORK='${OMEGA_GPU_FALLBACK_NETWORK}' \
        INSTALL_DIR=/opt/omega-remote-paging/bin \
        LAUNCHER_SRC=/opt/omega-remote-paging/bin/omega-qemu-launcher \
        AGENT_SRC=/opt/omega-remote-paging/bin/node-a-agent \
        DAEMON_SRC=/opt/omega-remote-paging/bin/omega-daemon \
        GPU_PROXY_SRC=/opt/omega-remote-paging/bin/omega-gpu-proxy \
        BRIDGE_SRC=/opt/omega-remote-paging/bin/omega-uffd-bridge.so \
        GPU_WORKER_CPU_SRC=/opt/omega-remote-paging/workers/omega-gpu-worker-cpu.py \
        GPU_WORKER_APP_SRC=/opt/omega-remote-paging/workers/omega-gpu-worker-app.py \
        OMEGA_AGENT_BIN=/opt/omega-remote-paging/bin/node-a-agent \
        omega-node-install
    "

    info "Démarrage omega-daemon sur ${node}…"
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "
        systemctl daemon-reload
        systemctl enable --now omega-daemon.service
        sleep 1
        systemctl is-active omega-daemon.service >/dev/null || {
            echo '[FAIL] omega-daemon non actif après démarrage'
            journalctl -u omega-daemon --since '1 min ago' -n 30 --no-pager
            exit 1
        }
    "

    # Nettoyage
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "rm -f '${REMOTE_DEB}'" || true

    success "Nœud ${node} déployé via .deb"
    echo
done

success "=== Déploiement .deb terminé ==="
echo
echo "Vérification rapide :"
echo "  for n in ${NODES_ARR[*]}; do ssh ${DEPLOY_USER}@\$n 'dpkg -l omega-remote-paging | tail -1; systemctl is-active omega-daemon'; done"
echo
echo "Désinstallation :"
echo "  for n in ${NODES_ARR[*]}; do ssh ${DEPLOY_USER}@\$n 'apt remove -y omega-remote-paging'; done"
