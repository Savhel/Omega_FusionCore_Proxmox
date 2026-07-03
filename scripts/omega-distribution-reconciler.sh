#!/usr/bin/env bash
# Omega distribution reconciler : maintient EN CONTINU la répartition cible des VMs
# omega par nœud (ex. 1 Emilia / 2 Ram / 2 Rem), SANS intervention humaine.
#
# Norme Omega : un agent maintient l'état désiré tout seul. Cet agent est CLUSTER-GLOBAL
# (la répartition est une décision globale, contrairement au qga-watchdog qui est par-nœud).
# Il tourne sur le nœud contrôleur (timer systemd) et, à chaque tick :
#   1. lit la politique de quotas (OMEGA_VM_NODE_DISTRIBUTION, mêmes valeurs que [p]) ;
#   2. compte les VMs omega VIVANTES par nœud (tag 'omega', hors templates/infra) ;
#   3. calcule la cible par nœud (greedy identique au provisioning : converge vers
#      1/2/2 quand la flotte = 5 ; en sur-effectif, répartit l'excédent à parts égales
#      → emilia reste le plus léger) ;
#   4. live-migre AU PLUS N VM par tick d'un nœud au-dessus de sa cible vers un nœud
#      en-dessous. JAMAIS de suppression (périmètre agent Omega : on migre, on ne détruit
#      pas). Stockage partagé Ceph → migration à chaud quasi instantanée.
#
# Idempotent : si la distribution est déjà conforme, ne fait rien.
set -euo pipefail

# ── Configuration (overridable par env / cluster.conf) ───────────────────────
: "${OMEGA_VM_NODE_DISTRIBUTION:=}"            # "IP_ou_nom:max,IP_ou_nom:max,..."
: "${OMEGA_VM_NODE_DEFAULT_MAX:=2}"            # quota des nœuds absents de la liste
: "${OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK:=1}"  # rafale max par tick (anti-storm)
: "${OMEGA_RECONCILE_PIN_VMIDS:=}"            # VMID à NE jamais migrer (liste, séparée par , ou espace)
: "${OMEGA_RECONCILE_ONLY_TAG:=omega}"        # tag identifiant une VM omega
# Nœuds GÉRÉS (allowlist KVM). Vide = déduit des clés de OMEGA_VM_NODE_DISTRIBUTION.
# Empêche toute migration vers un nœud nested no-KVM (BLADE/Bris/GENESIS/gandal).
: "${OMEGA_RECONCILE_NODES:=}"
: "${OMEGA_RECONCILE_LOG:=/var/log/omega/distribution-reconciler.log}"
: "${OMEGA_RECONCILE_DRY_RUN:=0}"             # 1 = n'exécute pas les migrations, log seulement
: "${OMEGA_RECONCILE_MIGRATE_TIMEOUT_SECS:=600}"  # réseau lent : une migration ~2min, marge x3

DRY_RUN="$OMEGA_RECONCILE_DRY_RUN"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --once) : ;;  # exécution unique (défaut ; le timer rappelle)
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Option inconnue: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$OMEGA_RECONCILE_LOG")"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$OMEGA_RECONCILE_LOG"; }
have() { command -v "$1" >/dev/null 2>&1; }

have pvesh || { log "ERREUR: pvesh absent — ce script doit tourner sur un nœud Proxmox"; exit 1; }
have qm    || { log "ERREUR: qm absent — ce script doit tourner sur un nœud Proxmox"; exit 1; }

# Normalise la liste des VMID pinnés (virgules/espaces → set).
declare -A PINNED=()
for v in ${OMEGA_RECONCILE_PIN_VMIDS//,/ }; do [[ -n "$v" ]] && PINNED[$v]=1; done

# ── Moteur de décision (Python) : vue cluster globale → émet "MIGRATE vmid node ..." ──
# IMPORTANT : le programme passe par `python3 -c "$RECONCILE_PY"` (PAS `python3 - <<heredoc`)
# car un heredoc occuperait stdin et entrerait en collision avec le pipe de données pvesh
# (→ SIGPIPE/exit 141). Ici stdin = uniquement les données JSON du pipe.
read -r -d '' RECONCILE_PY <<'PYEOF' || true
import json, os, re, sys

raw = sys.stdin.read()
def section(name):
    m = re.search(r'=== %s ===\n(.*?)(?:\n=== |\Z)' % re.escape(name), raw, re.S)
    if not m: return []
    try: return json.loads(m.group(1).strip() or '[]')
    except Exception: return []

status   = section('CLUSTER_STATUS')
vms      = section('VM_RESOURCES')
storages = section('STORAGES')

# Stockages PARTAGÉS (migrables sans copie de disque local) : flag 'shared' de Proxmox.
shared_storages = set(s.get('storage') for s in storages if s.get('shared'))

DISK_KEY = re.compile(r'^(scsi|virtio|ide|sata|efidisk|tpmstate)\d+:', re.I)
def vm_is_movable(node, vmid):
    # Movable ssi TOUS ses disques sont sur un stockage partagé. On lit la config dans
    # /etc/pve (montée cluster-wide, visible depuis n'importe quel nœud) → pas de SSH.
    path = '/etc/pve/nodes/%s/qemu-server/%s.conf' % (node, vmid)
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except Exception:
        return False
    seen_disk = False
    for ln in lines:
        if not DISK_KEY.match(ln):
            continue
        val = ln.split(':', 1)[1].strip()
        store = val.split(':', 1)[0].strip()      # "stockage.ceph:vm-..." → "stockage.ceph"
        if not store or store in ('none',):
            continue
        seen_disk = True
        if store not in shared_storages:
            return False                            # au moins un disque local → non migrable
    return seen_disk                                # migrable si au moins 1 disque, tous partagés

# Nœuds online : name + ip (depuis /cluster/status type=node).
nodes = {}        # name -> {'ip':.., 'online':bool}
ip2name = {}
for e in status:
    if e.get('type') == 'node':
        name = e.get('name'); ip = e.get('ip') or ''
        online = bool(e.get('online', 1))
        if name:
            nodes[name] = {'ip': ip, 'online': online}
            if ip: ip2name[ip] = name

def resolve_name(key):
    # une entrée de conf peut être une IP ou un nom de nœud PVE
    return ip2name.get(key, key if key in nodes else None)

# ── Allowlist des nœuds GÉRÉS ────────────────────────────────────────────────
# CRUCIAL : ne JAMAIS cibler un nœud nested no-KVM (BLADE/Bris/GENESIS/gandal) — une VM
# omega est KVM et ne peut pas y tourner. On se restreint aux nœuds explicitement listés
# dans OMEGA_RECONCILE_NODES, à défaut aux clés de OMEGA_VM_NODE_DISTRIBUTION (= les nœuds
# KVM emilia/ram/rem). Les autres nœuds online sont ignorés (ni source ni cible).
default_max = int(os.environ.get('OMEGA_VM_NODE_DEFAULT_MAX', '2') or 2)
dist = os.environ.get('OMEGA_VM_NODE_DISTRIBUTION', '') or ''
quota_spec = {}
for entry in dist.split(','):
    entry = entry.strip()
    if not entry or ':' not in entry: continue
    key, val = entry.rsplit(':', 1)
    if not val.strip().isdigit(): continue
    name = resolve_name(key.strip())
    if name: quota_spec[name] = int(val)

managed_env = os.environ.get('OMEGA_RECONCILE_NODES', '') or ''
managed = set()
for key in re.split(r'[,\s]+', managed_env):
    key = key.strip()
    if not key: continue
    name = resolve_name(key)
    if name: managed.add(name)
if not managed:
    managed = set(quota_spec.keys())          # défaut = nœuds de la distribution

online_nodes = [n for n in (nodes.keys()) if nodes[n]['online'] and n in managed]
if not online_nodes:
    print('NOOP no-managed-online-nodes'); sys.exit(0)

quota = {n: quota_spec.get(n, default_max) for n in online_nodes}

# VMs omega vivantes (tag autonome 'omega', hors templates) → node + status.
only_tag = os.environ.get('OMEGA_RECONCILE_ONLY_TAG', 'omega')
pat = re.compile(r'(^|[;, ])%s([;, ]|$)' % re.escape(only_tag))
pinned = set(x for x in re.split(r'[,\s]+', os.environ.get('OMEGA_RECONCILE_PIN_VMIDS','')) if x)

vm_node = {}      # vmid -> node
vm_status = {}    # vmid -> running/stopped
count = {n: 0 for n in online_nodes}
on_node = {n: [] for n in online_nodes}   # node -> [vmid,...]
tmpl_pat = re.compile(r'(^|[;, ])template([;, ]|$)')
skipped_local = []
for v in vms:
    if v.get('template'): continue                 # flag PVE "modèle"
    tags = v.get('tags') or ''
    if not pat.search(tags): continue              # doit être taguée omega
    if tmpl_pat.search(tags): continue             # mais PAS une image de base taguée 'template'
    node = v.get('node'); vmid = v.get('vmid')
    if node not in count or vmid is None: continue
    if not vm_is_movable(node, vmid):              # stockage local → hors flotte gérée
        skipped_local.append(vmid)
        continue
    vm_node[vmid] = node
    vm_status[vmid] = v.get('status','')
    count[node] += 1
    on_node[node].append(vmid)

if skipped_local:
    print('INFO ignore-non-migrables(stockage-local): ' +
          ','.join(str(x) for x in sorted(skipped_local)))

total = sum(count.values())

# Cible par nœud : greedy "plus forte capacité restante (quota-assigné), à égalité le
# plus gros quota d'abord". Pour total<=somme(quotas) → respecte exactement les quotas
# (1/2/2 pour 5). Pour total>somme → excédent réparti à parts égales (emilia plus léger).
target = {n: 0 for n in online_nodes}
order = sorted(online_nodes, key=lambda n: (-quota[n], n))  # tie-break déterministe
for _ in range(total):
    best = None; best_slack = None; best_q = None
    for n in order:
        slack = quota[n] - target[n]
        if best is None or slack > best_slack or (slack == best_slack and quota[n] > best_q):
            best, best_slack, best_q = n, slack, quota[n]
    target[best] += 1

# Récap occupation
recap = ' '.join('%s=%d/%d(cible %d)' % (n, count[n], quota[n], target[n]) for n in order)
print('RECAP ' + recap)

# Décisions : déplacer depuis les nœuds au-dessus de leur cible vers ceux en-dessous.
max_mig = int(os.environ.get('OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK','1') or 1)
moves = []
# copies mutables
cur = dict(count)
src_pool = {n: list(on_node[n]) for n in online_nodes}

def pick_movable(node):
    # préfère une VM en marche (live-migration), non pinnée ; plus haut vmid d'abord
    cands = [v for v in src_pool[node] if str(v) not in pinned]
    cands.sort(key=lambda v: (0 if vm_status.get(v)=='running' else 1, -int(v)))
    return cands[0] if cands else None

guard = 0
while len(moves) < max_mig and guard < 1000:
    guard += 1
    overs  = sorted([n for n in online_nodes if cur[n] > target[n]],
                    key=lambda n: (target[n]-cur[n], n))           # plus gros excédent d'abord
    unders = sorted([n for n in online_nodes if cur[n] < target[n]],
                    key=lambda n: (cur[n]-target[n], n))           # plus gros déficit d'abord
    if not overs or not unders: break
    src = overs[0]; dst = unders[0]
    vmid = pick_movable(src)
    if vmid is None:
        # rien de déplaçable sur src (tout pinné) → on retire src pour éviter une boucle
        cur[src] = target[src]; continue
    moves.append((vmid, dst, vm_status.get(vmid,''), src))
    src_pool[src].remove(vmid)
    cur[src] -= 1; cur[dst] += 1

if not moves:
    print('NOOP distribution-conforme')
else:
    for vmid, dst, st, src in moves:
        print('MIGRATE %s %s %s %s' % (vmid, dst, st, src))
PYEOF

PLAN="$(
  {
    echo "=== CLUSTER_STATUS ==="
    pvesh get /cluster/status --output-format json 2>/dev/null || echo '[]'
    echo "=== VM_RESOURCES ==="
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo '[]'
    echo "=== STORAGES ==="
    pvesh get /storage --output-format json 2>/dev/null || echo '[]'
  } | OMEGA_VM_NODE_DISTRIBUTION="$OMEGA_VM_NODE_DISTRIBUTION" \
      OMEGA_VM_NODE_DEFAULT_MAX="$OMEGA_VM_NODE_DEFAULT_MAX" \
      OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK="$OMEGA_RECONCILE_MAX_MIGRATIONS_PER_TICK" \
      OMEGA_RECONCILE_ONLY_TAG="$OMEGA_RECONCILE_ONLY_TAG" \
      OMEGA_RECONCILE_PIN_VMIDS="$OMEGA_RECONCILE_PIN_VMIDS" \
      OMEGA_RECONCILE_NODES="$OMEGA_RECONCILE_NODES" \
      python3 -c "$RECONCILE_PY"
)"

# ── Exécution des décisions ──────────────────────────────────────────────────
# `|| true` : un grep SANS correspondance (ex. aucune ligne INFO) renvoie 1 et, sous
# `set -euo pipefail`, AVORTAIT tout le script avant les migrations (bug d'équilibrage).
{ echo "$PLAN" | grep -E '^RECAP ' | sed 's/^RECAP /  occupation: /' || true; } | while read -r l; do log "$l"; done
{ echo "$PLAN" | grep -E '^INFO ' | sed 's/^INFO /  /' || true; } | while read -r l; do log "$l"; done

if echo "$PLAN" | grep -q '^NOOP '; then
    reason="$(echo "$PLAN" | grep -m1 '^NOOP ' | awk '{print $2}')"
    log "rien à faire ($reason)"
    exit 0
fi

migrations_done=0
while read -r kw vmid dst st src; do
    [[ "$kw" == "MIGRATE" ]] || continue
    online_val=0
    [[ "$st" == "running" ]] && online_val=1
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[dry-run] migrerait VM $vmid : $src → $dst $([[ $online_val == 1 ]] && echo --online || echo '(cold)')"
        continue
    fi
    log "migration VM $vmid : $src → $dst $([[ $online_val == 1 ]] && echo --online || echo '(cold)')"
    # `qm migrate` DOIT tourner sur le nœud SOURCE (sinon « target is local node »).
    # IMPÉRATIF : on l'exécute en BLOQUANT sur $src via ssh et on lit son VRAI code de
    # sortie. L'ancien `pvesh create .../migrate` rendait la main dès le LANCEMENT de la
    # tâche (async) → on comptait « ✓ » avant la fin réelle et on ne voyait jamais les
    # échecs (« Broken pipe ») survenant PENDANT la tâche → faux succès + retriggers.
    # Ici, qm migrate ne rend la main qu'à la FIN → succès/échec réels.
    mig_args=(--with-local-disks 0)
    [[ "$online_val" == "1" ]] && mig_args+=(--online 1)
    mig_rc=0
    if [[ "$src" == "$(hostname)" ]]; then
        timeout "$OMEGA_RECONCILE_MIGRATE_TIMEOUT_SECS" \
            qm migrate "$vmid" "$dst" "${mig_args[@]}" >>"$OMEGA_RECONCILE_LOG" 2>&1 || mig_rc=$?
    else
        timeout "$OMEGA_RECONCILE_MIGRATE_TIMEOUT_SECS" \
            ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$src" \
            "qm migrate $vmid $dst ${mig_args[*]}" >>"$OMEGA_RECONCILE_LOG" 2>&1 || mig_rc=$?
    fi
    if [[ "$mig_rc" -eq 0 ]]; then
        log "  ✓ VM $vmid réellement migrée sur $dst"
        migrations_done=$((migrations_done + 1))
    else
        # Échec réel (non-migrable à chaud GPU/local, ou coupure réseau) → jamais de
        # destruction ; on laisse pour le prochain tick.
        log "  ✗ migration VM $vmid échouée (rc=$mig_rc) — réessai au prochain tick"
    fi
done < <(echo "$PLAN" | grep -E '^MIGRATE ')

log "tick terminé : $migrations_done migration(s) effectuée(s)"
