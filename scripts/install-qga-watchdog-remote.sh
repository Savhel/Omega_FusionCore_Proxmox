#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/install-qga-watchdog-remote.sh --nodes A,B,C [options]

Options:
  --nodes CSV             Proxmox nodes/IPs. Required.
  --user USER             SSH user. Default: root.
  --root-password PASS    Guest root password used by watchdog SSH fallback. Default: root.
  --vmids CSV             Optional VMIDs scope. Empty = local VMs tagged omega.
  --reset-stuck 0|1       Reset VM after repeated QGA failures. Default: 0.
  --interval SECS         systemd timer interval. Default: 60.

  --add-vmid N            Ajoute le VMID N à la liste surveillée (always-on) sur tous
                          les nœuds, active l'autostart, recharge le timer — SANS
                          réinstaller. Ex : --nodes emilia,ram,rem --add-vmid 3001
  --remove-vmid N         Retire le VMID N de la liste (autostart=0 si liste vide).
EOF
}

fail() { echo "ERREUR: $*" >&2; exit 1; }
NODES=""
USER="root"
ROOT_PASSWORD="root"
VMIDS=""
INFRA_VMIDS=""         # VMs infra (pfSense/DNS) : autostart-only, config jamais touchée
RESET_STUCK="0"
INTERVAL="60"
ENSURE_CONFORMANT="1"
AUTOSTART=""           # vide = auto (1 si VMIDS fourni, sinon 0)
VCPU_MAX="4"
BALLOON_MIN="512"
SSH_KEY=""
ADD_VMID=""             # ajoute un VMID à la liste surveillée (always-on) sans réinstaller
REMOVE_VMID=""          # retire un VMID de la liste
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes) NODES="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --vmids) VMIDS="$2"; shift 2 ;;
        --infra-vmids) INFRA_VMIDS="$2"; shift 2 ;;
        --reset-stuck) RESET_STUCK="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --ensure-conformant) ENSURE_CONFORMANT="$2"; shift 2 ;;
        --autostart) AUTOSTART="$2"; shift 2 ;;
        --vcpu-max) VCPU_MAX="$2"; shift 2 ;;
        --balloon-min) BALLOON_MIN="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --add-vmid) ADD_VMID="$2"; shift 2 ;;
        --remove-vmid) REMOVE_VMID="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done
[[ -n "$NODES" ]] || fail "--nodes requis"
# autostart par défaut : 1 si une liste VMIDS explicite, sinon 0
[[ -n "$AUTOSTART" ]] || { [[ -n "$VMIDS" ]] && AUTOSTART="1" || AUTOSTART="0"; }
[[ "$RESET_STUCK" =~ ^[01]$ ]] || fail "--reset-stuck doit valoir 0 ou 1"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || fail "--interval doit etre numerique"

KEYOPT=(-o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && KEYOPT+=(-i "$SSH_KEY")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IFS=',' read -r -a NODE_ARR <<< "$NODES"

# ── Mode léger : ajouter/retirer un VMID de la liste surveillée (always-on) SANS
# réinstaller. Édite /etc/omega/qga-watchdog.env sur chaque nœud + relance le timer.
# Le watchdog n'agit que sur les VMs LOCALES → on met le VMID sur TOUS les nœuds
# (où qu'elle migre, elle reste surveillée). --add active aussi AUTOSTART ; --remove
# repasse AUTOSTART=0 si la liste devient vide (évite d'auto-démarrer toute la flotte).
if [[ -n "$ADD_VMID" || -n "$REMOVE_VMID" ]]; then
    target="${ADD_VMID:-$REMOVE_VMID}"; op="add"; [[ -n "$REMOVE_VMID" ]] && op="remove"
    [[ "$target" =~ ^[0-9]+$ ]] || fail "--add-vmid/--remove-vmid doit etre numerique"
    for node in "${NODE_ARR[@]}"; do
        [[ -n "$node" ]] || continue
        echo "[INFO] ${op} VMID ${target} sur ${node}"
        ssh "${KEYOPT[@]}" "${USER}@${node}" bash -s -- "$op" "$target" <<'REOF'
op="$1"; target="$2"
env=/etc/omega/qga-watchdog.env
[ -f "$env" ] || { echo "  watchdog non installe ici — ignore"; exit 0; }
cur=$(sed -n 's/^OMEGA_QGA_WATCHDOG_VMIDS=//p' "$env" | head -1)
new=$(printf '%s\n' "$cur" | tr ',' '\n' | grep -E '^[0-9]+$' | grep -vx "$target" | paste -sd, -)
[ "$op" = add ] && new="${new:+$new,}$target"
sed -i "s/^OMEGA_QGA_WATCHDOG_VMIDS=.*/OMEGA_QGA_WATCHDOG_VMIDS=$new/" "$env"
if [ "$op" = add ]; then
    sed -i "s/^OMEGA_QGA_WATCHDOG_AUTOSTART=.*/OMEGA_QGA_WATCHDOG_AUTOSTART=1/" "$env"
elif [ -z "$new" ]; then
    sed -i "s/^OMEGA_QGA_WATCHDOG_AUTOSTART=.*/OMEGA_QGA_WATCHDOG_AUTOSTART=0/" "$env"
fi
echo "  liste surveillee → ${new:-(vide)}"
systemctl restart omega-qga-watchdog.timer >/dev/null 2>&1 || true
REOF
    done
    echo "[OK] termine (${op} ${target})."
    exit 0
fi

for node in "${NODE_ARR[@]}"; do
    [[ -n "$node" ]] || continue
    echo "[INFO] installation omega-qga-watchdog sur $node"
    ssh "${KEYOPT[@]}" "${USER}@${node}" 'install -d -m 0755 /usr/local/sbin /etc/omega /etc/systemd/system /var/log/omega /var/lib/omega/qga-watchdog'
    # Déploiement propre : on utilise en priorité la copie livrée par le .deb dans /opt
    # (make deploy-deb). Fallback scp uniquement en dev sans paquet installé.
    if ssh "${KEYOPT[@]}" "${USER}@${node}" 'test -f /opt/omega-remote-paging/scripts/omega-qga-watchdog.sh'; then
        WD_BIN="/opt/omega-remote-paging/scripts/omega-qga-watchdog.sh"
        echo "[INFO]   watchdog: copie .deb ${WD_BIN} (pas de scp)"
    else
        WD_BIN="/usr/local/sbin/omega-qga-watchdog"
        scp "${KEYOPT[@]}" "${SCRIPT_DIR}/omega-qga-watchdog.sh" "${USER}@${node}:${WD_BIN}"
        ssh "${KEYOPT[@]}" "${USER}@${node}" "chmod 0755 ${WD_BIN}"
        echo "[INFO]   watchdog: scp vers ${WD_BIN} (aucun .deb détecté)"
    fi
    ssh "${KEYOPT[@]}" "${USER}@${node}" "
cat >/etc/omega/qga-watchdog.env <<EOF
OMEGA_QGA_WATCHDOG_ROOT_PASSWORD=${ROOT_PASSWORD}
OMEGA_QGA_WATCHDOG_VMIDS=${VMIDS}
OMEGA_QGA_WATCHDOG_INFRA_VMIDS=${INFRA_VMIDS}
OMEGA_QGA_WATCHDOG_RESET_STUCK=${RESET_STUCK}
OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD=3
OMEGA_QGA_WATCHDOG_ENSURE_CONFORMANT=${ENSURE_CONFORMANT}
OMEGA_QGA_WATCHDOG_AUTOSTART=${AUTOSTART}
OMEGA_QGA_WATCHDOG_VCPU_MAX=${VCPU_MAX}
OMEGA_QGA_WATCHDOG_BALLOON_MIN=${BALLOON_MIN}
OMEGA_QGA_WATCHDOG_DISK_AUTOGROW=1
OMEGA_QGA_WATCHDOG_DISK_THRESHOLD_PCT=85
OMEGA_QGA_WATCHDOG_DISK_TAIL_GIB=1
OMEGA_QGA_WATCHDOG_CPU_TYPE=x86-64-v2-AES
EOF
chmod 600 /etc/omega/qga-watchdog.env
cat >/etc/systemd/system/omega-qga-watchdog.service <<'EOF'
[Unit]
Description=Omega QGA watchdog - repair qemu-guest-agent in Omega VMs
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/omega/qga-watchdog.env
ExecStart=${WD_BIN}
EOF
cat >/etc/systemd/system/omega-qga-watchdog.timer <<EOF
[Unit]
Description=Run Omega QGA watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now omega-qga-watchdog.timer
systemctl start omega-qga-watchdog.service || true
systemctl --no-pager --full status omega-qga-watchdog.timer | sed -n '1,12p'"
done
