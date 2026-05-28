#!/usr/bin/env bash
# Repair qemu-guest-agent persistence in Omega Proxmox VMs.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/repair-qga-vms-remote.sh --controller HOST --vmids A,B,C [options]

Options:
  --controller HOST       Proxmox node reachable by SSH. Required.
  --user USER             SSH user for Proxmox nodes. Default: root.
  --vmids CSV             VMIDs to repair. Required.
  --root-password PASS    Guest root password for SSH fallback. Default: root.
  --reboot-check          Reboot each repaired VM and verify QGA comes back.
  --wait SECS             Wait for QGA/IP. Default: 120.
EOF
}

fail() { echo "ERREUR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

CONTROLLER=""
DEPLOY_USER="root"
VMIDS=""
ROOT_PASSWORD="root"
REBOOT_CHECK=0
WAIT_SECS=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller) CONTROLLER="$2"; shift 2 ;;
        --user) DEPLOY_USER="$2"; shift 2 ;;
        --vmids) VMIDS="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --reboot-check) REBOOT_CHECK=1; shift ;;
        --wait) WAIT_SECS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$CONTROLLER" ]] || fail "--controller requis"
[[ -n "$VMIDS" ]] || fail "--vmids requis"
[[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || fail "--wait doit etre numerique"

REMOTE="${DEPLOY_USER}@${CONTROLLER}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

ssh_remote() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }
ssh_node() {
    local node="$1"; shift
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${node}" "$@"
}

vm_node_name() {
    local vmid="$1"
    ssh_remote "pvesh get /cluster/resources --type vm --output-format json" | \
        python3 -c 'import json,sys; v=int(sys.argv[1]); print(next((x.get("node","") for x in json.load(sys.stdin) if x.get("vmid")==v),""))' "$vmid"
}

node_addr() {
    local node="$1" resolved
    resolved="$(ssh_remote "getent hosts '$node' | awk '{print \$1; exit}'" 2>/dev/null || true)"
    printf '%s\n' "${resolved:-$node}"
}

qga_ok() {
    local node="$1" vmid="$2"
    ssh_node "$node" "qm guest cmd '$vmid' ping >/dev/null 2>&1 || qm agent '$vmid' ping >/dev/null 2>&1"
}

wait_qga() {
    local node="$1" vmid="$2" end=$((SECONDS + WAIT_SECS))
    while (( SECONDS < end )); do
        if qga_ok "$node" "$vmid"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

guest_ip() {
    local node="$1" vmid="$2"
    ssh_node "$node" "if qm guest cmd '$vmid' ping >/dev/null 2>&1 || qm agent '$vmid' ping >/dev/null 2>&1; then
qm guest cmd '$vmid' network-get-interfaces 2>/dev/null || qm agent '$vmid' network-get-interfaces 2>/dev/null || true
else
true
fi" | python3 -c 'import json,sys
text=sys.stdin.read()
try:
    data=json.loads(text) if text.strip() else []
except Exception:
    data=[]
for iface in data:
    for addr in iface.get("ip-addresses", []):
        ip=addr.get("ip-address", "")
        if addr.get("ip-address-type") == "ipv4" and not ip.startswith(("127.", "169.254.")):
            print(ip); raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null && return 0

    ssh_node "$node" "mac=\$(qm config '$vmid' 2>/dev/null | sed -n 's/^net0: virtio=\\([^,]*\\).*/\\1/p' | head -1 | tr 'A-F' 'a-f');
[ -n \"\$mac\" ] || exit 1;
ip neigh | awk -v mac=\"\$mac\" 'tolower(\$0) ~ mac && \$1 !~ /^fe80/ {print \$1; exit}'" 2>/dev/null
}

install_guest_repair() {
    local node="$1" vmid="$2" ip="$3" pass_q
    printf -v pass_q '%q' "$ROOT_PASSWORD"
    info "VM $vmid: installation persistante QGA via SSH root@$ip"
    ssh_node "$node" "command -v sshpass >/dev/null 2>&1" || fail "sshpass absent sur $node; installer sshpass ou fournir une image avec SSH/QGA"
    ssh_node "$node" "sshpass -p $pass_q ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@'$ip' 'bash -s'" <<'GUEST'
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y qemu-guest-agent stress-ng openssh-server
fi
install -d -m 0755 /etc/ssh/sshd_config.d /usr/local/sbin /etc/systemd/system
cat >/etc/ssh/sshd_config.d/99-omega-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
cat >/usr/local/sbin/omega-qga-ensure <<'EOF'
#!/bin/sh
LOG=/var/log/omega-qga-ensure.log
{
echo "=== omega-qga-ensure $(date) ==="
if ! command -v qemu-ga >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update 2>/dev/null && apt-get install -y qemu-guest-agent 2>/dev/null || true
fi
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl enable qemu-guest-agent.service 2>/dev/null || true
systemctl enable qemu-guest-agent.socket 2>/dev/null || true
i=0
while [ "$i" -lt 30 ]; do
    if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
        systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
        systemctl start qemu-guest-agent.socket 2>/dev/null || true
        break
    fi
    i=$((i+1))
    sleep 2
done
systemctl is-active qemu-guest-agent 2>/dev/null && echo "qemu-guest-agent ACTIF" || echo "qemu-guest-agent INACTIF"
} >>"$LOG" 2>&1
EOF
chmod 0755 /usr/local/sbin/omega-qga-ensure
cat >/etc/systemd/system/omega-qga-ensure.service <<'EOF'
[Unit]
Description=Omega - garantit qemu-guest-agent actif a chaque boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/omega-qga-ensure
RemainAfterExit=no
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl enable qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
systemctl enable --now omega-qga-ensure.service
systemctl is-active qemu-guest-agent
GUEST
}

IFS=',' read -r -a VMID_ARR <<< "$VMIDS"
for vmid in "${VMID_ARR[@]}"; do
    [[ -n "$vmid" ]] || continue
    [[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID invalide: $vmid"
    pve_node="$(vm_node_name "$vmid")"
    [[ -n "$pve_node" ]] || { warn "VM $vmid introuvable"; continue; }
    node="$(node_addr "$pve_node")"
    info "VM $vmid sur $pve_node/$node"
    ssh_node "$node" "qm set '$vmid' --agent enabled=1 >/dev/null; qm status '$vmid' | grep -q running || qm start '$vmid'" || warn "VM $vmid: start/config a signale une erreur"

    if wait_qga "$node" "$vmid"; then
        info "VM $vmid: QGA deja joignable"
    else
        warn "VM $vmid: QGA absent apres attente, tentative SSH"
    fi

    ip="$(guest_ip "$node" "$vmid" | head -1 || true)"
    if [[ -z "$ip" ]]; then
        warn "VM $vmid: aucune IP invite detectee; impossible de reparer depuis SSH"
        continue
    fi
    install_guest_repair "$node" "$vmid" "$ip" || { warn "VM $vmid: reparation invite echouee"; continue; }
    wait_qga "$node" "$vmid" || { warn "VM $vmid: QGA toujours absent apres reparation"; continue; }
    info "VM $vmid: QGA OK apres reparation"

    if (( REBOOT_CHECK )); then
        info "VM $vmid: reboot de validation"
        ssh_node "$node" "qm reboot '$vmid' >/dev/null 2>&1 || qm reset '$vmid' >/dev/null"
        sleep 10
        if wait_qga "$node" "$vmid"; then
            info "VM $vmid: QGA OK apres reboot"
        else
            warn "VM $vmid: QGA absent apres reboot"
        fi
    fi
done
