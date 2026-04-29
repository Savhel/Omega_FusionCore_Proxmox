#!/usr/bin/env bash
# deploy.sh — Déploie les binaires compilés sur les nœuds du cluster via SSH.
#
# Prérequis :
#   - accès SSH sans mot de passe configuré vers NODE_B et NODE_C
#   - binaires compilés dans target/release/
#
# Variables d'environnement :
#   NODE_A      : hostname/IP du nœud A (optionnel — l'agent peut être lancé localement)
#   NODE_B      : hostname/IP du nœud B (obligatoire pour déployer le store)
#   NODE_C      : hostname/IP du nœud C (obligatoire pour déployer le store)
#   DEPLOY_USER : utilisateur SSH (défaut : root)
#   DEPLOY_DIR  : répertoire de déploiement sur les nœuds (défaut : /opt/omega-remote-paging)

set -euo pipefail

: "${NODE_B:?Variable NODE_B requise (ex: export NODE_B=192.168.1.2)}"
: "${NODE_C:?Variable NODE_C requise (ex: export NODE_C=192.168.1.3)}"
: "${DEPLOY_USER:=root}"
: "${DEPLOY_DIR:=/opt/omega-remote-paging}"
: "${STORE_PORT_B:=9100}"
: "${STORE_PORT_C:=9101}"
# Si NODE_A est défini, déploie aussi le launcher et installe le wrapper QEMU
: "${OMEGA_STORES:=${NODE_B}:${STORE_PORT_B},${NODE_C}:${STORE_PORT_C}}"
: "${OMEGA_INSTALL_VMIDS:=}"  # VMIDs séparés par virgule pour le hookscript

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE_BIN="${ROOT_DIR}/target/release/node-bc-store"
AGENT_BIN="${ROOT_DIR}/target/release/node-a-agent"
LAUNCHER_BIN="${ROOT_DIR}/target/release/omega-qemu-launcher"
DAEMON_BIN="${ROOT_DIR}/target/release/omega-daemon"

info()    { echo -e "\033[32m[INFO]\033[0m  $*"; }
success() { echo -e "\033[32m[OK]\033[0m    $*"; }
fail()    { echo -e "\033[31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ -x "$STORE_BIN"   ]] || fail "node-bc-store non compilé — lancez 'make build' d'abord"
[[ -x "$AGENT_BIN"   ]] || fail "node-a-agent non compilé — lancez 'make build' d'abord"
[[ -x "$LAUNCHER_BIN" ]] || fail "omega-qemu-launcher non compilé — lancez 'make build' d'abord"

# ─── Fonction de déploiement d'un store ───────────────────────────────────────

deploy_store() {
    local node="$1"
    local port="$2"
    local node_id="$3"

    info "Déploiement du store sur ${DEPLOY_USER}@${node} (port ${port}, id=${node_id})..."

    # Création du répertoire
    ssh "${DEPLOY_USER}@${node}" "mkdir -p ${DEPLOY_DIR}/bin ${DEPLOY_DIR}/logs"

    # Copie du binaire
    scp "$STORE_BIN" "${DEPLOY_USER}@${node}:${DEPLOY_DIR}/bin/node-bc-store"

    # Copie du service systemd
    scp "${ROOT_DIR}/scripts/node-bc-store.service.tmpl" \
        "${DEPLOY_USER}@${node}:/tmp/node-bc-store.service" 2>/dev/null || {
        # Génération inline si le template n'existe pas
        ssh "${DEPLOY_USER}@${node}" "cat > /etc/systemd/system/node-bc-store.service" <<EOF
[Unit]
Description=omega-remote-paging store (${node_id})
After=network.target

[Service]
Type=simple
ExecStart=${DEPLOY_DIR}/bin/node-bc-store --listen 0.0.0.0:${port} --node-id ${node_id}
Restart=always
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
EOF
    }

    # Activation et démarrage
    ssh "${DEPLOY_USER}@${node}" "
        systemctl daemon-reload
        systemctl enable node-bc-store.service
        systemctl restart node-bc-store.service
        sleep 1
        systemctl status node-bc-store.service --no-pager || true
    "

    success "Store déployé sur ${node}:${port}"
}

# ─── Déploiement ──────────────────────────────────────────────────────────────

info "=== Déploiement omega-remote-paging ==="
info "Nœud B : ${NODE_B}"
info "Nœud C : ${NODE_C}"
info "Répertoire : ${DEPLOY_DIR}"
echo

deploy_store "$NODE_B" "$STORE_PORT_B" "node-b"
deploy_store "$NODE_C" "$STORE_PORT_C" "node-c"

echo
info "Déploiement des binaires sur nœud A (local ou ${NODE_A:-<local>})..."
if [[ -n "${NODE_A:-}" ]]; then
    ssh "${DEPLOY_USER}@${NODE_A}" "mkdir -p ${DEPLOY_DIR}/bin"
    scp "$AGENT_BIN"    "${DEPLOY_USER}@${NODE_A}:${DEPLOY_DIR}/bin/node-a-agent"
    scp "$LAUNCHER_BIN" "${DEPLOY_USER}@${NODE_A}:${DEPLOY_DIR}/bin/omega-qemu-launcher"
    [[ -x "$DAEMON_BIN" ]] && scp "$DAEMON_BIN" "${DEPLOY_USER}@${NODE_A}:${DEPLOY_DIR}/bin/omega-daemon" || true

    # Copier les scripts d'installation et lancer l'installation du wrapper QEMU
    info "Copie des scripts d'installation sur ${NODE_A}..."
    scp "${ROOT_DIR}/scripts/proxmox_hook.pl"       "${DEPLOY_USER}@${NODE_A}:/tmp/proxmox_hook.pl"
    scp "${ROOT_DIR}/scripts/omega-proxmox-install.sh" "${DEPLOY_USER}@${NODE_A}:/tmp/omega-proxmox-install.sh"

    info "Lancement de omega-proxmox-install.sh sur ${NODE_A}..."
    ssh "${DEPLOY_USER}@${NODE_A}" "
        INSTALL_DIR='${DEPLOY_DIR}/bin' \
        OMEGA_STORES='${OMEGA_STORES}' \
        OMEGA_VMIDS='${OMEGA_INSTALL_VMIDS}' \
        SCRIPT_DIR=/tmp \
        bash /tmp/omega-proxmox-install.sh
    "
    success "Nœud A (${NODE_A}) — launcher + wrapper QEMU installés"
else
    info "NODE_A non défini — binaires et wrapper non déployés (à faire manuellement):"
    info "  INSTALL_DIR=/usr/local/bin OMEGA_STORES='${OMEGA_STORES}' bash scripts/omega-proxmox-install.sh"
fi

echo
success "=== Déploiement terminé ==="
echo
echo "Récapitulatif :"
echo "  Node B store  : ${NODE_B}:${STORE_PORT_B}"
echo "  Node C store  : ${NODE_C}:${STORE_PORT_C}"
if [[ -n "${NODE_A:-}" ]]; then
echo "  Node A launcher: installé dans ${DEPLOY_DIR}/bin/"
echo "  Wrapper QEMU  : /usr/bin/kvm → ${DEPLOY_DIR}/bin/kvm-omega"
echo "  Hookscript    : /var/lib/vz/snippets/omega-hook.pl"
fi
echo
echo "Pour enregistrer le hookscript sur une VM :"
echo "  qm set <vmid> --hookscript local:snippets/omega-hook.pl"
