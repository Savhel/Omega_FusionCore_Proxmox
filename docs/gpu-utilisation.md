# Utilisation du GPU dans Omega — guide complet

Ce document explique **comment le GPU est utilisé de bout en bout** dans le cluster
Omega : le matériel, les deux voies d'accès (proxy applicatif par jobs et
gateway LLM Ollama), comment une VM en bénéficie, et les commandes. Il complète
[gpu-proxy-applicatif.md](gpu-proxy-applicatif.md) (détail de l'API du proxy).

---

## 1. Principe directeur : pas de passthrough

Omega **ne donne jamais une carte GPU PCI à une VM** (pas de VFIO/passthrough,
pas de vGPU). Raisons :

- le **passthrough monopolise** la carte pour une seule VM ;
- il **casse la live‑migration** (la VM est clouée au nœud) ;
- il exige **IOMMU + reboot** du nœud.

À la place, Omega **partage le GPU au niveau applicatif** : le GPU reste piloté
par l'hôte (pilote NVIDIA chargé sur le nœud), et les VMs **consomment la
puissance GPU via le réseau**, par une API. Conséquence : une VM **n'a aucun
`/dev/nvidia*`**, reste **isolée**, et reste **migrable**.

> Corollaire important : un logiciel qui exige un **vrai device CUDA local +
> NVML** dans la VM (ex. **Ollama/llama.cpp**) ne peut pas voir un « GPU
> virtuel ». Il faut donc faire tourner ce logiciel **là où est le GPU** (sur le
> nœud) et exposer son **API** aux VMs. C'est exactement la voie B ci‑dessous.

---

## 2. Le matériel GPU du cluster

Seuls **3 nœuds sur 7** ont une carte (vérifiable par `nvidia-smi -L`) :

| Nœud   | IP              | GPU            | VRAM   |
|--------|-----------------|----------------|--------|
| emilia | 192.168.123.100 | RTX 2080 Ti    | 11 Go  |
| ram    | 192.168.123.101 | RTX 3090 Ti    | 24 Go  |
| rem    | 192.168.123.102 | RTX 3090 Ti    | 24 Go  |

`blade`, `gandal`, `genesis`, `bris` n'ont pas de GPU : leurs VMs peuvent
**consommer** la puissance GPU par le réseau, mais pas calculer en local.
Pool total ≈ **2×24 Go + 11 Go ≈ 59 Go de VRAM**.

Les 3 nœuds GPU sont déclarés dans `scripts/cluster.conf` :

```bash
OMEGA_GPU_NODES="192.168.123.100,192.168.123.101,192.168.123.102"
OMEGA_GPU_PRIMARY_NODE=""   # vide = 1er nœud GPU détecté (mettre un 3090 de préférence)
OMEGA_GPU_PROXY_URL=""       # vide = dérivée du nœud primaire
```

---

## 3. Les deux voies d'accès au GPU

Omega expose **deux voies complémentaires**, selon le besoin :

### Voie A — Proxy applicatif par **jobs** (`omega-gpu-proxy`, port 9400)

Pour des **calculs ponctuels** (one‑shot). La VM (ou l'hôte) **soumet un job
HTTP** au proxy ; le proxy l'exécute sur le GPU de l'hôte via un *worker*, puis
renvoie le résultat. Familles de jobs supportées
(`scripts/omega-gpu-worker-app.py`) :

| `kind`            | Moteur                                   |
|-------------------|------------------------------------------|
| `matrix_multiply` | PyTorch CUDA (sinon CPU)                  |
| `inference`       | ONNX Runtime (si `model_path`)            |
| `video_encode`    | ffmpeg `h264_nvenc`/`hevc_nvenc`          |
| `render`          | Blender batch (Cycles GPU)               |
| `custom`          | commande explicite (désactivée par défaut)|

Caractéristiques : **budget VRAM logique par VM** (`omega_gpu_vram_mib`), file
d'attente à concurrence limitée, refus hors budget, métriques Prometheus, token
d'API. Détail complet dans [gpu-proxy-applicatif.md](gpu-proxy-applicatif.md).

### Voie B — Gateway **LLM** (Ollama + LiteLLM)

Pour des **services LLM persistants** (chatbots, assistants, génération). Comme
Ollama exige un vrai GPU local, on lance **un serveur Ollama sur chaque nœud
GPU** (conteneur Docker `--gpus all`, port `11434`, pilote hôte injecté par
`nvidia-container-toolkit` → pas de passthrough, pas de reboot), puis **une
gateway LiteLLM unique** (OpenAI‑compatible) devant eux :

```
VM / console ──HTTP──▶ Gateway LiteLLM (emilia:4000, API OpenAI)
                              │ route par modèle · load‑balance · fallback santé
              ┌───────────────┼───────────────────┐
         Ollama emilia    Ollama ram          Ollama rem
          (2080Ti 11Go)   (3090Ti 24Go)       (3090Ti 24Go)
```

- **Endpoint unique** : `http://192.168.123.100:4000/v1` (token dans
  `/etc/omega/llm-gateway.token`).
- **Routage** : gros modèles (14B…) → les 3090 24 Go ; petits modèles →
  load‑balance sur les 3 nœuds. Stratégie `least-busy`, `num_retries`,
  fallback si un nœud tombe.
- **Config** : `/opt/omega-llm/config.yaml` (générée depuis les modèles réels de
  chaque nœud via `GET /api/tags`).

---

## 4. Comment une VM utilise le GPU (de bout en bout)

### a) Déclarer un budget VRAM sur la VM

Dans la config Proxmox de la VM, la métadonnée Omega :

```
#... omega_gpu_vram_mib=8192 ...
```

C'est un **budget logique** (placement + quota), pas un device. Réglable depuis
la console (inspecteur VM → « GPU / VRAM ») ou `omega-lab.sh` (option `[m]`).

### b) Le contrôleur GPU global décide du placement

Pour une VM ayant `omega_gpu_vram_mib > 0`, le contrôleur (modules Rust
`gpu_placement.rs`, `gpu_scheduler.rs`, `gpu_multiplexer.rs`,
`policy_engine.rs`) choisit :

1. **`local_gpu`** — la VM est déjà sur un nœud GPU avec assez de VRAM → on
   configure son budget localement ;
2. **`migrate_to_gpu`** — la VM est sur un nœud sans GPU mais une cible GPU peut
   l'accueillir → migration proactive (`OMEGA_GPU_MIGRATE_TO_GPU_NODE=1`) ;
3. **`remote_proxy`** — sinon, la VM reste où elle est et **appelle le GPU par
   le réseau** (`OMEGA_GPU_FALLBACK_NETWORK=1`) ;
4. **refus** si rien n'est possible (journalisé).

### c) Ouvrir l'accès réseau de la VM au GPU/LLM

Les VMs Omega sont **isolées par défaut**. Pour qu'une VM `vram>0` atteigne la
gateway LLM, une **règle pfSense étroite** est posée (la VM ne peut joindre
**que** l'hôte gateway, rien d'autre du LAN) :

- **automatique** : un **réconciliateur** (`omega-llm-access-reconciler.sh`)
  garantit en continu que *toute VM démarrée avec `omega_gpu_vram_mib > 0`* a
  l'accès. Déployé sur le contrôleur avec un **timer systemd**
  (`omega-llm-access-reconciler.timer`, toutes les ~3 min) ;
- **à la demande** : `scripts/llm-access.sh --vmid <id> --enable`.

### d) La VM consomme

- **LLM** : la VM (ou la console GANDAL / `cli-llm`) pointe sur la gateway :

  ```bash
  export OPENAI_BASE_URL=http://192.168.123.100:4000/v1
  export OPENAI_API_KEY=$(cat /etc/omega/llm-gateway.token)   # côté serveur
  # ou directement un nœud : OLLAMA_HOST=http://192.168.123.102:11434
  ```

- **Jobs GPU** : la VM soumet un job au proxy `:9400`
  (`scripts/omega-gpu-client.sh ... matmul|inference|encode|render`).

---

## 5. Commandes (depuis `scripts/omega-lab.sh`)

| Commande                                 | Effet |
|------------------------------------------|-------|
| `./omega-lab.sh --llm`  · menu `[L]`     | Monte la **stack LLM** : Ollama‑GPU sur chaque nœud GPU + gateway LiteLLM + maj `cluster.env`. Idempotent. |
| `./omega-lab.sh --llm-access` · menu `[W]`| Ouvre l'accès **gateway** à une VM / `all` / `reconcile` (auto `vram>0`). |
| `./omega-lab.sh --llm-access-reconcile`  | Réconcilie l'accès LLM de toutes les VMs `vram>0` (idéal en timer). |
| `--llm-access-reconcile --dry-run`       | Montre ce qui serait fait, sans appliquer. |

Côté **GANDAL‑API** (console) :

- `POST /cluster/vms/{id}/llm-access` — ouvre/ferme l'accès gateway d'une VM ;
- `POST /cluster/llm-access/reconcile?prune=` — réconcilie (admin) ;
- `GET  /cluster/gpu` — état des GPU (utilisation, VRAM, température).

---

## 6. Vérifications rapides

```bash
# Les 3 nœuds voient bien leur GPU :
for n in 100 101 102; do ssh root@192.168.123.$n 'hostname; nvidia-smi --query-gpu=name,memory.total --format=csv,noheader'; done

# La gateway répond et liste les modèles :
TOKEN=$(ssh root@192.168.123.100 cat /etc/omega/llm-gateway.token)
curl -s http://192.168.123.100:4000/v1/models -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

# Inférence GPU (la VRAM doit monter pendant la requête) :
curl -s http://192.168.123.100:4000/v1/chat/completions -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:3b","messages":[{"role":"user","content":"Bonjour"}]}'

# Règles d'accès LLM chargées dans pfSense :
ssh root@192.168.123.100 'ssh admin@192.168.123.200 "pfctl -sr | grep omega-llm"'
```

---

## 7. Récapitulatif des responsabilités

| Couche | Rôle |
|--------|------|
| **Ollama / LiteLLM** (par nœud GPU) | Charge les modèles, exécute CUDA, concurrence intra‑nœud |
| **omega-gpu-proxy** (`:9400`) | Jobs GPU one‑shot (matmul/ONNX/nvenc/render) + budgets |
| **Contrôleur GPU** (Rust) | Placement inter‑nœuds (`local_gpu`/`migrate_to_gpu`/`remote_proxy`), quotas |
| **Réconciliateur LLM‑access** (+timer) | Ouvre/maintient l'accès réseau `vram>0 → gateway` |
| **GANDAL‑API / console** | Pilotage (budget VRAM, accès, état GPU) |

**En une phrase** : Omega ne virtualise pas la carte, il **met le moteur GPU sur
le nœud et route les VMs vers lui** (par jobs pour le calcul, par la gateway
OpenAI pour les LLM), tout en gardant les VMs **isolées et migrables**.
