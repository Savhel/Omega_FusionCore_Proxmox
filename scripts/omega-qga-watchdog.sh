#!/usr/bin/env bash
# Omega QGA watchdog: detecte et repare automatiquement qemu-guest-agent
# pour les VMs Omega locales d'un noeud Proxmox.
set -euo pipefail

: "${OMEGA_QGA_WATCHDOG_VMIDS:=}"              # vide = VMs locales tagguees omega
: "${OMEGA_QGA_WATCHDOG_ROOT_PASSWORD:=root}"
: "${OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD:=3}"
: "${OMEGA_QGA_WATCHDOG_RESET_STUCK:=0}"       # 1 = reset VM apres seuil si aucune IP/SSH
: "${OMEGA_QGA_WATCHDOG_LOG:=/var/log/omega/qga-watchdog.log}"
: "${OMEGA_QGA_WATCHDOG_STATE_DIR:=/var/lib/omega/qga-watchdog}"
: "${OMEGA_QGA_WATCHDOG_SSH_USER:=root}"

mkdir -p "$(dirname "$OMEGA_QGA_WATCHDOG_LOG")" "$OMEGA_QGA_WATCHDOG_STATE_DIR"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$OMEGA_QGA_WATCHDOG_LOG"; }

have() { command -v "$1" >/dev/null 2>&1; }

vmids_to_scan() {
    if [[ -n "$OMEGA_QGA_WATCHDOG_VMIDS" ]]; then
        tr ',' '\n' <<<"$OMEGA_QGA_WATCHDOG_VMIDS" | awk 'NF'
        return
    fi
    qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vmid; do
        cfg="$(qm config "$vmid" 2>/dev/null || true)"
        printf '%s\n' "$cfg" | grep -q '^template: 1' && continue
        tags="$(printf '%s\n' "$cfg" | sed -n 's/^tags: //p')"
        desc="$(printf '%s\n' "$cfg" | sed -n 's/^description: //p')"
        if printf '%s\n%s\n' "$tags" "$desc" | grep -Eq '(^|[;, ])omega([;, ]|$)|omega_'; then
            echo "$vmid"
        fi
    done
}

qga_ok() {
    local vmid="$1"
    qm guest cmd "$vmid" ping >/dev/null 2>&1 || qm agent "$vmid" ping >/dev/null 2>&1
}

vm_status() {
    qm status "$1" 2>/dev/null | awk '{print $2}'
}

vm_mac() {
    qm config "$1" 2>/dev/null | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p' | head -1 | tr 'A-F' 'a-f'
}

vm_ip_from_neigh() {
    local mac="$1"
    [[ -n "$mac" ]] || return 1
    ip neigh | awk -v mac="$mac" 'tolower($0) ~ mac && $1 !~ /^fe80/ && $1 !~ /^169\.254\./ {print $1; exit}'
}

failure_file() { printf '%s/%s.failures\n' "$OMEGA_QGA_WATCHDOG_STATE_DIR" "$1"; }

failure_count() {
    local f; f="$(failure_file "$1")"
    [[ -s "$f" ]] && cat "$f" || echo 0
}

set_failure_count() {
    printf '%s\n' "$2" >"$(failure_file "$1")"
}

clear_failure() {
    rm -f "$(failure_file "$1")"
}

install_guest_repair() {
    local vmid="$1" ip="$2" pass_q
    have sshpass || { log "vm=$vmid qga=bad action=skip reason=sshpass_absent"; return 1; }
    printf -v pass_q '%q' "$OMEGA_QGA_WATCHDOG_ROOT_PASSWORD"
    sshpass -p "$OMEGA_QGA_WATCHDOG_ROOT_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 \
        "${OMEGA_QGA_WATCHDOG_SSH_USER}@${ip}" 'bash -s' <<'GUEST'
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y qemu-guest-agent openssh-server
fi
install -d -m 0755 /usr/local/sbin /etc/systemd/system /etc/ssh/sshd_config.d
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

scan_one() {
    local vmid="$1" status cfg agent mac ip failures
    status="$(vm_status "$vmid" || true)"
    [[ "$status" == "running" ]] || { clear_failure "$vmid"; return 0; }

    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    agent="$(printf '%s\n' "$cfg" | sed -n 's/^agent: //p')"
    if [[ "$agent" != *enabled=1* && "$agent" != "1" ]]; then
        qm set "$vmid" --agent enabled=1 >/dev/null 2>&1 || true
        log "vm=$vmid action=enable-proxmox-agent"
    fi

    if qga_ok "$vmid"; then
        clear_failure "$vmid"
        log "vm=$vmid qga=ok"
        return 0
    fi

    failures="$(( $(failure_count "$vmid") + 1 ))"
    set_failure_count "$vmid" "$failures"
    mac="$(vm_mac "$vmid")"
    ip="$(vm_ip_from_neigh "$mac" || true)"
    log "vm=$vmid qga=bad failures=$failures ip=${ip:-none} action=repair-attempt"

    if [[ -n "$ip" ]] && install_guest_repair "$vmid" "$ip"; then
        sleep 3
        if qga_ok "$vmid"; then
            clear_failure "$vmid"
            log "vm=$vmid qga=repaired ip=$ip"
            return 0
        fi
        log "vm=$vmid qga=still-bad-after-repair ip=$ip"
    fi

    if [[ "$OMEGA_QGA_WATCHDOG_RESET_STUCK" == "1" && "$failures" -ge "$OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD" ]]; then
        log "vm=$vmid action=reset reason=qga_stuck failures=$failures"
        qm reset "$vmid" >/dev/null 2>&1 || qm reboot "$vmid" >/dev/null 2>&1 || true
        set_failure_count "$vmid" 0
    fi
}

main() {
    have qm || { log "qm absent; watchdog ignored"; exit 0; }
    mapfile -t vmids < <(vmids_to_scan)
    [[ "${#vmids[@]}" -gt 0 ]] || { log "no omega vm local"; exit 0; }
    for vmid in "${vmids[@]}"; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        scan_one "$vmid" || log "vm=$vmid action=scan-error"
    done
}

main "$@"
