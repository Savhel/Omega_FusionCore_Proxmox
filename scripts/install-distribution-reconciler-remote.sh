#!/usr/bin/env bash
# Installe l'agent de réconciliation de distribution (timer systemd) sur LE nœud
# contrôleur. C'est un agent CLUSTER-GLOBAL (une seule instance) : il maintient la
# répartition cible des VMs omega par nœud (ex. 1 Emilia / 2 Ram / 2 Rem) par
# live-migration, sans intervention humaine.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/install-distribution-reconciler-remote.sh --controller IP [options]

Options:
  --controller IP|HOST    Nœud contrôleur où tourne l'agent (UNE instance). Requis.
  --user USER             SSH user. Default: root.
  --interval SECS         Intervalle du timer systemd. Default: 120.
  --distribution SPEC     Quotas "IP_ou_nom:max,...". Default: hérité de l'env/conf.
  --default-max N         Quota des nœuds absents de la liste. Default: 2.
  --max-per-tick N        Migrations max par tick (anti-storm). Default: 1.
  --pin-vmids CSV         VMID à ne jamais migrer.
  --dry-run               Installe en mode observation (log, pas de migration).
  --ssh-key PATH          Clé SSH.
  --uninstall             Désactive et supprime l'agent du contrôleur.
EOF
}

fail() { echo "ERREUR: $*" >&2; exit 1; }

CONTROLLER=""
USER="root"
INTERVAL="120"
DISTRIBUTION="${OMEGA_VM_NODE_DISTRIBUTION:-}"
DEFAULT_MAX="${OMEGA_VM_NODE_DEFAULT_MAX:-2}"
MAX_PER_TICK="${OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK:-1}"
PIN_VMIDS="${OMEGA_RECONCILE_PIN_VMIDS:-}"
DRY_RUN="0"
SSH_KEY=""
UNINSTALL="0"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller) CONTROLLER="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --distribution) DISTRIBUTION="$2"; shift 2 ;;
        --default-max) DEFAULT_MAX="$2"; shift 2 ;;
        --max-per-tick) MAX_PER_TICK="$2"; shift 2 ;;
        --pin-vmids) PIN_VMIDS="$2"; shift 2 ;;
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
    echo "[INFO] désinstallation omega-distribution-reconciler sur $CONTROLLER"
    ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" '
systemctl disable --now omega-distribution-reconciler.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/omega-distribution-reconciler.timer \
      /etc/systemd/system/omega-distribution-reconciler.service \
      /etc/omega/distribution-reconciler.env
systemctl daemon-reload
echo "  supprimé."'
    exit 0
fi

echo "[INFO] installation omega-distribution-reconciler sur $CONTROLLER (agent cluster-global)"
ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" 'install -d -m 0755 /usr/local/sbin /etc/omega /etc/systemd/system /var/log/omega'

# Déploiement : priorité à la copie .deb dans /opt (make deploy-deb), fallback scp en dev.
if ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" 'test -f /opt/omega-remote-paging/scripts/omega-distribution-reconciler.sh'; then
    RC_BIN="/opt/omega-remote-paging/scripts/omega-distribution-reconciler.sh"
    echo "[INFO]   reconciler: copie .deb ${RC_BIN} (pas de scp)"
else
    RC_BIN="/usr/local/sbin/omega-distribution-reconciler"
    scp "${KEYOPT[@]}" "${SCRIPT_DIR}/omega-distribution-reconciler.sh" "${USER}@${CONTROLLER}:${RC_BIN}"
    ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" "chmod 0755 ${RC_BIN}"
    echo "[INFO]   reconciler: scp vers ${RC_BIN} (aucun .deb détecté)"
fi

ssh "${KEYOPT[@]}" "${USER}@${CONTROLLER}" "
cat >/etc/omega/distribution-reconciler.env <<EOF
OMEGA_VM_NODE_DISTRIBUTION=${DISTRIBUTION}
OMEGA_VM_NODE_DEFAULT_MAX=${DEFAULT_MAX}
OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK=${MAX_PER_TICK}
OMEGA_RECONCILE_PIN_VMIDS=${PIN_VMIDS}
OMEGA_RECONCILE_DRY_RUN=${DRY_RUN}
EOF
chmod 600 /etc/omega/distribution-reconciler.env
cat >/etc/systemd/system/omega-distribution-reconciler.service <<EOF
[Unit]
Description=Omega distribution reconciler - keep omega VMs balanced per node (live migration)
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/omega/distribution-reconciler.env
ExecStart=${RC_BIN}
EOF
cat >/etc/systemd/system/omega-distribution-reconciler.timer <<EOF
[Unit]
Description=Run Omega distribution reconciler periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now omega-distribution-reconciler.timer
systemctl --no-pager --full status omega-distribution-reconciler.timer | sed -n '1,10p'"
echo "[OK] reconciler installé sur $CONTROLLER (intervalle ${INTERVAL}s, dry-run=${DRY_RUN})"
