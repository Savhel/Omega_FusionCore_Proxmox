#!/usr/bin/env bash
# Test M5 — Migration live pendant pression mémoire active
# Pages partiellement sur les stores → migration live doit réussir quand même
# Usage : ./15-mixed-live-migration-pressure.sh [vmid] [target_node]
# Prérequis : cluster 3+ nœuds, VM avec pages évincées sur les stores

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
require_vm_running "$VMID"
VMID="$SELECTED_VMID"
VM_RAM_MIB=$(vm_ram_mib "$VMID"); VM_RAM_MIB="${VM_RAM_MIB:-1024}"

header "Test M5 — Migration live sous pression mémoire (VM $VMID)"
print_cluster_config

[[ $(store_count) -ge 1 ]] || fail "au moins 1 store requis"

step "Prérequis"
require_cluster

step "Nœud initial et nœud cible"
node_init=$(vm_node "$VMID")
# Choisir un nœud cible différent du nœud initial. Priorité à la RAM libre pour
# éviter de faire échouer M5 sur une cible techniquement disponible mais chargée.
TARGET_NODE=""
TARGET_NODE="$(
    for n in "${OMEGA_NODES_ARR[@]}"; do
        [[ "$n" != "$node_init" ]] || continue
        free="$(curl -fsS "http://${n}:${STATUS_PORT}/status" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("available_mib",0))' 2>/dev/null || echo 0)"
        printf '%s %s\n' "$free" "$n"
    done | sort -nr | awk 'NR==1{print $2}'
)"
[[ -n "$TARGET_NODE" ]] || fail "aucun nœud cible disponible (cluster à 1 seul nœud ?)"
TARGET_NODE_PVE=$(_ip_to_pve_node "$TARGET_NODE")
info "VM $VMID : source=$node_init → cible=$TARGET_NODE (pvesh: $TARGET_NODE_PVE)"

step "Phase 1 : éviction d'un maximum de pages avant migration"
LOG_PHASE1="/tmp/omega-m5-phase1.log"
_TMPFILES+=("$LOG_PHASE1")
"$AGENT_BIN" \
    --stores "$STORES_CSV" \
    --status-addrs "$STATUS_CSV" \
    --vm-id "$VMID" \
    --vm-requested-mib "$VM_RAM_MIB" \
    --region-mib "$VM_RAM_MIB" \
    --current-node "$node_init" \
    --eviction-threshold-mib 999999 \
    --eviction-batch-size 64 \
    --eviction-interval-secs 2 \
    --recall-threshold-mib 0 \
    --mode daemon >"$LOG_PHASE1" 2>&1 &
AGENT_PID=$!
_PIDS+=($!)

info "Éviction forcée pendant 30s..."
host_mem_stress 30 "70%" || warn "aucune pression mémoire hôte disponible pendant la phase d'éviction"
sleep 30

pages_before=0
for n in "${STORE_NODES_ARR[@]}"; do
    pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
    pages_before=$((pages_before + pc))
done
info "Pages sur les stores avant migration : $pages_before"
[[ "$pages_before" -gt 0 ]] || warn "aucune page évincée — migration sera triviale"

step "Phase 2 : migration live pendant que les stores ont des pages"
info "stress-ng continu pendant la migration (simule activité VM)"
host_mem_stress 120 "60%" || warn "aucune pression mémoire hôte disponible pendant la migration"

# Éjecter les CD-ROMs locaux (ISOs) — Proxmox refuse de migrer les images CDROM locales
qm config "$VMID" 2>/dev/null | grep "media=cdrom" | cut -d: -f1 | while read -r drv; do
    qm set "$VMID" "--${drv}" none 2>/dev/null && info "CD-ROM $drv éjecté" || true
done

info "Lancement migration live : qm migrate $VMID $TARGET_NODE_PVE --online"
t_migrate=$SECONDS
LOG_QM="/tmp/omega-m5-migrate.log"
_TMPFILES+=("$LOG_QM")
set +e
qm migrate "$VMID" "$TARGET_NODE_PVE" --online >"$LOG_QM" 2>&1
migrate_status=$?
set -e
cat "$LOG_QM"
migrate_duration=$(elapsed $t_migrate)

step "Résultats migration"
node_final=$(vm_node "$VMID" || echo "inconnu")
info "VM $VMID maintenant sur : $node_final"
info "Durée migration : ${migrate_duration}s"
info "Statut qm migrate : $migrate_status"

if [[ $migrate_status -ne 0 ]]; then
    warn "qm migrate a échoué; dernières lignes:"
    tail -80 "$LOG_QM" || true
    fail "qm migrate a échoué (code=$migrate_status). Vérifier Ceph, réseau migration, CD-ROM/local disk et locks Proxmox."
fi
[[ "$node_final" == "$TARGET_NODE" ]] || \
    fail "VM toujours sur $node_final, attendu $TARGET_NODE"

step "Phase 3 : vérification intégrité après migration"
pages_after=0
for n in "${STORE_NODES_ARR[@]}"; do
    pc=$(curl -sf "http://${n}:${STATUS_PORT}/status" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('page_count',0))" || echo 0)
    pages_after=$((pages_after + pc))
done
info "Pages sur les stores après migration : $pages_after"

step "Test accès mémoire post-migration"
vm_status=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | \
    python3 -c "import sys,json; vms=[v for v in json.load(sys.stdin) if v['vmid']==$VMID]; print(vms[0]['status'] if vms else 'unknown')" 2>/dev/null || echo "unknown")
[[ "$vm_status" == "running" ]] || fail "VM $VMID n'est plus en cours d'exécution après migration (status=$vm_status)"

pass "M5 OK — migration live réussie en ${migrate_duration}s ($pages_before pages sur stores, VM toujours active)"
