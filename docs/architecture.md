# Architecture — omega-remote-paging V4

## Vue d'ensemble

```
┌─────────────────────────────────────────────────────────────────────┐
│  Cluster Proxmox (3 nœuds)                                          │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Nœud A (compute + store)                                    │   │
│  │                                                              │   │
│  │  VMs QEMU/KVM                                               │   │
│  │    VM 100 : 8 Gio RAM max                                   │   │
│  │    VM 101 : 4 Gio RAM max                                   │   │
│  │         │ page fault (userfaultfd)                          │   │
│  │  ┌──────▼──────────────────────────────────────────────┐   │   │
│  │  │  omega-daemon (Rust + Tokio)                         │   │   │
│  │  │                                                      │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │   │   │
│  │  │  │ Store TCP   │  │ Eviction    │  │ vCPU       │  │   │   │
│  │  │  │ :9100 (TLS) │  │ Engine      │  │ Scheduler  │  │   │   │
│  │  │  └─────────────┘  └─────────────┘  └────────────┘  │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │   │   │
│  │  │  │ Cluster API │  │ VM Tracker  │  │ Migration  │  │   │   │
│  │  │  │ :9200       │  │             │  │ Executor   │  │   │   │
│  │  │  └─────────────┘  └─────────────┘  └────────────┘  │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │   │   │
│  │  │  │ Control API │  │ Quota       │  │ Fault Bus  │  │   │   │
│  │  │  │ :9300       │  │ Registry    │  │ (IPC)      │  │   │   │
│  │  │  └─────────────┘  └─────────────┘  └────────────┘  │   │   │
│  │  └──────────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Même daemon tourne aussi sur Nœud B et Nœud C                     │
│  (rôle store + monitoring local)                                    │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  omega-controller (Python — tourne sur nœud A)              │   │
│  │                                                              │   │
│  │  MigrationPolicy   → GET /control/status (chaque nœud)      │   │
│  │  MigrationExecutor → POST /control/migrate (nœud source)    │   │
│  │  AdmissionEngine   → contrôle RAM/vCPU/GPU à l'admission    │   │
│  │  CgroupCpuMonitor  → lecture cgroups v2 en temps réel       │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Flux de données — éviction d'une page

```
1. Pression mémoire détectée (mem_available < seuil)
2. EvictionEngine sélectionne les pages froides (algorithme CLOCK)
3. Page envoyée via PUT_PAGE TCP (TLS) → store du nœud B ou C
4. madvise(MADV_DONTNEED) → page libérée du page table local
5. Page marquée "distante" dans le VM Tracker
```

## Flux de données — récupération d'une page (page fault)

```
1. VM accède à une adresse dont la page est distante
2. Kernel intercepte le page fault (userfaultfd)
3. omega-daemon reçoit l'événement via FaultBus
4. GET_PAGE TCP (TLS) → nœud qui stocke la page
5. UFFDIO_COPY → page copiée en RAM locale
6. VM reprend son exécution (<2ms sur GbE)
```

## Flux de données — migration live

```
1. MigrationPolicy détecte un nœud surchargé (RAM, CPU ou GPU réservé)
2. Le controller choisit automatiquement un nœud Y qui peut accueillir la VM
3. POST /control/migrate sur nœud source
4. MigrationExecutor lance : qm migrate {vmid} {target} --online
5. KVM pre-copy : RAM transférée page par page (VM reste active)
6. Bascule finale : downtime < 1s
7. cleanup_after_migration() : supprime pages store, libère slots vCPU, quotas RAM et budgets GPU
```

## Flux de données — migration cold

```
Identique sauf :
  - VM stoppée avant transfert (qm migrate sans --online)
  - Pas de dirty pages à gérer
  - Forcée si RAM > 95% (live ne converge pas) ou VM idle > 60s
```

## Composants du daemon (omega-daemon, Rust)

### Store TCP (port 9100, TLS)
Accepte les pages envoyées par d'autres nœuds. Index `DashMap<(vm_id, page_id) → [u8; 4096]>`, sharded, sans verrou global. Chiffrement TLS avec certificats auto-signés, vérification par empreinte (TOFU).

### Cluster API (port 9200, HTTP)
Expose l'état du nœud : RAM, pages stockées, VMs locales avec leur `avg_cpu_pct`, `throttle_ratio`, `remote_pages`, ainsi que l'état GPU local (backend, VRAM totale, VRAM libre, budgets réservés). Interrogé par le controller Python.

### Control API (port 9300, HTTP)
Canal de contrôle local : éviction, quotas par VM, vCPU, budgets GPU, migrations live/cold, métriques Prometheus (`/control/metrics`) et état GPU (`/control/gpu/status`).

### Eviction Engine
Surveille `/proc/meminfo`. Quand `mem_available < seuil`, sélectionne les pages froides (CLOCK) et les envoie au nœud avec le meilleur `placement_score`. Taux d'éviction adapté via `AdaptiveInterval` selon la pression du FaultBus.

### Fault Bus
Canal IPC interne (tokio mpsc) entre le handler uffd et l'EvictionEngine. Chaque page fault notifie le bus → l'EvictionEngine accélère ou ralentit en conséquence.

### Quota Registry
Budget par VM : `max_mem_mib` (local + distant). Aucune page ne peut être stockée si le quota est dépassé. Invariant garanti à chaque PUT_PAGE.

### VM Tracker
Détecte les VMs QEMU via `/var/run/qemu-server/{vmid}.pid` et `/etc/pve/qemu-server/{vmid}.conf`. Compteurs de pages distantes par VM.

### vCPU Scheduler
Allocation élastique : 3 vCPU par pCPU, jusqu'à 3 VMs par slot. Hotplug si usage > 80%. Si le hotplug réel via QMP n'est plus possible ou si le nœud reste trop throttlé, l'état remonté par le scheduler pousse le controller à migrer automatiquement la VM vers un autre nœud.

### Migration Executor
Lance `qm migrate {vmid} {target} [--online]` via `tokio::process::Command`. Ceph RBD : disques partagés, seule la RAM est transférée (live) ou la VM redémarre sur le même disque (cold). Suivi par task_id. Nettoyage post-migration : supprime les pages store, libère les slots vCPU, retire le quota.

### GPU Multiplexer
Partage d'un GPU physique entre plusieurs VMs. Budget VRAM configurable par VM via `/control/vm/{vmid}/gpu`, état exposé via `/control/gpu/status`, contraintes VRAM remontées au controller pour le placement et la migration.

## Composants du controller (Python)

### MigrationPolicy
Vue cluster-wide. Collecte `GET /control/status` sur les 3 nœuds. Décide : quoi migrer, vers où, live ou cold. Règles : RAM > 95% → cold forcée, RAM 85–95% → live, VM idle > 60s → cold, VM throttlée → live, GPU réservé trop haut → migration vers un nœud avec assez de VRAM libre.

### AdmissionEngine
À la création d'une VM : sélectionne le nœud cible, calcule le budget `local + remote = max_mem`, envoie la config au daemon.

### CgroupCpuMonitor
Lecture des cgroups v2 en temps réel (fenêtre glissante 100ms). Callbacks CPU_HIGH / CPU_IDLE / THROTTLE. Alimente le `VcpuScheduler` du daemon via `update_from_cgroup()`.

### TopologyPlacement
Score multi-critères pour le placement : RAM (50%), topologie réseau (25%), charge CPU (15%), migrations actives (10%).

### ResilientCollector
Collecte avec circuit-breaker. Nœud injoignable → isolation temporaire, données en cache (120s).

## Distribution des pages entre nœuds

Sélection déterministe : `hash(vm_id, page_id) % num_stores`.
Réplication factor configurable (défaut : 2 — chaque page sur 2 nœuds).

## Ports réseau

| Port | Protocole | Usage |
|------|-----------|-------|
| 9100 | TCP + TLS | Store de pages (inter-nœuds) |
| 9200 | HTTP | API cluster (état du nœud) |
| 9300 | HTTP | API contrôle (local uniquement) |
