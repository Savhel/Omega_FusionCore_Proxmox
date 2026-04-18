# omega-remote-paging

Prototype d'ingénierie de **mémoire distante paginée** pour cluster Proxmox VE (3 nœuds).

## Concept

Quand la RAM du nœud A (compute) est sous pression, les pages froides sont externalisées vers la RAM des nœuds B et C (memory stores). En cas de réaccès, un page fault est intercepté par `userfaultfd` et la page est rapatriée depuis le store distant en TCP.

```
Nœud A (VM)           Nœud B (store)    Nœud C (store)
  │                       │                   │
  │  page fault ──────►   │                   │
  │  GET_PAGE   ◄──────   │  (page_id pair)   │
  │                       │                   │
  │  PUT_PAGE   ──────────────────────────►   │  (page_id impair)
  │                                           │
```

## Architecture rapide

| Composant        | Langage | Nœud | Rôle                                     |
|------------------|---------|------|------------------------------------------|
| `node-bc-store`  | Rust    | B, C | Store TCP de pages en RAM                |
| `node-a-agent`   | Rust    | A    | userfaultfd + client store               |
| `controller`     | Python  | any  | Politique de paging + monitoring         |

- **Protocole** : binaire TCP, trame 20 octets, page 4096 octets
- **Distribution** : `page_id % num_stores` (déterministe, sans état)
- **Sélection** : pages paires → B, pages impaires → C

## Démarrage rapide

### Prérequis

```bash
# Rust 1.75+
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Python 3.10+
cd controller && pip install -r requirements.txt

# userfaultfd sans root (kernel ≥ 5.11)
echo 1 | sudo tee /proc/sys/vm/unprivileged_userfaultfd
```

### Compilation

```bash
make build
```

### Test en local (3 nœuds simulés sur 1 machine)

```bash
# Lance les stores + l'agent demo + vérifie l'intégrité
make scenario

# Ou étape par étape :
make store-b &    # store B sur :9100
make store-c &    # store C sur :9101
make agent-demo   # scénario de validation
```

### Déploiement sur cluster réel

```bash
export NODE_B=192.168.1.2
export NODE_C=192.168.1.3
./scripts/deploy.sh

# Lancer l'agent sur nœud A
./target/release/node-a-agent \
    --stores "$NODE_B:9100,$NODE_C:9101" \
    --vm-id 100 --region-mib 512 --mode daemon
```

### Controller

```bash
# Statut du cluster
make controller-status

# Monitoring en continu (10s)
make controller-monitor

# Évaluation de la politique une fois
make controller-policy
```

## Tests

```bash
make test            # Tous les tests (Rust + Python)
make test-rust       # Tests unitaires Rust
make test-python     # Tests unitaires Python (controller)
make test-integration # Test intégration store
```

## Structure

```
omega-remote-paging/
├── Cargo.toml              # Workspace Rust
├── Makefile
├── node-a-agent/           # Agent userfaultfd (Rust)
│   └── src/
│       ├── main.rs         # Entrée + scénario demo
│       ├── uffd.rs         # FFI Linux userfaultfd
│       ├── remote.rs       # Client TCP stores
│       ├── memory.rs       # mmap + éviction
│       ├── metrics.rs      # Compteurs atomiques
│       └── config.rs       # CLI clap
├── node-bc-store/          # Store de pages (Rust)
│   └── src/
│       ├── main.rs         # Entrée
│       ├── protocol.rs     # Sérialisation TCP
│       ├── store.rs        # DashMap<PageKey, [u8]>
│       ├── server.rs       # Tokio TCP server
│       ├── metrics.rs      # Stats atomiques
│       └── config.rs       # CLI clap
├── controller/             # Controller de politique (Python)
│   └── controller/
│       ├── main.py         # CLI click
│       ├── policy.py       # PolicyEngine (3 décisions)
│       ├── metrics.py      # MetricsCollector (/proc)
│       ├── proxmox.py      # ProxmoxClient stub (V2)
│       └── store_client.py # Client TCP Python
├── scripts/                # Scripts Bash utilitaires
├── tests/                  # Tests intégration + protocole
└── docs/                   # Architecture, protocole, métriques
```

## Documentation

- [Architecture](docs/architecture.md)
- [Protocole réseau](docs/protocol.md)
- [Guide des expériences](docs/experiments.md)
- [Métriques](docs/metrics.md)

## Limites V1

- Politique d'éviction basique (séquentielle, pas LRU)
- Pas de réplication entre B et C (si B tombe, pages paires perdues)
- Canal de contrôle controller→agent absent (décisions non exécutées)
- userfaultfd nécessite root ou configuration kernel sur kernels < 5.11
- Pas de chiffrement ni d'authentification sur le canal TCP

Voir [docs/experiments.md](docs/experiments.md) pour le plan de test complet.

## Plan V2

- Canal de contrôle HTTP agent←controller
- Politique LRU d'éviction
- Réplication B↔C
- Endpoint métriques Prometheus
- Préfetch basé sur la localité
- Intégration API Proxmox (migration automatique)

## Plan V3+

- Transport RDMA (InfiniBand / RoCE)
- Intégration hooks QEMU pour le paging au niveau hyperviseur
- Distribution avec consistent hashing
- Tolérance aux pannes (réplication n+1)
# Omega_FusionCore_Proxmox
# Omega_FusionCore_Proxmox
