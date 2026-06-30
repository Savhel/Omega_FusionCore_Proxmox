#!/usr/bin/env bash
# Installe l'agent de réparation réseau (timer systemd) sur LE nœud contrôleur.
# Agent CLUSTER-GLOBAL (une instance) : détecte les VMs Omega running sans IP
# (MAC netplan ≠ net0) et les répare via le guest agent, sans intervention.
# Cf omega-netfix-reconciler.sh.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/install-netfix-reconciler-remote.sh --controller IP [options]

Options:
  --controller IP|HOST   Nœud contrôleur où tourne l'agent (UNE instance). Requis.
  --user USER            SSH user. Default: root.
  --interval SECS        Intervalle du timer systemd. Default: 180.
  --dry-run              Installe en mode observation (log, ne répare pas).
  --ssh-key PATH         Clé SSH.
  --uninstall            Désactive et supprime l'agent du contrôleur.
EOF
}
fail() { echo "ERREUR: $*" >&2; exit 1; }

CONTROLLER=""; USER="root"; INTERVAL="180"; DRY_RUN="0"; SSH_KEY=""; UNINSTALL="0"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller) CONTROLLER="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --dry-run) DRY_RUN="1"; shift ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --uninstall) UNINSTALL="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done
[[ -n "$CONTROLLER" ]] || fail "--controller requis"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || fail "--interval doit etre numerique"

KEYOPT=(-o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && KEYOPT+=(-i "$SSH_KEY")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$UNINSTALL" == "1" ]]; then
    echo "[INFO] désinstallation omega-netfix-reconciler sur $CONTROLLER"
    ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" '
systemctl disable --now omega-netfix-reconciler.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/omega-netfix-reconciler.timer \
      /etc/systemd/system/omega-netfix-reconciler.service \
      /etc/omega/netfix-reconciler.env
systemctl daemon-reload
echo "  supprimé."'
    exit 0
fi

echo "[INFO] installation omega-netfix-reconciler sur $CONTROLLER (agent cluster-global)"
ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" 'install -d -m 0755 /usr/local/sbin /etc/omega /etc/systemd/system /var/log/omega'

# Déploiement : priorité à la copie .deb dans /opt (make deploy-deb), fallback scp en dev.
if ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" 'test -f /opt/omega-remote-paging/scripts/omega-netfix-reconciler.sh'; then
    RC_BIN="/opt/omega-remote-paging/scripts/omega-netfix-reconciler.sh"
    echo "[INFO]   reconciler: copie .deb ${RC_BIN} (pas de scp)"
else
    RC_BIN="/usr/local/sbin/omega-netfix-reconciler"
    scp "${KEYOPT[@]}" "${SCRIPT_DIR}/omega-netfix-reconciler.sh" "${USER}@${CONTROLLER}:${RC_BIN}"
    ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" "chmod 0755 ${RC_BIN}"
    echo "[INFO]   reconciler: scp vers ${RC_BIN} (aucun .deb détecté)"
fi

ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" "
cat >/etc/omega/netfix-reconciler.env <<EOF
OMEGA_NETFIX_DRY_RUN=${DRY_RUN}
EOF
chmod 600 /etc/omega/netfix-reconciler.env
cat >/etc/systemd/system/omega-netfix-reconciler.service <<EOF
[Unit]
Description=Omega netfix reconciler - repair omega VMs stuck without IP (netplan MAC drift)
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/omega/netfix-reconciler.env
ExecStart=${RC_BIN}
EOF
cat >/etc/systemd/system/omega-netfix-reconciler.timer <<EOF
[Unit]
Description=Run Omega netfix reconciler periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now omega-netfix-reconciler.timer
systemctl --no-pager --full status omega-netfix-reconciler.timer | sed -n '1,10p'"
echo "[OK] netfix reconciler installé sur $CONTROLLER (intervalle ${INTERVAL}s, dry-run=${DRY_RUN})"
