# Fonctionnement complet — RAM, vCPU, disque, GPU

Ce document décrit tous les scénarios de vie d'une VM dans le système omega-remote-paging :
de la création jusqu'au fonctionnement sous pression, pour les trois ressources gérées.

---

## Architecture générale

```
┌─────────────────────────────────────────────────────────────────┐
│                        NŒUD PROXMOX                             │
│                                                                 │
│  VM (QEMU)                                                      │
│  ┌──────────────┐                                               │
│  │ processus    │  userfaultfd ──► omega-daemon (Rust)          │
│  │ qemu-system  │  QMP socket  ──► vcpu hotplug                 │
│  │              │  cgroup v2   ──► cpu.max / cpu.weight / io.weight │
│  └──────────────┘  /dev/dri   ──► GPU multiplexer              │
│                                                                 │
│  omega-daemon (Rust)                                            │
│  ├── fault_bus        ← intercepte les page faults RAM          │
│  ├── eviction_engine  ← décide quoi paginer vers les autres nœuds│
│  ├── vcpu_scheduler   ← gère le pool de vCPU                   │
│  ├── qmp_vcpu         ← hotplug réel via QMP                   │
│  ├── cpu_cgroup       ← lit/écrit cgroups CPU v2               │
│  ├── io_cgroup        ← lit/écrit cgroups I/O v2               │
│  ├── disk_io_scheduler← rééquilibre les priorités disque locales│
│  ├── gpu_multiplexer  ← partage le GPU entre VMs               │
│  └── gpu_drm_backend  ← ioctls DRM vers /dev/dri/renderD128    │
│                                                                 │
│  controller (Python)                                            │
│  ├── cpu_cgroup_monitor ← lit cpu.stat toutes les 1 ms         │
│  ├── memory_monitor     ← surveille la RAM allouée             │
│  └── placement          ← choisit le nœud pour chaque VM       │
└─────────────────────────────────────────────────────────────────┘
```

Le cluster comporte 3 nœuds identiques. Chaque nœud exécute un `omega-daemon`.
Les nœuds communiquent entre eux via TLS pour le paging RAM distant. Le disque reste
sur Ceph RBD partagé, mais l'arbitrage de contention locale se fait via `io.weight`.

## Partie 0 — Source de vérité par ressource

- RAM : quotas et budgets réels dans `quota.rs`, ajustés depuis `virtio-balloon` via QMP
- CPU : topologie et hotplug réels via QMP, bande passante via `cpu.max`/`cpu.weight`
- Disque : compteurs réels via `io.stat`, pression nœud via PSI I/O, priorités via `io.weight`
- GPU : capacité nœud via backend DRM (`/dev/dri/renderD*`), budgets VM via métadonnées Proxmox

---

## Partie 1 — RAM

### Principe

La RAM d'une VM peut déborder physiquement sur un nœud voisin.
Quand la VM accède une page absente en mémoire locale, le kernel lève un page fault.
`omega-daemon` intercepte ce fault via **userfaultfd**, récupère la page depuis le nœud
qui la stocke, et la réinjecte dans le processus QEMU — de façon transparente pour la VM.

### Scénario 1 — Création d'une VM (RAM suffisante)

```
Utilisateur → pvesh create /nodes/node-a/qemu -memory 4096 -vcpus 4 ...
                                │
                Controller placement.py
                  ┌─────────────────────────────┐
                  │ node-a : 8 Go libres         │  ← sélectionné
                  │ node-b : 6 Go libres         │
                  │ node-c : 3 Go libres         │
                  └─────────────────────────────┘
                                │
                VM créée sur node-a avec 4 Go alloués localement
                omega-daemon enregistre : vm_id=101, local=4096 Mo
```

La VM démarre, toute sa RAM est locale — aucun paging, latence normale.

### Scénario 2 — Pression mémoire (RAM locale insuffisante)

```
Cluster chargé :
  node-a : 1 Go libre  ← VM 101 veut 4 Go → manque 3 Go
  node-b : 5 Go libres ← peut héberger 3 Go de pages distantes
  node-c : 4 Go libres

omega-daemon (node-a) :
  1. Détecte que node-a manque de RAM (quota.rs)
  2. Choisit node-b pour héberger 3 Go de pages
  3. Mappe les pages distantes via uffd (fault_bus.rs)
  4. VM 101 démarre avec 1 Go local + 3 Go distants (node-b)
```

Quand la VM accède une page distante :

```
VM touche adresse 0x7f...
    │
    ▼ page fault (kernel)
    │
userfaultfd → omega-daemon (node-a)
    │
    ▼ UFFD_MSG_PAGEFAULT
    │
fault_bus.rs → requête TLS → node-b
    │
    ▼ store_server.rs (node-b) → lit la page en mémoire locale
    │
    ▼ réponse TLS → node-a
    │
UFFD_COPY → page injectée dans QEMU → VM reprend son exécution
```

Latence typique sur réseau local : 100–300 µs (LAN Gigabit).

### Scénario 3 — Éviction (node-a sur-chargé)

```
node-a atteint 95% d'occupation mémoire physique
eviction_engine.rs :
  1. Identifie les pages froides des VMs (peu accédées)
  2. Envoie ces pages vers node-b ou node-c via TLS
  3. Libère la mémoire physique sur node-a
  4. Met à jour la table de mapping : page X → node-b
```

La VM ne voit rien — les pages sont migrées à chaud.

### Scénario 4 — Garantie de quota mémoire

Le module `quota.rs` garantit qu'aucune VM ne dépasse la RAM qu'elle a demandée :

```
VM 101 demande 4 Go → quota max = 4 Go
VM 102 demande 2 Go → quota max = 2 Go

Si VM 101 tente d'allouer 5 Go :
  quota.rs refuse l'allocation supplémentaire
  → VM reçoit OOM kill sur ses propres processus (comportement normal)
  → Les autres VMs ne sont pas affectées
```

Le nœud le plus chargé n'est jamais choisi pour une nouvelle VM (placement.py).

---

## Partie 2 — vCPU

### Principe

Les vCPUs ne correspondent pas à des cœurs physiques fixes.
Un vCPU est un **quota de temps CPU** alloué par le scheduler CFS du kernel.

```
cpu.max = "N × 1_000_000  1_000_000"

Exemples :
  "1000000 1000000"  → 1 vCPU  (100% d'un thread physique sur 1 seconde)
  "2000000 1000000"  → 2 vCPU  (200% — 2 threads en parallèle)
  "6000000 1000000"  → 6 vCPU  (600% — 6 threads en parallèle)

Ce n'est pas un cœur physique dédié.
Une VM avec 2 vCPU peut s'exécuter sur n'importe quels 2 threads physiques
disponibles au même instant — le kernel choisit.
```

### Dimensionnement du pool

Sur un nœud avec 4 pCPU (4 cœurs physiques, 8 threads avec HT) :

```
VCPU_PER_PCPU = 3 (sursouscription × 3)
MAX_VCPU_POOL = 8 threads × 3 = 24 vCPUs disponibles

MAX_VMS_PER_SLOT = 3  (max 3 VMs partagent un même vCPU "slot")
```

La sursouscription est possible parce que les VMs n'utilisent jamais leurs
vCPU à 100% en continu — il y a toujours de la place pour les autres.

### Scénario 1 — VM inactive (vCPU réduit automatiquement)

```
VM 101 : 4 vCPU demandés, usage réel = 2%
  cpu.stat lu toutes les 1 ms
  Fenêtre 100 ms (100 échantillons) : avg_usage = 2%

vcpu_scheduler.rs :
  2% < seuil_bas (20%) pendant 30 secondes
  → Décision : réduire à 2 vCPU
  → QmpVcpuClient.hotplug_remove() → device_del via QMP
  → cpu.max = "2000000 1000000"
  → La VM voit 2 vCPU (le guest OS retire les CPU manquants)

Libération : 2 vCPU remis dans le pool pour d'autres VMs
```

### Scénario 2 — VM sous charge (vCPU augmenté)

```
VM 102 : 2 vCPU alloués, lance une compilation lourde
  Après 100 ms : avg_usage = 95%, throttle_ratio = 0.15

cpu_cgroup_monitor.py détecte :
  95% > seuil_haut (80%) ET throttle_ratio (15%) > seuil (10%)

on_pressure(vm_id=102, usage=95.0, throttle=0.15) déclenché
  → POST /control/vm/102/vcpu/metrics envoyé au daemon Rust

vcpu_scheduler.rs reçoit la métrique :
  Pool disponible : 6 vCPU libres
  → Décision : ajouter 2 vCPU → VM 102 passe à 4 vCPU
  → QmpVcpuClient.hotplug_add() → device_add cpu via QMP
  → cpu.max = "4000000 1000000"
  → Le guest OS détecte les nouveaux CPU (hotplug ACPI)

Délai typique entre détection et hotplug : < 200 ms
```

### Scénario 3 — Pool épuisé (réclamation locale puis partage CPU)

```
node-a : 24 vCPU pool → tous alloués
VM 103 veut 2 vCPU supplémentaires → pool = 0

vcpu_scheduler.rs :
  Étape 1 : chercher une VM durablement idle pouvant céder 1 vCPU réel
  Étape 2 : hot-unplug côté donneur, hotplug côté VM 103
  Étape 3 : si aucun donneur n'est disponible, activer un partage CPU local

Partage CPU local :
  VM 103 garde ses vCPU actuels
  son cpu.weight est temporairement augmenté
  les VMs peu actives du nœud voient leur cpu.weight baisser

Résultat :
  VM 103 reçoit plus de temps CPU hôte pendant la contention
  sans "emprunter" littéralement les vCPU logiques des autres VMs
  → si la pression persiste, la migration est recommandée
```

### Scénario 4 — Throttling persistant

```
VM 104 : throttle_ratio = 0.40 (40% des périodes throttlées) pendant 1 seconde
  Le nœud est saturé — aucun vCPU libre

vcpu_scheduler.rs :
  Identifie VM 105 (basse charge stable) : avg_usage = 3%
  → Retire 1 vCPU à VM 105 (hotplug_remove) si elle est au-dessus de son minimum
  → Donne 1 vCPU à VM 104
  → Si aucun retrait réel n'est possible, VM 104 passe en priorité CPU locale
    via cpu.weight en attendant la migration

balloon.rs peut aussi intervenir :
  Si VM 105 n'a pas besoin de RAM → libérer sa RAM pour éviter que la
  saturation vCPU se combine à une saturation RAM
```

### Lecture des métriques à 1 ms

```
Pourquoi 1 ms ?
  cpu.stat est mis à jour par le kernel à chaque context switch.
  À 1 ms, on capture chaque changement significatif.
  À 10 ms ou plus, on rate les pics courts (compilation, encodage).

Structure de la fenêtre glissante :
  100 échantillons × 1 ms = fenêtre de 100 ms
  avg_usage_pct    = moyenne sur 100 ms
  max_usage_pct    = pic sur 100 ms
  avg_throttle_ratio = taux de throttling moyen sur 100 ms

Rate-limiting des décisions :
  Max 1 décision de hotplug par fenêtre de 100 ms
  Évite les oscillations (add/remove/add/remove en rafale)
```

---

## Partie 3 — GPU

### Principe

Aucun GPU du cluster ne supporte les vGPU SR-IOV natifs.
On implémente un **multiplexeur GPU** au niveau daemon : les VMs accèdent
au GPU via un protocole binaire qui sérialise les commandes.

```
VM (guest)
  │
  ▼ virtio-gpu / protocole omega-gpu (unix socket)
  │
gpu_multiplexer.rs (daemon, une instance par nœud)
  │
  ▼ sérialisation des requêtes par VM
  │
gpu_drm_backend.rs → /dev/dri/renderD128 (render node DRM)
  │
  ▼ ioctls DRM → GPU physique (amdgpu / i915 / nouveau)
```

### Scénario 1 — VM sans GPU

```
VM 101 : aucune demande GPU
  gpu_multiplexer.rs : aucun slot alloué
  La VM utilise le display VNC standard (framebuffer logiciel)
```

### Scénario 2 — VM avec GPU (calcul)

```
VM 102 demande un slot GPU pour du calcul (ML, rendu)
  gpu_multiplexer.rs :
    1. Vérifie la disponibilité : GPU physique libre
    2. Crée un handle GEM (Graphics Execution Manager) via DRM ioctl
       DRM_IOCTL_AMDGPU_GEM_CREATE (amdgpu) ou
       DRM_IOCTL_I915_GEM_CREATE   (Intel)
    3. Alloue N Mo de VRAM pour VM 102
    4. Retourne un handle opaque à la VM : (gem_handle << 32 | fd)

Encodage du handle :
  gem_handle (32 bits) : identifiant DRM du buffer dans le driver
  fd         (32 bits) : file descriptor du render node ouvert
  handle     (64 bits) : (gem_handle << 32) | (fd & 0xFFFF_FFFF)
```

### Scénario 3 — Plusieurs VMs sur le même GPU

```
node-a : 1 GPU physique (RTX 3080, 10 Go VRAM)
  VM 201 : 3 Go VRAM alloués (calcul ML)
  VM 202 : 2 Go VRAM alloués (rendu 3D)
  VM 203 : 1 Go VRAM alloués (encodage vidéo)
  Libre : 4 Go VRAM

gpu_multiplexer.rs sérialise les commandes :
  File d'attente par priorité (définie à la création du slot)
  Une seule VM accède au GPU à la fois (mutex interne)
  Rotation round-robin entre VMs de même priorité
  Timeslice par VM : configurable (défaut 10 ms par slot)
```

### Scénario 4 — VRAM saturée

```
VM 204 demande 5 Go VRAM → seulement 4 Go libres

gpu_multiplexer.rs :
  Option 1 : refuser (code d'erreur → la VM voit ENOMEM)
  Option 2 : libérer les handles inactifs depuis > 30 s
             → gem_free() → DRM_IOCTL_GEM_CLOSE
             → récupère la VRAM libérée
             → réessaie l'allocation

Si toujours insuffisant :
  La VM reçoit une erreur GPU → elle doit réduire sa demande
  Le daemon ne swappe pas la VRAM (pas de mémoire virtuelle GPU)
```

### Scénario 5 — Découverte des render nodes

```
Au démarrage du daemon, gpu_drm_backend.rs :
  Pour renderD128 à renderD135 :
    1. Ouvre /dev/dri/renderDXXX
    2. Envoie DRM_IOCTL_VERSION (0xC028_6400)
    3. Lit le nom du driver : "amdgpu", "i915", "nouveau", "virtio_gpu"
    4. Enregistre le type et les capacités

Résultat : liste de backends disponibles
  [DrmDriver::Amdgpu at renderD128, DrmDriver::I915 at renderD129]

Le multiplexeur choisit le backend selon la demande de la VM.
```

---

## Scénarios combinés RAM + vCPU + GPU

### Scénario A — VM de calcul intensif

```
VM 301 : 16 Go RAM, 8 vCPU, 4 Go VRAM

Au démarrage (nœud vide) :
  RAM    : 16 Go alloués localement (node-a, 32 Go libres)
  vCPU   : 8 vCPU → cpu.max = "8000000 1000000"
  GPU    : 4 Go VRAM → handle GEM alloué

Pendant l'entraînement d'un modèle ML :
  RAM    : stable (données en mémoire locale)
  vCPU   : usage 90% → pas de throttling → quota maintenu
  GPU    : VRAM à 95%, sérialisé par le multiplexeur

Résultat : VM 301 tourne à plein régime, pas d'intervention du scheduler
```

### Scénario B — Cluster saturé (contention sur les 3 ressources)

```
node-a : 28 Go RAM utilisés / 32 Go, 22 vCPU utilisés / 24, GPU à 90% VRAM
node-b : 30 Go / 32 Go, 20 vCPU / 24, GPU à 60% VRAM
node-c : 25 Go / 32 Go, 18 vCPU / 24, GPU à 30% VRAM

Nouvelle VM 302 demande : 8 Go RAM, 4 vCPU, 2 Go VRAM

placement.py calcule les scores :
  node-a : score faible (RAM et vCPU saturés)
  node-b : score moyen
  node-c : score élevé → SÉLECTIONNÉ

VM 302 créée sur node-c :
  RAM    : 8 Go locaux (node-c a 7 Go libres → 1 Go distant sur node-a)
  vCPU   : 4 vCPU alloués (node-c a 6 slots libres)
  GPU    : 2 Go VRAM alloués (node-c GPU à 30% → 7 Go libres)

Si node-c se charge à son tour :
  RAM    : le 1 Go distant sur node-a reste, node-c migre d'autres pages
  vCPU   : scheduler réduit VM 302 à 2 vCPU si usage < 20%
  GPU    : pas d'action (VRAM est statique une fois allouée)
```

### Scénario C — VM qui démarre et s'arrête (libération des ressources)

```
VM 303 s'arrête proprement (shutdown) :

  RAM    : omega-daemon libère toutes les pages distantes
           → node-b récupère 3 Go de RAM physique
           quota.rs retire VM 303 de sa table

  vCPU   : QmpVcpuClient détecte la déconnexion du socket QMP
           vcpu_scheduler retire VM 303
           → 4 vCPU remis dans le pool
           → cpu.max n'a plus d'effet (processus mort)

  GPU    : gpu_multiplexer reçoit la déconnexion du socket VM
           → gem_free() sur tous les handles de VM 303
           → 2 Go VRAM libérés
           → slot retiré de la file d'attente
```

---

## Partie 4 — Migrations (à chaud et à froid)

### Principe général

Une migration déplace une VM entière d'un nœud vers un autre.
Elle est déclenchée automatiquement par l'`EvictionEngine` ou manuellement via l'API.

```
Deux types :

  LIVE (à chaud) — VM reste allumée pendant le transfert
    qm migrate {vmid} {target} --online
    Mécanisme : KVM pre-copy (les pages mémoire sont transférées en continu
    pendant que la VM tourne ; les pages modifiées sont retransférées jusqu'à
    convergence ; VM suspendue < 1s pour la coupure finale).
    Avec Ceph RBD : seule la RAM est transférée, le disque reste sur Ceph
    et devient accessible depuis le nœud cible immédiatement.

  COLD (à froid) — VM stoppée avant transfert
    qm migrate {vmid} {target}
    Mécanisme : Proxmox arrête la VM, bascule l'accès disque Ceph RBD
    vers le nœud cible, redémarre. Aucune copie de disque.
    Downtime = stop + redémarrage (quelques secondes).
```

### Règles de décision live vs cold

```
État de la VM        Pression nœud             Raison               → Type
─────────────────    ───────────────────────   ──────────────────   ──────
Running, CPU > 5%    RAM 85–95%                mémoire haute        LIVE
Running, CPU > 5%    RAM > 95% (critique)      urgence OOM          COLD (*)
Running, CPU < 5%    RAM > 85% (+ 60s idle)   VM idle              COLD
Stopped              peu importe               déplacement          COLD
Running, throttlé    vCPU saturé               CPU plein            LIVE
Running, remote>60%  peu importe               paging excessif      LIVE ou COLD

(*) Pression > 95% : live migration est trop lente (trop de dirty pages
    transférées en boucle). Cold est plus rapide car la VM ne modifie plus rien.
```

### Scénario 1 — Migration live déclenchée automatiquement (RAM)

```
node-a : RAM à 88%, VM 401 (8 Go, CPU 60%) cause la pression
node-b : RAM à 35%, peut accueillir 8 Go

EvictionEngine (toutes les 10s) :
  1. Lit /proc/meminfo → usage 88% > seuil 85%
  2. Appelle MigrationPolicy.evaluate()
     - VM 401 : running, CPU 60% > 5% → LIVE
     - Target : node-b (score 0.72 vs node-c score 0.51)
     - MigrationRequest { vm_id=401, target="node-b", type=LIVE }

  3. Vérifie : pas de migration déjà en cours pour VM 401
  4. MigrationExecutor.spawn() → tâche tokio de fond

  5. Commande exécutée :
     qm migrate 401 node-b --online
     (disque déjà sur Ceph RBD → aucune copie disque, seule la RAM est transférée)

  6. Pendant la migration (30s–2 min selon RAM dirty) :
     - Source continue de servir les page faults normalement
     - Proxmox transfère les pages via KVM pre-copy
     - Chaque page modifiée par la VM est retransférée

  7. Quand Proxmox signale le succès :
     - cleanup_after_migration() :
       → delete toutes les pages du store source (node-bc-store)
       → vcpu_scheduler.release_vm(401)
       → quota_registry.remove(401)

VM 401 reprend sur node-b avec < 1s de downtime visible.
```

### Scénario 2 — Migration cold (VM idle)

```
node-a : RAM à 87%, VM 402 (4 Go, CPU 1% depuis 90s)
node-c : RAM à 25%

MigrationPolicy détecte :
  - VM 402 : running, CPU 1% < 5%, idle depuis 90s > 60s → COLD acceptable
  - RAM 87% > 85% → action requise
  - MigrationRequest { vm_id=402, target="node-c", type=COLD }

Exécution :
  qm migrate 402 node-c

Sequence :
  1. Proxmox arrête la VM 402 (ACPI shutdown propre)
  2. Proxmox bascule l'accès RBD → node-c obtient l'accès exclusif au disque Ceph
  3. La VM redémarre sur node-c (disque disponible immédiatement)
  4. Cleanup sur node-a (pages store, vCPU, quota)

Downtime typique : 10–30s (arrêt + redémarrage uniquement, pas de copie disque).
Acceptable car la VM était idle (pas d'utilisateur actif).
```

### Scénario 3 — Migration cold d'urgence (RAM critique)

```
node-b : RAM à 97% — risque d'OOM imminent
VM 403 (16 Go, CPU 40%) est la VM la plus lourde

Même si CPU > 5%, la pression critique force COLD :
  - Live migration à 97% générerait trop de dirty pages
  - Le transfert live n'arriverait jamais à convergence (dirty rate > transfer rate)
  - Cold est plus rapide : VM stoppée → plus de dirty pages → transfert immédiat

MigrationPolicy :
  urgency = 2 (critique)
  type = COLD (is_critical = true → override idle check)

Exécution :
  qm migrate 403 node-a

Downtime : 15–60s (arrêt + redémarrage). Acceptable vs OOM qui tuerait toutes les VMs.
Ceph RBD : pas de copie disque → le downtime est minimal même pour une grosse VM.
```

### Scénario 4 — Migration live pour saturation vCPU

```
node-c : vCPU pool utilisé à 92%, VM 404 throttle_ratio = 0.42 (42%)
node-a : vCPU pool utilisé à 45%

MigrationPolicy détecte :
  - VM 404 : throttle 42% > seuil 30%, running → LIVE
  - Raison : CpuSaturation { throttle_ratio: 0.42, target_vcpu_free: 13 }
  - Target : node-a (13 vCPU libres)

Exécution : qm migrate 404 node-a --online

Sur node-a après migration :
  - VM 404 admet dans vcpu_scheduler (13 slots libres)
  - cpu.max mis à jour selon les vCPU disponibles
  - throttle_ratio revient à < 5% car plus de contention
```

### Scénario 5 — Migration manuelle via API

```bash
# Déclencher une migration depuis le controller Python
curl -X POST http://node-a:7200/control/migrate \
  -H "Content-Type: application/json" \
  -d '{"vm_id": 405, "target": "node-b", "type": "live", "reason": "admin_request"}'

# Réponse immédiate (tâche en fond)
{
  "status": "migration_started",
  "task_id": 3,
  "vm_id": 405,
  "target": "node-b",
  "type": "live"
}

# Consulter les recommandations automatiques
curl http://node-a:7200/control/migrate/recommend
{
  "node_id": "node-a",
  "count": 2,
  "recommendations": [
    { "vm_id": 406, "type": "live", "reason": "memory_pressure", "urgency": 1 },
    { "vm_id": 407, "type": "cold", "reason": "excessive_remote_paging", "urgency": 1 }
  ]
}
```

### Scénario 6 — Cluster en récupération après migration

```
Avant migration : node-a surchargé (RAM 90%), node-b à 30%
Après migration de VM 401 vers node-b :

  node-a : RAM libérée (8 Go) → 72%
    - EvictionEngine repasse sous seuil (85%) → pas de nouveau cycle de migration
    - Les pages distantes que VM 401 avait sur node-b sont supprimées
    - VMs restantes sur node-a : page faults servies normalement

  node-b : RAM augmentée 30% → 55%
    - omega-daemon sur node-b enregistre VM 401 (nouveau vm_tracker)
    - quota_registry.set() pour VM 401 avec ses quotas
    - vcpu_scheduler.admit_vm() alloue les vCPU de VM 401

  Résultat : cluster équilibré, aucune VM stoppée, RAM disponible sur chaque nœud
```

### Séquence de nettoyage post-migration (détail)

Quand `cleanup_after_migration()` s'exécute sur le nœud source :

```
1. store.keys_for_vm(vm_id)
   → liste toutes les pages de la VM stockées dans le store source

2. store.delete(key) × N
   → libère la RAM physique occupée par ces pages distantes
   (les pages étaient déjà sur node-b avant la migration — on libère la copie source)

3. vcpu_scheduler.release_vm(vm_id)
   → libère tous les slots vCPU alloués à cette VM
   → ces slots peuvent maintenant être attribués à d'autres VMs

4. quota_registry.remove(vm_id)
   → supprime la limite mémoire (le quota est recréé sur le nœud cible)

Note : le nœud cible configure ses propres ressources quand la VM démarre.
Le controller Python envoie POST /control/vm/{vm_id}/quota au nœud cible
après avoir vérifié que la VM est bien démarrée.
```

---

## Comment tester

### Prérequis

```bash
# Sur chaque nœud Proxmox (ou KVM simulant un nœud)
systemctl status omega-daemon   # daemon Rust doit tourner
python3 -m venv /opt/omega/venv
source /opt/omega/venv/bin/activate
pip install -r controller/requirements.txt
```

### Tests unitaires Python (sans infrastructure)

```bash
cd omega-remote-paging/controller

# Tous les tests (233 au total)
python3 -m pytest -v

# Tests CPU cgroup seulement (44 tests)
python3 -m pytest tests/test_cpu_cgroup.py -v

# Tests RAM / quota (filtrer par module)
python3 -m pytest tests/test_quota.py tests/test_memory.py -v

# Tests placement (choix du nœud)
python3 -m pytest tests/test_topology_placement.py -v

# Résumé rapide
python3 -m pytest --tb=short -q
```

### Tests Rust (daemon)

```bash
cd omega-remote-paging/omega-daemon

# Tous les tests Rust
cargo test

# Tests d'un module spécifique
cargo test cpu_cgroup
cargo test qmp_vcpu
cargo test gpu_drm

# Avec logs de debug
RUST_LOG=debug cargo test -- --nocapture
```

### Test RAM — paging distant manuel

```bash
# Créer une VM avec plus de RAM que disponible localement
# (adapter selon la RAM réelle du nœud)
pvesh create /nodes/node-a/qemu \
  --vmid 901 \
  --memory 20480 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0

# Dans la VM, remplir la RAM
stress-ng --vm 1 --vm-bytes 18G --timeout 60s

# Vérifier le paging sur node-a
cat /proc/$(pgrep -f "qemu.*901")/status | grep VmRSS
journalctl -u omega-daemon --since "1 min ago" | grep "fault\|page\|remote"
```

### Test vCPU — monitoring à 1 ms

```bash
# Lancer le moniteur en mode debug
cd controller
python3 -c "
from controller.cpu_cgroup_monitor import CgroupCpuController, CgroupCpuMonitor

ctrl = CgroupCpuController()

def on_pressure(vm_id, usage_pct, throttle_ratio):
    print(f'VM {vm_id}: usage={usage_pct:.1f}% throttle={throttle_ratio:.2%}')

mon = CgroupCpuMonitor(
    controller=ctrl,
    on_pressure=on_pressure,
    usage_threshold=50.0,
    throttle_threshold=0.05,
)
mon.start()

import time
time.sleep(30)
print(mon.snapshot())
mon.stop()
"

# Dans la VM, créer de la charge CPU
stress-ng --cpu 4 --timeout 20s

# Vérifier le cgroup directement
VMID=901
CGROUP=/sys/fs/cgroup/machine.slice/machine-qemu-${VMID}-pve.scope
watch -n 0.1 "cat ${CGROUP}/cpu.stat | head -6"
watch -n 0.1 "cat ${CGROUP}/cpu.max"
```

### Test vCPU — hotplug QMP

```bash
# Vérifier les vCPU visibles dans la VM avant hotplug
ssh root@vm901 "nproc"

# Envoyer une commande QMP directement
echo '{"execute":"query-hotpluggable-cpus"}' | \
  socat - UNIX:/var/run/qemu-server/901.qmp

# Ajouter un vCPU via QMP
echo '{"execute":"device_add","arguments":{"driver":"host-x86_64-cpu","id":"cpu-extra-1","socket-id":0,"core-id":2,"thread-id":0}}' | \
  socat - UNIX:/var/run/qemu-server/901.qmp

# Vérifier dans la VM
ssh root@vm901 "nproc"  # doit avoir augmenté
```

### Test GPU — render node

```bash
# Vérifier que le render node est accessible
ls -la /dev/dri/
# → renderD128 doit exister

# Vérifier le driver chargé
cat /sys/class/drm/renderD128/device/driver/module/parameters/*/  2>/dev/null
dmesg | grep -E "amdgpu|i915|nouveau" | tail -5

# Tester l'ouverture du render node (sans root)
python3 -c "
import fcntl, struct, os

fd = os.open('/dev/dri/renderD128', os.O_RDWR)
# DRM_IOCTL_VERSION = 0xC0286400
buf = struct.pack('iiiiQQii', 0, 0, 0, 0, 0, 0, 0, 0) + b'\x00' * 64
try:
    fcntl.ioctl(fd, 0xC0286400, buf)
    print('render node OK')
except Exception as e:
    print(f'erreur: {e}')
finally:
    os.close(fd)
"

# Vérifier la VRAM disponible (amdgpu)
cat /sys/class/drm/card0/device/mem_info_vram_total
cat /sys/class/drm/card0/device/mem_info_vram_used
```

### Test GPU — multiplexeur omega

```bash
# Démarrer le daemon avec logs GPU
RUST_LOG=omega_daemon::gpu_multiplexer=debug,omega_daemon::gpu_drm_backend=debug \
  /usr/local/bin/omega-daemon

# Dans les logs, chercher
journalctl -u omega-daemon | grep -E "gpu|drm|gem|vram"

# Vérifier depuis la VM (si le protocole omega-gpu est configuré)
# (protocole virtio ou socket unix selon la configuration VM)
```

### Test complet — scénario de charge réaliste

```bash
# 1. Créer 3 VMs avec des demandes variées
pvesh create /nodes/node-a/qemu --vmid 910 --memory 4096 --cores 2
pvesh create /nodes/node-b/qemu --vmid 911 --memory 8192 --cores 4
pvesh create /nodes/node-c/qemu --vmid 912 --memory 16384 --cores 8

# 2. Lancer des charges dans chaque VM
for vmid in 910 911 912; do
  ssh root@vm${vmid} "stress-ng --cpu 0 --vm 1 --vm-bytes 80% --timeout 60s &"
done

# 3. Observer le comportement en temps réel
watch -n 1 "
echo '=== RAM paging ==='
journalctl -u omega-daemon --since '5s ago' | grep 'remote\|fault\|evict' | tail -5

echo '=== vCPU ==='
for vmid in 910 911 912; do
  cg=/sys/fs/cgroup/machine.slice/machine-qemu-\${vmid}-pve.scope
  echo -n \"VM \$vmid cpu.max: \"
  cat \$cg/cpu.max 2>/dev/null
  echo -n \"  throttled: \"
  grep nr_throttled \$cg/cpu.stat 2>/dev/null
done

echo '=== GPU VRAM ==='
cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null
"

# 4. Vérifier les métriques Python
python3 -c "
from controller.cpu_cgroup_monitor import CgroupCpuController, CgroupCpuMonitor
import time, json
ctrl = CgroupCpuController()
mon = CgroupCpuMonitor(ctrl)
mon.start()
time.sleep(5)
print(json.dumps(mon.snapshot(), indent=2))
mon.stop()
"
```

### Interprétation des résultats

| Métrique | Valeur normale | Action requise |
|---|---|---|
| `avg_usage_pct` | 20% – 80% | < 20% → réduire vCPU ; > 80% → augmenter |
| `avg_throttle_ratio` | < 5% | > 10% → hotplug urgent |
| `max_usage_pct` | < 150% | > 200% → saturation, migration |
| Pages distantes | < 20% de la RAM VM | > 50% → VM sur mauvais nœud |
| VRAM utilisée | < 85% | > 90% → libérer handles inactifs |

### Logs à surveiller

```bash
# Décisions de hotplug vCPU
journalctl -u omega-daemon | grep -E "hotplug|device_add|device_del|vcpu"

# Paging RAM distant
journalctl -u omega-daemon | grep -E "fault|remote|page|evict"

# GPU
journalctl -u omega-daemon | grep -E "gem|vram|drm|render"

# Python controller
journalctl -u omega-controller | grep -E "pressure|throttle|placement"

# Migrations
journalctl -u omega-daemon | grep -E "migration|migrate|qm migrate|cleanup"
```

### Test migration — unitaires (sans cluster)

```bash
# Tests Python de la politique de migration (28 tests)
cd controller
python3 -m pytest tests/test_migration_policy.py -v

# Tests Rust du module vm_migration (6 tests)
cargo test -p omega-daemon vm_migration -- --nocapture

# Cas couverts :
# - VM stopped → toujours cold
# - VM active + RAM critique → cold forcée
# - VM active + RAM haute → live
# - VM idle (CPU < 5% depuis 60s) → cold
# - Throttle vCPU > 30% → live
# - Remote paging > 60% → migration
# - Pas de migration si cluster sain
# - Urgence (critique) en premier dans la liste
```

### Test migration — en conditions réelles

```bash
# 1. Vérifier que qm migrate fonctionne manuellement
qm migrate 901 node-b --online
# → doit retourner un task_id Proxmox, puis "Migration successful"

# 2. Déclencher via l'API omega (après avoir recréé la VM)
qm restore node-a 901 ...
curl -X POST http://node-a:7200/control/migrate \
  -d '{"vm_id": 901, "target": "node-b", "type": "live"}'

# 3. Consulter les recommandations automatiques
curl http://node-a:7200/control/migrate/recommend | python3 -m json.tool

# 4. Forcer une pression mémoire pour déclencher la migration automatique
# (sur node-a, dans une VM ou depuis le host)
stress-ng --vm 1 --vm-bytes 90% --timeout 60s &
# Surveiller dans les logs
watch -n 2 "journalctl -u omega-daemon --since '10s ago' | grep migrat"

# 5. Vérifier que la VM est bien passée sur node-b
pvesh get /nodes/node-b/qemu/901/status/current | grep status
# → should return "running"

# 6. Vérifier le cleanup sur node-a
curl http://node-a:7200/control/quotas | python3 -m json.tool
# → VM 901 ne doit plus apparaître
curl http://node-a:7200/control/vcpu/status | python3 -m json.tool
# → slots de VM 901 libérés
```

### Métriques de migration à surveiller

| Métrique | Valeur attendue | Problème si |
|---|---|---|
| Durée migration live | 30s–3 min | > 10 min → dirty rate trop élevé |
| Downtime live | < 1s | > 5s → réseau saturé |
| Durée migration cold | 1–5 min | > 15 min → disque lent |
| Pages supprimées post-migration | = pages distantes de la VM | 0 → cleanup raté |
| vCPU libérés post-migration | = slots de la VM | 0 → release_vm raté |
| RAM disponible après migration | augmente sur source | inchangé → bug store |
