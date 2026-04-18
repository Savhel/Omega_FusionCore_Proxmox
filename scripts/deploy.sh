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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE_BIN="${ROOT_DIR}/target/release/node-bc-store"
AGENT_BIN="${ROOT_DIR}/target/release/node-a-agent"

info()    { echo -e "\033[32m[INFO]\033[0m  $*"; }
success() { echo -e "\033[32m[OK]\033[0m    $*"; }
fail()    { echo -e "\033[31m[FAIL]\033[0m  $*" >&2; exit 1; }

[[ -x "$STORE_BIN" ]] || fail "node-bc-store non compilé — lancez 'make build' d'abord"
[[ -x "$AGENT_BIN" ]] || fail "node-a-agent non compilé — lancez 'make build' d'abord"

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
info "Déploiement du binaire agent sur nœud A (local ou ${NODE_A:-<local>})..."
if [[ -n "${NODE_A:-}" ]]; then
    ssh "${DEPLOY_USER}@${NODE_A}" "mkdir -p ${DEPLOY_DIR}/bin"
    scp "$AGENT_BIN" "${DEPLOY_USER}@${NODE_A}:${DEPLOY_DIR}/bin/node-a-agent"
    success "Agent déployé sur ${NODE_A}"
else
    info "NODE_A non défini — agent non déployé (à lancer manuellement)"
fi

echo
success "=== Déploiement terminé ==="
echo
echo "Pour lancer l'agent sur le nœud A :"
echo "  sudo ${DEPLOY_DIR}/bin/node-a-agent \\"
echo "    --stores ${NODE_B}:${STORE_PORT_B},${NODE_C}:${STORE_PORT_C} \\"
echo "    --vm-id 100 \\"
echo "    --region-mib 512 \\"
echo "    --mode daemon"
