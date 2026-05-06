#!/usr/bin/env bash
# deploy.sh — Déploie les binaires compilés sur tous les nœuds du cluster via SSH.
#
# Variables d'environnement :
#   OMEGA_NODES      : nœuds séparés par virgule (défaut : lire cluster.conf)
#   OMEGA_CONTROLLER : nœud qui active le contrôleur (défaut : lire cluster.conf)
#   DEPLOY_USER      : utilisateur SSH (défaut : root)
#   DEPLOY_DIR       : répertoire de déploiement sur les nœuds (défaut : /opt/omega-remote-paging)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Sourcer cluster.conf si les variables ne sont pas déjà définies
if [[ -z "${OMEGA_NODES:-}" ]] || [[ -z "${OMEGA_CONTROLLER:-}" ]]; then
    source "${SCRIPT_DIR}/cluster.conf"
fi

: "${OMEGA_NODES:?Variable OMEGA_NODES requise}"
: "${OMEGA_CONTROLLER:?Variable OMEGA_CONTROLLER requise}"
: "${DEPLOY_USER:=root}"
: "${DEPLOY_DIR:=/opt/omega-remote-paging}"
: "${STORE_PORT:=9100}"
: "${OMEGA_INSTALL_VMIDS:=}"

DAEMON_BIN="${ROOT_DIR}/target/release/omega-daemon"
AGENT_BIN="${ROOT_DIR}/target/release/node-a-agent"
LAUNCHER_BIN="${ROOT_DIR}/target/release/omega-qemu-launcher"

info()    { echo -e "\033[32m[INFO]\033[0m  $*"; }
success() { echo -e "\033[32m[OK]\033[0m    $*"; }
fail()    { echo -e "\033[31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ -x "$DAEMON_BIN"   ]] || fail "omega-daemon non compilé — lancez 'make build' d'abord"
[[ -x "$AGENT_BIN"    ]] || fail "node-a-agent non compilé — lancez 'make build' d'abord"
[[ -x "$LAUNCHER_BIN" ]] || fail "omega-qemu-launcher non compilé — lancez 'make build' d'abord"

IFS=',' read -ra NODES_ARR <<< "$OMEGA_NODES"

# Construire OMEGA_STORES = tous les nœuds avec leur port store
OMEGA_STORES=""
for n in "${NODES_ARR[@]}"; do
    OMEGA_STORES="${OMEGA_STORES:+$OMEGA_STORES,}${n}:${STORE_PORT}"
done

info "=== Déploiement omega-remote-paging ==="
info "Nœuds      : ${NODES_ARR[*]}"
info "Contrôleur : ${OMEGA_CONTROLLER}"
info "Répertoire : ${DEPLOY_DIR}"
echo

# ─── Déploiement sur chaque nœud ─────────────────────────────────────────────

for node in "${NODES_ARR[@]}"; do
    info "── Nœud ${node} ──"

    ssh "${DEPLOY_USER}@${node}" "mkdir -p ${DEPLOY_DIR}/bin ${DEPLOY_DIR}/logs"

    # Arrêter le daemon avant de remplacer les binaires (on ne peut pas écraser un exécutable en cours)
    ssh "${DEPLOY_USER}@${node}" "systemctl stop omega-daemon 2>/dev/null || true"

    scp "$DAEMON_BIN"    "${DEPLOY_USER}@${node}:${DEPLOY_DIR}/bin/omega-daemon"
    scp "$AGENT_BIN"     "${DEPLOY_USER}@${node}:${DEPLOY_DIR}/bin/node-a-agent"
    scp "$LAUNCHER_BIN"  "${DEPLOY_USER}@${node}:${DEPLOY_DIR}/bin/omega-qemu-launcher"

    scp "${SCRIPT_DIR}/proxmox_hook.pl"          "${DEPLOY_USER}@${node}:/tmp/proxmox_hook.pl"
    scp "${SCRIPT_DIR}/omega-proxmox-install.sh" "${DEPLOY_USER}@${node}:/tmp/omega-proxmox-install.sh"

    # Stores distants = tous les autres nœuds
    node_stores=""
    for s in "${NODES_ARR[@]}"; do
        [[ "$s" == "$node" ]] && continue
        node_stores="${node_stores:+$node_stores,}${s}:${STORE_PORT}"
    done

    info "Activation userfaultfd sur ${node}..."
    ssh "${DEPLOY_USER}@${node}" "
        sysctl -w vm.unprivileged_userfaultfd=1
        grep -q 'unprivileged_userfaultfd' /etc/sysctl.conf \
            || echo 'vm.unprivileged_userfaultfd=1' >> /etc/sysctl.conf
    "

    info "Création /etc/omega/cluster.env sur ${node}..."
    ssh "${DEPLOY_USER}@${node}" "
        mkdir -p /etc/omega
        cat > /etc/omega/cluster.env <<'ENVEOF'
OMEGA_NODES=${OMEGA_NODES}
OMEGA_CONTROLLER=${OMEGA_CONTROLLER}
OMEGA_STORE_PORT=${STORE_PORT}
ENVEOF
    "

    info "Installation wrapper QEMU sur ${node} (stores: ${node_stores})..."
    ssh "${DEPLOY_USER}@${node}" "
        INSTALL_DIR='${DEPLOY_DIR}/bin' \
        LAUNCHER_SRC='${DEPLOY_DIR}/bin/omega-qemu-launcher' \
        AGENT_SRC='${DEPLOY_DIR}/bin/node-a-agent' \
        DAEMON_SRC='${DEPLOY_DIR}/bin/omega-daemon' \
        OMEGA_STORES='${node_stores}' \
        OMEGA_VMIDS='${OMEGA_INSTALL_VMIDS}' \
        bash /tmp/omega-proxmox-install.sh
    "

    # Démarrer omega-daemon sur tous les nœuds
    info "Démarrage omega-daemon sur ${node}..."
    ssh "${DEPLOY_USER}@${node}" "
        systemctl daemon-reload
        systemctl enable omega-daemon.service
        systemctl restart omega-daemon.service
        sleep 1
        systemctl is-active omega-daemon.service || true
    "
    success "omega-daemon actif sur ${node}"

    success "Nœud ${node} déployé"
    echo
done

success "=== Déploiement terminé ==="
echo
echo "Récapitulatif :"
for node in "${NODES_ARR[@]}"; do
    if [[ "$node" == "$OMEGA_CONTROLLER" ]]; then
        echo "  ${node} : binaires + wrapper QEMU + contrôleur actif"
    else
        echo "  ${node} : binaires + wrapper QEMU"
    fi
done
echo
echo "Pour enregistrer le hookscript sur une VM :"
echo "  qm set <vmid> --hookscript local:snippets/omega-hook.pl"
