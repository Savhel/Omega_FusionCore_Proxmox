# omega-remote-paging

Système de mutualisation de RAM entre les nœuds d'un cluster Proxmox VE 3 nœuds.

---

## Le problème

Dans un cluster Proxmox standard, la RAM est cloisonnée par nœud. Si le nœud A est à 90% et les nœuds B et C sont à 30%, Proxmox refuse de créer de nouvelles VMs sur A — même si le cluster a collectivement de la mémoire disponible.

De plus, une VM configurée avec 8 Go de RAM ne les utilise pas tous en permanence. Une partie est "froide" : des données rarement accédées qui occupent de la RAM physique sans être utiles à court terme.

---

## Ce que fait ce projet

### 1. Paging distant

Les pages mémoire froides d'une VM (4 Ko chacune) sont déplacées vers la RAM d'un autre nœud du cluster. La RAM locale est ainsi libérée pour d'autres VMs.

Quand la VM a besoin d'une page qui est sur un autre nœud :

```
1. La VM accède à l'adresse → page fault
2. Linux intercepte via userfaultfd (espace utilisateur, sans modifier le kernel)
3. omega-daemon envoie GET_PAGE au nœud qui stocke la page
4. La page est copiée en RAM locale
5. La VM reprend son exécution — elle n'a rien vu
```

Latence typique : < 2 ms sur GbE. La VM ne sait pas que sa mémoire était à distance.

### 2. Contrôle des ressources par VM

Chaque VM a un budget strict : `RAM locale + RAM distante ≤ max configuré`. Il est impossible de dépasser ce budget — garanti à l'admission et à chaque écriture de page.

### 3. Migration automatique

Si un nœud est saturé (RAM > 85%) ou si une VM a trop de pages distantes (latence élevée), le système migre la VM vers un nœud moins chargé :

- **Migration live** : la VM continue de fonctionner pendant le transfert, downtime < 1s
- **Migration cold** : VM arrêtée, transférée, redémarrée — utilisée quand la VM est idle ou la pression critique

Les disques sont sur Ceph RBD (partagés), donc seule la RAM est transférée.

### 4. Scheduler vCPU élastique

Les vCPU sont alloués dynamiquement. Une VM démarre avec un minimum et reçoit des cœurs supplémentaires (hotplug) quand sa charge augmente, jusqu'à son plafond. Si le nœud est saturé en CPU, la migration est recommandée.

### 5. Multiplexeur GPU

Un GPU physique est partagé entre toutes les VMs d'un nœud. Chaque VM a un budget VRAM. Le daemon arbitre les accès et retourne les résultats à la bonne VM.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Cluster Proxmox — 3 nœuds                                 │
│                                                             │
│  Nœud A                  Nœud B              Nœud C        │
│  ┌─────────────┐         ┌─────────────┐     ┌──────────┐  │
│  │ VMs QEMU    │         │ omega-daemon│     │ omega-   │  │
│  │             │ ──TCP── │ (store)     │     │ daemon   │  │
│  │ omega-daemon│         │ port 9100   │     │ (store)  │  │
│  │ (compute    │         └─────────────┘     └──────────┘  │
│  │  + store)   │                                            │
│  └─────────────┘                                            │
│         ▲                                                   │
│         │ HTTP                                              │
│  ┌──────┴──────────────────────────────────────────────┐   │
│  │  omega-controller (Python)                          │   │
│  │  Collecte l'état des 3 nœuds, décide les           │   │
│  │  migrations, valide l'admission des nouvelles VMs   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Chaque nœud fait tourner le même `omega-daemon`. Selon sa position dans le cluster il joue simultanément le rôle de **compute** (ses VMs paguent vers les autres) et de **store** (il héberge les pages distantes des VMs des autres nœuds).

---

## Composants

### omega-daemon (Rust + Tokio)

Un seul binaire, un daemon par nœud.

| Module | Rôle |
|--------|------|
| `store_server.rs` | Reçoit et sert les pages distantes via TCP TLS (port 9100) |
| `eviction_engine.rs` | Surveille `/proc/meminfo`, envoie les pages froides vers les autres nœuds (algo CLOCK) |
| `fault_bus.rs` | Canal IPC entre le handler userfaultfd et le moteur d'éviction — adapte l'agressivité en temps réel |
| `vm_tracker.rs` | Détecte les VMs QEMU locales via les fichiers Proxmox |
| `quota.rs` | Budget strict RAM par VM, invariant garanti à chaque écriture |
| `vcpu_scheduler.rs` | Allocation élastique des vCPU, hotplug, steal time |
| `vm_migration.rs` | Lance `qm migrate` live ou cold, nettoie les ressources source |
| `gpu_multiplexer.rs` | Arbitre les accès GPU entre VMs, budget VRAM par VM |
| `cluster_api.rs` | API HTTP port 9200 — état du nœud pour le controller |
| `control_api.rs` | API HTTP port 9300 — canal de contrôle local (éviction, quotas, métriques Prometheus) |
| `tls.rs` | Certificat auto-signé, vérification par empreinte TOFU |
| `balloon.rs` | Lecture des stats mémoire internes des VMs via QMP |

### omega-controller (Python)

Un seul processus, tourne sur un nœud.

| Module | Rôle |
|--------|------|
| `admission.py` | Valide et place les nouvelles VMs (RAM locale + distante) |
| `cpu_admission.py` | Valide l'allocation vCPU à l'échelle du cluster |
| `gpu_admission.py` | Valide les budgets VRAM à l'échelle du cluster |
| `migration_policy.py` | Évalue quelles VMs migrer et en mode live ou cold |
| `migration_daemon.py` | Boucle de migration automatique via l'API Proxmox |
| `topology_placement.py` | Score de placement : RAM 50%, topologie 25%, CPU 15%, migrations actives 10% |
| `resilient_collector.py` | Collecte l'état des nœuds avec retry + circuit-breaker (données en cache 120s) |
| `lxc_monitor.py` | Surveille la pression mémoire des conteneurs LXC via cgroups v2 PSI |
| `proxmox.py` | Client API REST Proxmox (migrations, état des nœuds) |

---

## Protocoles réseau

**Inter-nœuds (port 9100, TCP + TLS)**

Protocole binaire, trame fixe 20 octets + payload :

```
│ magic 2B │ opcode 1B │ flags 1B │ vm_id 4B │ page_id 8B │ payload_len 4B │ payload │
```

Opcodes : `PUT_PAGE`, `GET_PAGE`, `DELETE_PAGE`, `PING/PONG`, `OK`, `NOT_FOUND`, `ERROR`, `STATS_REQUEST/RESPONSE`.

**Daemon ↔ Controller (port 9200/9300, HTTP)**

JSON sur HTTP plain. Le port 9200 est accessible par le cluster entier. Le port 9300 est local uniquement.

---

## Ce que ce projet ne fait pas

- Ne modifie pas le kernel Linux — tout fonctionne en espace utilisateur via userfaultfd
- Ne remplace pas QEMU/KVM — la virtualisation reste inchangée
- Ne gère pas les disques des VMs — uniquement la RAM
- Ne remplace pas Proxmox HA — la tolérance aux pannes nœud reste celle de Proxmox natif
- Ne compresse pas les pages (optionnel, non activé par défaut)

---

## Prérequis

- Proxmox VE 8.x ou 9.x, 3 nœuds
- Ceph RBD pour le stockage des disques VMs (partagé entre nœuds)
- Rust 1.75+ (compilation sur la machine de dev)
- Python 3.10+

## Documentation

| Fichier | Contenu |
|---------|---------|
| `docs/installation.md` | Déploiement pas à pas sur le cluster |
| `docs/developpement-et-deploiement.md` | Workflow dev → lab → prod |
| `docs/architecture.md` | Flux de données détaillés |
| `docs/fonctionnement-complet.md` | Chaque décision expliquée |
| `docs/cluster-kvm.md` | Monter un lab KVM sur une machine physique |
| `docs/cluster-physique.md` | Déploiement sur machines physiques |
| `docs/utilisation-physique.md` | Commandes opérationnelles |
| `docs/metrics.md` | Métriques Prometheus disponibles |
| `docs/protocol.md` | Protocole TCP binaire détaillé |
