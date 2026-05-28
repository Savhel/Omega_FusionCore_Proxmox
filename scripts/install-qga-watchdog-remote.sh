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
EOF
}

fail() { echo "ERREUR: $*" >&2; exit 1; }
NODES=""
USER="root"
ROOT_PASSWORD="root"
VMIDS=""
RESET_STUCK="0"
INTERVAL="60"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes) NODES="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --vmids) VMIDS="$2"; shift 2 ;;
        --reset-stuck) RESET_STUCK="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done
[[ -n "$NODES" ]] || fail "--nodes requis"
[[ "$RESET_STUCK" =~ ^[01]$ ]] || fail "--reset-stuck doit valoir 0 ou 1"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || fail "--interval doit etre numerique"

IFS=',' read -r -a NODE_ARR <<< "$NODES"
for node in "${NODE_ARR[@]}"; do
    [[ -n "$node" ]] || continue
    echo "[INFO] installation omega-qga-watchdog sur $node"
    ssh -o StrictHostKeyChecking=accept-new "${USER}@${node}" 'install -d -m 0755 /usr/local/sbin /etc/omega /etc/systemd/system /var/log/omega /var/lib/omega/qga-watchdog'
    scp -o StrictHostKeyChecking=accept-new scripts/omega-qga-watchdog.sh "${USER}@${node}:/usr/local/sbin/omega-qga-watchdog"
    ssh -o StrictHostKeyChecking=accept-new "${USER}@${node}" "chmod 0755 /usr/local/sbin/omega-qga-watchdog
cat >/etc/omega/qga-watchdog.env <<EOF
OMEGA_QGA_WATCHDOG_ROOT_PASSWORD=${ROOT_PASSWORD}
OMEGA_QGA_WATCHDOG_VMIDS=${VMIDS}
OMEGA_QGA_WATCHDOG_RESET_STUCK=${RESET_STUCK}
OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD=3
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
ExecStart=/usr/local/sbin/omega-qga-watchdog
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
