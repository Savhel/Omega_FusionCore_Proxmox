#!/usr/bin/env bash
# Test 37 — Puissance Omega sur flotte physique.
#
# Objectif:
#   - utiliser 40-50 VMs simultanément pour RAM, CPU, DISK, GPU et migrations;
#   - comparer une tâche sur hôte physique puis dans une VM;
#   - lancer un chaos live sur jusqu'à 75 VMs: start/stop aléatoires + travaux;
#   - observer les métriques Omega/Proxmox sans supposer un nom de nœud.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

VMIDS_SPEC="${1:-${OMEGA_FLEET_VMIDS:-${OMEGA_SCALE_VMIDS:-${OMEGA_TEST_VMIDS:-$TEST_VMID}}}}"
FLEET_COUNT="${2:-${OMEGA_FLEET_VM_COUNT:-50}}"
CHAOS_COUNT="${3:-${OMEGA_FLEET_CHAOS_VM_COUNT:-75}}"
DURATION_SECS="${4:-${OMEGA_FLEET_DURATION_SECS:-900}}"
PHASE_SECS="${OMEGA_FLEET_PHASE_SECS:-180}"
BATCH_SIZE="${OMEGA_FLEET_BATCH_SIZE:-10}"
MIGRATION_COUNT="${OMEGA_FLEET_MIGRATIONS:-12}"
GPU_VM_COUNT="${OMEGA_FLEET_GPU_VM_COUNT:-12}"
GPU_JOB_N="${OMEGA_FLEET_GPU_JOB_N:-1024}"
GPU_JOB_VRAM_MIB="${OMEGA_FLEET_GPU_JOB_VRAM_MIB:-256}"
REPORT_PATH="${OMEGA_FLEET_REPORT:-/tmp/omega-fleet-power-$(date -u +%Y%m%dT%H%M%SZ).json}"
TMP_DIR="$(mktemp -d /tmp/omega-fleet-power.XXXXXX)"
_TMPFILES+=("$TMP_DIR")

header "Test 37 — Puissance Omega flotte (${FLEET_COUNT} VMs charge, ${CHAOS_COUNT} VMs chaos)"

require_cluster
require_bin python3
require_bin curl

expand_vmids() {
    local spec="$1" part start end i
    tr ',' '\n' <<< "$spec" | while read -r part; do
        [[ -n "$part" ]] || continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if [[ "$start" -le "$end" ]]; then
                for ((i=start; i<=end; i++)); do printf '%s\n' "$i"; done
            else
                for ((i=start; i>=end; i--)); do printf '%s\n' "$i"; done
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$part"
        fi
    done
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'
}

metric_snapshot() {
    local label="$1" out="$2" node
    {
        printf '{"label":%s,"ts":%s,"nodes":[' "$(printf '%s' "$label" | json_escape)" "$(date +%s)"
        first=1
        for node in "${OMEGA_NODES_ARR[@]}"; do
            status="$(curl -fsS --max-time 5 "http://${node}:9300/control/status" 2>/dev/null || true)"
            store="$(curl -fsS --max-time 5 "http://${node}:${STATUS_PORT}/status" 2>/dev/null || true)"
            [[ -n "$status" ]] || status='{}'
            [[ -n "$store" ]] || store='{}'
            [[ "$first" == 1 ]] || printf ','
            first=0
            printf '{"node":%s,"omega":%s,"store":%s}' \
                "$(printf '%s' "$node" | json_escape)" "$status" "$store"
        done
        printf ']}\n'
    } >> "$out"
}

seconds_float() {
    python3 - "$1" "$2" <<'PY'
import sys
print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000:.3f}")
PY
}

elapsed_py='import sys; print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000:.3f}")'

guest_run() {
    local vmid="$1"; shift
    guest_exec_wait "$vmid" bash -lc "$*"
}

guest_bg() {
    local vmid="$1"; shift
    guest_run "$vmid" "nohup $* >/tmp/omega-fleet-${vmid}.log 2>&1 &"
}

host_perf_cpu() {
    local node="$1"
    ssh_run "$node" "start=\$(date +%s%N); python3 - <<'PY'
x = 0
for i in range(12000000):
    x = (x * 1664525 + i + 1013904223) & 0xffffffff
print(x)
PY
end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\""
}

vm_perf_cpu() {
    local vmid="$1"
    guest_run "$vmid" "start=\$(date +%s%N); python3 - <<'PY'
x = 0
for i in range(12000000):
    x = (x * 1664525 + i + 1013904223) & 0xffffffff
print(x)
PY
end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\"" | tail -1
}

host_perf_ram() {
    local node="$1"
    ssh_run "$node" "start=\$(date +%s%N); python3 - <<'PY'
size = 256 * 1024 * 1024
b = bytearray(size)
for i in range(0, size, 4096):
    b[i] = (i // 4096) & 255
print(sum(b[::4096]))
PY
end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\""
}

vm_perf_ram() {
    local vmid="$1"
    guest_run "$vmid" "start=\$(date +%s%N); python3 - <<'PY'
size = 256 * 1024 * 1024
b = bytearray(size)
for i in range(0, size, 4096):
    b[i] = (i // 4096) & 255
print(sum(b[::4096]))
PY
end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\"" | tail -1
}

host_perf_disk() {
    local node="$1"
    ssh_run "$node" "f=/tmp/omega-host-disk-\$\$.bin; start=\$(date +%s%N); dd if=/dev/zero of=\$f bs=4M count=64 conv=fdatasync status=none; dd if=\$f of=/dev/null bs=4M status=none; rm -f \$f; end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\""
}

vm_perf_disk() {
    local vmid="$1"
    guest_run "$vmid" "f=/tmp/omega-vm-disk-\$\$.bin; start=\$(date +%s%N); dd if=/dev/zero of=\$f bs=4M count=64 conv=fdatasync status=none; dd if=\$f of=/dev/null bs=4M status=none; rm -f \$f; end=\$(date +%s%N); python3 -c '$elapsed_py' \"\$start\" \"\$end\"" | tail -1
}

gpu_token_header=()
GPU_JOB_IDS=()
GPU_NODES="${OMEGA_GPU_NODES:-${OMEGA_GPU_PRIMARY_NODE:-}}"
GPU_PRIMARY="${OMEGA_GPU_PRIMARY_NODE:-${GPU_NODES%%,*}}"
GPU_PROXY_URL="${OMEGA_GPU_PROXY_URL:-${GPU_PRIMARY:+http://${GPU_PRIMARY}:9400}}"
GPU_PROXY_URL="${GPU_PROXY_URL:-http://${CONTROLLER_NODE}:9400}"
if [[ -z "$GPU_PRIMARY" && "$GPU_PROXY_URL" =~ ^https?://([^/:]+) ]]; then
    GPU_PRIMARY="${BASH_REMATCH[1]}"
fi
GPU_TOKEN="${OMEGA_GPU_PROXY_API_TOKEN:-}"
if [[ -z "$GPU_TOKEN" && -n "${OMEGA_GPU_PROXY_API_TOKEN_FILE:-}" && -r "${OMEGA_GPU_PROXY_API_TOKEN_FILE}" ]]; then
    GPU_TOKEN="$(tr -d ' \n\r\t' < "${OMEGA_GPU_PROXY_API_TOKEN_FILE}")"
fi
[[ -n "$GPU_TOKEN" ]] && gpu_token_header=(-H "Authorization: Bearer ${GPU_TOKEN}")

host_perf_gpu() {
    local node="$1" n="${1:-}"
    [[ -n "$node" ]] || { printf '{"available":false,"error":"no_gpu_node"}\n'; return 0; }
    n="${OMEGA_FLEET_GPU_JOB_N:-1024}"
    ssh_run "$node" "set -a; [ -r /etc/omega/cluster.env ] && . /etc/omega/cluster.env; set +a; py=\${OMEGA_GPU_PYTHON:-}; [ -n \"\$py\" ] && [ -x \"\$py\" ] || py=/opt/omega-gpu-venv/bin/python; [ -x \"\$py\" ] || py=/opt/omega-remote-paging/gpu-venv/bin/python; [ -x \"\$py\" ] || py=python3; \"\$py\" - <<'PY'
import json, time
n = int('$n')
try:
    import torch
    if not torch.cuda.is_available():
        print(json.dumps({'available': False, 'backend': 'torch', 'cuda_available': False}))
        raise SystemExit(0)
    torch.cuda.synchronize()
    a = torch.randn((n, n), device='cuda')
    b = torch.randn((n, n), device='cuda')
    torch.cuda.synchronize()
    start = time.perf_counter()
    c = a @ b
    torch.cuda.synchronize()
    duration_ms = (time.perf_counter() - start) * 1000
    print(json.dumps({
        'available': True,
        'backend': 'torch',
        'device': 'cuda',
        'gpu_name': torch.cuda.get_device_name(0),
        'n': n,
        'duration_ms': round(duration_ms, 3),
        'checksum': float(c[0, 0].detach().cpu()),
    }))
except Exception as exc:
    print(json.dumps({'available': False, 'error': str(exc)}))
PY" 2>/dev/null || printf '{"available":false,"error":"ssh_or_python_failed"}\n'
}

gpu_submit_jobs() {
    local count="$1" vmid resp code body job_id
    GPU_JOB_IDS=()
    for vmid in "${FLEET_VMIDS[@]:0:$count}"; do
        curl -fsS "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/vm/${vmid}/budget" \
            -H "Content-Type: application/json" \
            -d "{\"vram_budget_mib\":$((GPU_JOB_VRAM_MIB * 2))}" >/dev/null
        resp="$(curl -sS -w '\n%{http_code}' "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/jobs" \
            -H "Content-Type: application/json" \
            -d "{\"vm_id\":${vmid},\"kind\":\"matrix_multiply\",\"vram_mib\":${GPU_JOB_VRAM_MIB},\"payload\":{\"n\":${GPU_JOB_N},\"seed\":${vmid},\"require_cuda\":true}}" || true)"
        code="$(printf '%s\n' "$resp" | tail -1)"
        body="$(printf '%s\n' "$resp" | sed '$d')"
        if [[ "$code" == 2* ]]; then
            job_id="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("job_id",""))' 2>/dev/null || true)"
            [[ -n "$job_id" ]] && GPU_JOB_IDS+=("$job_id")
        else
            warn "GPU job VM $vmid refusé: http=$code body=${body:-vide}"
        fi
    done
}

gpu_proxy_bench() {
    local vmid="$1" resp code body job_id result state deadline
    if ! curl -fsS "${gpu_token_header[@]}" "$GPU_PROXY_URL/health" >/dev/null 2>&1; then
        printf '{"available":false,"error":"proxy_unreachable"}\n'
        return 0
    fi
    curl -fsS "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/vm/${vmid}/budget" \
        -H "Content-Type: application/json" \
        -d "{\"vram_budget_mib\":$((GPU_JOB_VRAM_MIB * 2))}" >/dev/null || {
        printf '{"available":false,"error":"budget_rejected"}\n'
        return 0
    }
    resp="$(curl -sS -w '\n%{http_code}' "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/jobs" \
        -H "Content-Type: application/json" \
        -d "{\"vm_id\":${vmid},\"kind\":\"matrix_multiply\",\"vram_mib\":${GPU_JOB_VRAM_MIB},\"payload\":{\"n\":${GPU_JOB_N},\"seed\":${vmid},\"require_cuda\":true}}" || true)"
    code="$(printf '%s\n' "$resp" | tail -1)"
    body="$(printf '%s\n' "$resp" | sed '$d')"
    if [[ "$code" != 2* ]]; then
        printf '{"available":false,"error":"submit_rejected","http":%s}\n' "${code:-0}"
        return 0
    fi
    job_id="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("job_id",""))' 2>/dev/null || true)"
    [[ -n "$job_id" ]] || { printf '{"available":false,"error":"missing_job_id"}\n'; return 0; }
    deadline=$((SECONDS + ${OMEGA_FLEET_GPU_TIMEOUT_SECS:-600}))
    while [[ "$SECONDS" -lt "$deadline" ]]; do
        result="$(curl -fsS "${gpu_token_header[@]}" "$GPU_PROXY_URL/v1/jobs/$job_id" 2>/dev/null || true)"
        state="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
        if [[ "$state" == "succeeded" || "$state" == "failed" || "$state" == "cancelled" ]]; then
            printf '%s\n' "${result:-{\"available\":false,\"error\":\"empty_result\"}}"
            return 0
        fi
        sleep 1
    done
    printf '{"available":false,"error":"timeout","job_id":"%s"}\n' "$job_id"
}

gpu_wait_jobs() {
    local deadline=$((SECONDS + ${OMEGA_FLEET_GPU_TIMEOUT_SECS:-600}))
    local done_count state job_id result
    while [[ "$SECONDS" -lt "$deadline" ]]; do
        done_count=0
        for job_id in "${GPU_JOB_IDS[@]:-}"; do
            result="$(curl -fsS "${gpu_token_header[@]}" "$GPU_PROXY_URL/v1/jobs/$job_id" 2>/dev/null || true)"
            state="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
            case "$state" in
                succeeded) done_count=$((done_count + 1)) ;;
                failed|cancelled) warn "GPU job $job_id terminé en $state" ;;
            esac
        done
        [[ "$done_count" -eq "${#GPU_JOB_IDS[@]}" ]] && return 0
        sleep 2
    done
    return 1
}

step "Sélection des VMs"
mapfile -t ALL_VMIDS < <(expand_vmids "$VMIDS_SPEC")
[[ "${#ALL_VMIDS[@]}" -gt 0 ]] || fail "aucune VMID fournie"

EXISTING_VMIDS=()
for vmid in "${ALL_VMIDS[@]}"; do
    qm config "$vmid" >/dev/null 2>&1 && EXISTING_VMIDS+=("$vmid") || warn "VM $vmid absente"
done
[[ "${#EXISTING_VMIDS[@]}" -ge 40 ]] || fail "il faut au moins 40 VMs existantes, trouvées=${#EXISTING_VMIDS[@]}"

[[ "$FLEET_COUNT" -le "${#EXISTING_VMIDS[@]}" ]] || FLEET_COUNT="${#EXISTING_VMIDS[@]}"
[[ "$CHAOS_COUNT" -le "${#EXISTING_VMIDS[@]}" ]] || CHAOS_COUNT="${#EXISTING_VMIDS[@]}"
FLEET_VMIDS=("${EXISTING_VMIDS[@]:0:$FLEET_COUNT}")
CHAOS_VMIDS=("${EXISTING_VMIDS[@]:0:$CHAOS_COUNT}")
info "VMs charge: ${#FLEET_VMIDS[@]} (${FLEET_VMIDS[0]}..${FLEET_VMIDS[-1]})"
info "VMs chaos : ${#CHAOS_VMIDS[@]} (${CHAOS_VMIDS[0]}..${CHAOS_VMIDS[-1]})"

step "Préparation: démarrage + QGA + stress-ng"
idx=0
for vmid in "${FLEET_VMIDS[@]}"; do
    require_vm_running "$vmid"
    if guest_agent_ready "$vmid"; then
        ensure_guest_packages "$vmid" stress-ng qemu-guest-agent >/dev/null || warn "VM $vmid: stress-ng/QGA non vérifié"
    else
        warn "VM $vmid: QGA absent, cette VM sera ignorée pour les charges invitées"
    fi
    idx=$((idx + 1))
    [[ $((idx % BATCH_SIZE)) -eq 0 ]] && info "préparation $idx/${#FLEET_VMIDS[@]}"
done

SNAPSHOTS="$TMP_DIR/snapshots.jsonl"
: > "$SNAPSHOTS"
metric_snapshot "start" "$SNAPSHOTS"

step "Benchmark host vs VM"
BENCH_VM="${FLEET_VMIDS[0]}"
BENCH_NODE="$(vm_node "$BENCH_VM")"
HOST_CPU="$(host_perf_cpu "$BENCH_NODE" | tail -1 || echo null)"
VM_CPU="$(vm_perf_cpu "$BENCH_VM" || echo null)"
HOST_RAM="$(host_perf_ram "$BENCH_NODE" | tail -1 || echo null)"
VM_RAM="$(vm_perf_ram "$BENCH_VM" || echo null)"
HOST_DISK="$(host_perf_disk "$BENCH_NODE" | tail -1 || echo null)"
VM_DISK="$(vm_perf_disk "$BENCH_VM" || echo null)"
HOST_GPU_FILE="$TMP_DIR/host_gpu.json"
PROXY_GPU_FILE="$TMP_DIR/proxy_gpu.json"
host_perf_gpu "$GPU_PRIMARY" > "$HOST_GPU_FILE"
gpu_proxy_bench "$BENCH_VM" > "$PROXY_GPU_FILE"
info "CPU secondes host=${HOST_CPU} vm=${VM_CPU}"
info "RAM secondes host=${HOST_RAM} vm=${VM_RAM}"
info "DISK secondes host=${HOST_DISK} vm=${VM_DISK}"
info "GPU direct hôte: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("duration_ms", d.get("error", "n/a")))' "$HOST_GPU_FILE" 2>/dev/null || echo n/a)"
info "GPU via proxy : $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); out=d.get("result",{}).get("output",{}); print(out.get("duration_ms", d.get("error", "n/a")))' "$PROXY_GPU_FILE" 2>/dev/null || echo n/a)"

step "Phase CPU (${PHASE_SECS}s, ${#FLEET_VMIDS[@]} VMs)"
for vmid in "${FLEET_VMIDS[@]}"; do
    guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --cpu 0 --timeout ${PHASE_SECS}s"
done
sleep "$PHASE_SECS"
metric_snapshot "after_cpu" "$SNAPSHOTS"

step "Phase RAM (${PHASE_SECS}s, ${#FLEET_VMIDS[@]} VMs)"
for vmid in "${FLEET_VMIDS[@]}"; do
    guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --vm 1 --vm-bytes 70% --timeout ${PHASE_SECS}s"
done
sleep "$PHASE_SECS"
metric_snapshot "after_ram" "$SNAPSHOTS"

step "Phase DISK (${PHASE_SECS}s, ${#FLEET_VMIDS[@]} VMs)"
for vmid in "${FLEET_VMIDS[@]}"; do
    guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --hdd 1 --hdd-bytes 512M --timeout ${PHASE_SECS}s"
done
sleep "$PHASE_SECS"
metric_snapshot "after_disk" "$SNAPSHOTS"

step "Phase GPU proxy (${GPU_VM_COUNT} jobs CUDA max)"
if curl -fsS "${gpu_token_header[@]}" "$GPU_PROXY_URL/health" >/dev/null 2>&1; then
    [[ "$GPU_VM_COUNT" -le "${#FLEET_VMIDS[@]}" ]] || GPU_VM_COUNT="${#FLEET_VMIDS[@]}"
    gpu_submit_jobs "$GPU_VM_COUNT"
    info "GPU jobs soumis: ${#GPU_JOB_IDS[@]}"
    gpu_wait_jobs || warn "certains jobs GPU n'ont pas terminé avant timeout"
else
    warn "proxy GPU indisponible: $GPU_PROXY_URL"
fi
metric_snapshot "after_gpu" "$SNAPSHOTS"

step "Phase migrations sous charge (${MIGRATION_COUNT} migrations)"
for vmid in "${FLEET_VMIDS[@]:0:$MIGRATION_COUNT}"; do
    guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --cpu 1 --vm 1 --vm-bytes 50% --timeout 240s" || true
    src="$(vm_node "$vmid" || true)"
    target="$(
        for n in "${OMEGA_NODES_ARR[@]}"; do
            [[ "$n" != "$src" ]] && printf '%s\n' "$n"
        done | shuf | head -1
    )"
    [[ -n "$target" ]] || continue
    target_pve="$(_ip_to_pve_node "$target")"
    qm config "$vmid" 2>/dev/null | grep "media=cdrom" | cut -d: -f1 | while read -r drv; do
        [[ -n "$drv" ]] && qm set "$vmid" "--${drv}" none >/dev/null 2>&1 || true
    done
    info "migration VM $vmid: ${src:-?} -> $target ($target_pve)"
    if ! qm migrate "$vmid" "$target_pve" --online >/tmp/omega-fleet-migrate-"$vmid".log 2>&1; then
        warn "migration VM $vmid échouée: $(tail -20 /tmp/omega-fleet-migrate-"$vmid".log | tr '\n' ' ' | cut -c1-240)"
    fi
done
metric_snapshot "after_migrations" "$SNAPSHOTS"

step "Chaos live (${DURATION_SECS}s): start/stop aléatoire + travaux mixtes"
end=$((SECONDS + DURATION_SECS))
ops=0
while [[ "$SECONDS" -lt "$end" ]]; do
    vmid="${CHAOS_VMIDS[$((RANDOM % ${#CHAOS_VMIDS[@]}))]}"
    action=$((RANDOM % 6))
    case "$action" in
        0)
            qm stop "$vmid" >/dev/null 2>&1 || true
            ;;
        1)
            _try_start_vm "$vmid" >/dev/null 2>&1 || true
            ;;
        2)
            guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --cpu 1 --timeout 90s" || true
            ;;
        3)
            guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --vm 1 --vm-bytes 65% --timeout 90s" || true
            ;;
        4)
            guest_agent_ready "$vmid" && guest_bg "$vmid" "stress-ng --hdd 1 --hdd-bytes 256M --timeout 90s" || true
            ;;
        5)
            if curl -fsS "${gpu_token_header[@]}" "$GPU_PROXY_URL/health" >/dev/null 2>&1; then
                curl -fsS "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/vm/${vmid}/budget" \
                    -H "Content-Type: application/json" \
                    -d "{\"vram_budget_mib\":$((GPU_JOB_VRAM_MIB * 2))}" >/dev/null 2>&1 || true
                curl -fsS "${gpu_token_header[@]}" -X POST "$GPU_PROXY_URL/v1/jobs" \
                    -H "Content-Type: application/json" \
                    -d "{\"vm_id\":${vmid},\"kind\":\"matrix_multiply\",\"vram_mib\":${GPU_JOB_VRAM_MIB},\"payload\":{\"n\":${GPU_JOB_N},\"seed\":${vmid},\"require_cuda\":true}}" >/dev/null 2>&1 || true
            fi
            ;;
    esac
    ops=$((ops + 1))
    [[ $((ops % 20)) -eq 0 ]] && metric_snapshot "chaos_ops_${ops}" "$SNAPSHOTS"
    sleep "${OMEGA_FLEET_CHAOS_INTERVAL_SECS:-5}"
done
metric_snapshot "end" "$SNAPSHOTS"

step "Rapport"
python3 - "$REPORT_PATH" "$SNAPSHOTS" "$HOST_GPU_FILE" "$PROXY_GPU_FILE" <<PY
import json, pathlib, sys
report = pathlib.Path(sys.argv[1])
snapshots = []
for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    try:
        snapshots.append(json.loads(line))
    except Exception:
        pass
data = {
    "fleet_count": ${#FLEET_VMIDS[@]},
    "chaos_count": ${#CHAOS_VMIDS[@]},
    "duration_secs": $DURATION_SECS,
    "phase_secs": $PHASE_SECS,
    "migration_count": $MIGRATION_COUNT,
    "bench_vm": $BENCH_VM,
    "bench_node": "$BENCH_NODE",
    "bench_seconds": {
        "host_cpu": "$HOST_CPU",
        "vm_cpu": "$VM_CPU",
        "host_ram": "$HOST_RAM",
        "vm_ram": "$VM_RAM",
        "host_disk": "$HOST_DISK",
        "vm_disk": "$VM_DISK",
    },
    "bench_gpu_host_direct": json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")),
    "bench_gpu_proxy": json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")),
    "gpu_proxy_url": "$GPU_PROXY_URL",
    "gpu_jobs_submitted": ${#GPU_JOB_IDS[@]},
    "chaos_ops": $ops,
    "snapshots": snapshots,
}
report.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
print(report)
PY

pass "Fleet Omega power terminé: rapport=${REPORT_PATH}, VMs charge=${#FLEET_VMIDS[@]}, chaos_ops=${ops}"
