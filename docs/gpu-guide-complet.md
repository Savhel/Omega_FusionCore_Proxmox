# Guide complet du GPU dans Omega/GANDAL

*Mis à jour le 29 juin 2026 — reflète l'état réel du cluster (emilia/ram/rem).*

Ce document résume **tout ce qui a été mis en place autour du GPU** et explique
**comment l'utiliser dans les trois formes** que le projet propose. Il est
volontairement autonome : pour le détail d'implémentation voir aussi
[`gpu-proxy-applicatif.md`](gpu-proxy-applicatif.md) et
[`gpu-utilisation.md`](gpu-utilisation.md).

---

## 1. Le matériel

| Nœud | GPU | VRAM | Rôle GPU |
|------|-----|------|----------|
| **emilia** (192.168.123.100) | RTX 2080 Ti | 11 Go | contrôleur + serving LLM + jobs |
| **ram** (192.168.123.101) | RTX 3090 Ti | 24 Go | serving LLM (gros modèles) + jobs + entraînement |
| **rem** (192.168.123.102) | RTX 3090 Ti | 24 Go | **jobs + entraînement uniquement** (voir §6) |
| blade / gandal / genesis / bris | — | — | aucun GPU |

**Principe fondateur :** le pilote NVIDIA est chargé **côté hôte** (`nvidia-smi`
fonctionne sur l'hôte), le GPU n'est **jamais** passé en PCI passthrough à une VM.
Conséquence : les VMs Omega n'ont **jamais** `/dev/nvidia*`. Cela **préserve la
live-migration** (pas de device PCI attaché) — c'est un choix d'architecture
assumé, pas une limitation accidentelle.

Comme une VM n'a pas de device CUDA local, on expose le GPU **par le réseau**,
de trois façons complémentaires décrites ci-dessous.

---

## 2. Les trois formes d'utilisation du GPU

```
                         ┌─────────────────────────────────────────────┐
                         │                 NŒUD GPU                     │
   VM Omega (isolée)     │   pilote NVIDIA hôte + /dev/nvidia*          │
   pas de /dev/nvidia    │                                              │
        │                │   (1) omega-gpu-proxy   :9400  jobs one-shot │
        │  réseau étroit  │   (2) Ollama (Docker)   :11434  LLM serving │
        ├───────────────▶│       + gateway LiteLLM :4000  (sur emilia) │
        │   (pfSense)     │   (3) LXC entraînement  CT 9500  Jupyter    │
        ▼                │                                              │
   soumet un job /        └─────────────────────────────────────────────┘
   appelle une API
```

| Forme | Pour quoi | Endpoint | Nœuds |
|-------|-----------|----------|-------|
| **(1) Proxy de jobs** | calcul GPU ponctuel (matmul, inference ONNX, encodage vidéo nvenc, rendu Blender) | `:9400` | emilia, ram, **rem** |
| **(2) Serving LLM** | inférence de modèles de langage (chat, complétion, RAG) | Ollama `:11434` / gateway `:4000` | emilia, ram *(rem exclu, §6)* |
| **(3) Entraînement** | entraîner un modèle (PyTorch/TF, boucle epochs, checkpoints) | LXC + Jupyter `:8888` / SSH | ram, **rem** (CT 9500) |

---

## 3. Forme (1) — Le proxy de jobs `omega-gpu-proxy` (:9400)

**Ce que c'est :** un service applicatif qui exécute des **jobs prédéfinis** sur
le GPU de l'hôte et renvoie le résultat. La VM n'exécute pas de code GPU
arbitraire : elle **soumet un job** par HTTP.

**Types de jobs supportés :** `matrix_multiply` (PyTorch), `inference` (ONNX
Runtime), `video_encode` (nvenc), `render` (Blender).

**Budget VRAM logique :** chaque VM a un champ de conf `omega_gpu_vram_mib`
(ex. 8192). Ce n'est **pas** un device, c'est un **quota comptable** que le
contrôleur GPU global utilise pour décider, par VM : `local_gpu` /
`migrate_to_gpu` / `remote_proxy` / refus (placement GPU-aware).

**rem est pleinement utilisable ici** : un job ne fait quasiment pas d'I/O disque,
donc l'état dégradé du disque local de rem (§6) n'a pas d'impact.

> Détails et exemples de payloads : [`gpu-proxy-applicatif.md`](gpu-proxy-applicatif.md).

---

## 4. Forme (2) — Le serving LLM (Ollama + gateway LiteLLM)

C'est la forme « IA générative » : servir des modèles de langage à grande échelle.

### 4.1 Architecture

- Sur chaque nœud GPU tourne un conteneur Docker **`dex-ollama-worker`**
  (`ollama/ollama:latest`, runtime nvidia `--gpus all`), écoute `:11434`.
  Défini par un compose `ollama_worker` (`/home/<user>/ollama_worker/`).
- Sur **emilia** tourne en plus la **gateway `omega-llm-gateway`** (LiteLLM,
  conteneur `ghcr.io/berriai/litellm`), écoute **`:4000`**, API **compatible
  OpenAI** (`/v1/chat/completions`). Config : `/opt/omega-llm/config.yaml`,
  token : `/etc/omega/llm-gateway.token`.
- La gateway **agrège les Ollama** des nœuds et **load-balance** : les gros
  modèles (14B) sont répartis sur les GPU 24 Go (ram + emilia), les petits sur
  l'ensemble. Stratégie `least-busy`, avec retries/fallback.

### 4.2 Modèles disponibles (état au 29 juin 2026)

| Nœud | Modèles servis |
|------|----------------|
| **ram** (3090 Ti 24 Go) | 13 modèles, dont `deepseek-r1:14b`, `qwen2.5:14b`/`1.5b`, `mistral:7b-instruct` (+16k/32k/48k), `llama3`, `llama3.2:3b`, `gemma3:4b`/`gemma3n:e2b`, `phi4-mini` |
| **emilia** (2080 Ti 11 Go) | 8 modèles : les 4 petits d'origine + **`deepseek-r1:14b`, `qwen2.5:14b`, `mistral:7b-instruct`, `llama3`** (copiés depuis ram) |
| **rem** | **vide** — exclu du serving (§6) |

> Les modèles ont été **copiés de nœud à nœud** (store Ollama `models/{blobs,manifests}`)
> plutôt que retéléchargés, puis `docker restart dex-ollama-worker` pour les détecter.

### 4.3 Comment une VM/un service l'utilise

Pointer le client sur la gateway (recommandé, car load-balancée) :

```bash
# API OpenAI-compatible
curl http://192.168.123.100:4000/v1/chat/completions \
  -H "Authorization: Bearer $(cat /etc/omega/llm-gateway.token)" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:14b","messages":[{"role":"user","content":"Bonjour"}]}'
```

Ou directement un Ollama de nœud (sans load-balancing) :

```bash
curl http://192.168.123.101:11434/api/generate \
  -d '{"model":"deepseek-r1:14b","prompt":"Explique la fission"}'
```

### 4.4 Accès réseau automatique (règle « vram>0 → accès LLM »)

Décidé par l'utilisateur : **toute VM Omega *running* avec `omega_gpu_vram_mib > 0`
doit pouvoir joindre la gateway `:4000`**. « Accès GPU » = **accès réseau étroit
à la gateway** (les VMs restent isolées, pas de device).

Implémenté par :
- `scripts/llm-access.sh` — pose une règle pfSense PASS+NAT **étroite**
  (src VM → gateway `:4000` uniquement).
- `scripts/omega-llm-access-reconciler.sh` — scanne les confs, résout l'IP des
  VMs via `pvesh agent`, applique l'accès ; **timer systemd** sur emilia
  (`omega-llm-access-reconciler.timer`, ~3 min). Options `--dry-run`/`--prune`/`--threshold`.
- Côté GANDAL-API : endpoints `POST /cluster/vms/{id}/llm-access` et
  `POST /cluster/llm-access/reconcile`.

### 4.5 Lancer / réparer toute la pile en une commande

```bash
./scripts/omega-lab.sh --llm        # ou menu [L]
```

Idempotent : détecte les nœuds GPU, assure un Ollama-GPU par nœud (réutilise
l'existant, ré-attache si NVML KO), régénère la config LiteLLM depuis les
`/api/tags` réels, déploie la gateway, met à jour `cluster.env`.

---

## 5. Forme (3) — L'entraînement de modèles (LXC GPU)

**Pourquoi pas dans une VM :** entraîner (PyTorch/TF, `model.to('cuda')`, boucle
epochs/checkpoints) exige un **vrai device CUDA local + NVML** dans le contexte
d'exécution — or les VMs n'ont pas `/dev/nvidia*`. Même cause racine qu'Ollama.

**Solution : un conteneur LXC directement sur un nœud GPU**, avec
**bind-mount de `/dev/nvidia*`** (partage le pilote hôte, pas de passthrough, pas
de reboot, multi-tenant). On obtient un vrai CUDA, `pip torch`, datasets montés,
Jupyter/SSH.

**Déployé : CT 9500 « omega-train-rem » sur rem** :
- RTX 3090 Ti 24 Go visible **dans le conteneur** (`nvidia-smi` y fonctionne),
- **Jupyter** actif sur `:8888`, venv `/opt/ml`, espace utilisateur `/home/etu3009`,
- userspace NVIDIA = version **exacte** de l'hôte (550.x) — indispensable avec un
  bind-mount (pas de passthrough).
- Le rootfs du CT est sur **Ceph rbd** (`stockage.ceph`), donc il **ne dépend pas**
  du disque local dégradé de rem (§6) — l'entraînement reste possible sur rem.

Une VM accède au LXC via Jupyter/SSH (port ouvert dans pfSense). Le rôle d'Omega
est conservé : placement (nœud GPU + VRAM libre), quota `omega_gpu_vram_mib`,
publication de l'endpoint, ouverture du port. L'entraînement tourne **dans le
LXC**, pas dans la VM isolée.

Dans le workspace GANDAL, le nœud « Pool GPU » apparaît en vert pointillé,
non-supprimable.

---

## 6. Cas particulier : le disque local de rem est dégradé

**Constat (29 juin 2026) :** le disque local de rem subit des **stalls I/O**
(thread de journal ext4 `jbd2` bloqué → nœud entier figé). Un simple bench
d'écriture de 2 Go a suffi à faire retomber le nœud `offline`. Pression I/O au
repos anormalement haute (PSI `some` ~70 %). C'est un **problème matériel**
(à rapprocher de l'OSD SMR `ST8000DM004` côté ram).

**Conséquences et règle adoptée :**

| Usage GPU de rem | Statut | Raison |
|------------------|--------|--------|
| **(1) Proxy de jobs** `:9400` | ✅ utilisable | calcul GPU, quasi pas de disque |
| **(3) Entraînement** CT 9500 | ✅ utilisable | rootfs sur Ceph rbd, pas le disque local |
| **(2) Serving LLM** | ❌ **exclu** | charger un modèle 14B (~9 Go) exige un **disque local rapide** ; le disque de rem stalle |

→ Le GPU de rem reste donc **sollicité pour les jobs et l'entraînement**, en plus
de ram et emilia. **Seul le serving des modèles d'IA** (Ollama/gateway) se limite
à **ram + emilia**.

**À faire (vrai correctif) :** remplacer le disque local de rem. Une copie des
modèles sur **CephFS** a été testée mais écartée : Ceph est lui-même dégradé en ce
moment (osd.1 crashé sur ram, osd.2 lent sur emilia) → débit ~5 Mo/s, soit
~30 min pour charger un modèle 14B — inutilisable pour du serving. CephFS reste
acceptable pour le rootfs d'un LXC d'entraînement (peu sensible au débit
séquentiel), pas pour Ollama.

> Note d'exploitation : après un reboot de rem, le conteneur `dex-ollama-worker`
> et le CT 9500 reviennent ; les VMs qui perdent leur IP (dérive de MAC netplan)
> sont réparées automatiquement par l'agent `omega-netfix-reconciler` (timer sur
> emilia).

---

## 7. Aide-mémoire des commandes

```bash
# Voir les GPU d'un nœud
ssh root@<nœud> nvidia-smi

# Modèles servis par un Ollama
curl -s http://192.168.123.101:11434/api/tags | python3 -m json.tool

# Santé de la gateway LLM
curl -s http://192.168.123.100:4000/health/liveliness     # -> "I'm alive!"

# (Ré)assembler toute la pile LLM (Ollama + gateway)
./scripts/omega-lab.sh --llm

# Donner l'accès LLM aux VMs éligibles (vram>0)
./scripts/omega-lab.sh --llm-access-reconcile           # --dry-run pour simuler

# Statut d'un conteneur Ollama / le redémarrer (ré-attache le GPU si NVML KO)
ssh root@<nœud> 'docker ps --filter name=ollama; docker restart dex-ollama-worker'

# Entraînement : entrer dans le LXC GPU
ssh root@192.168.123.102 'pct exec 9500 -- nvidia-smi'   # GPU vu dans le CT
# Jupyter du CT : http://<ip-CT-9500>:8888
```

---

## 8. Résumé en une phrase par forme

1. **Jobs** (`:9400`) — la VM envoie un calcul GPU ponctuel ; tourne sur emilia/ram/**rem**.
2. **LLM** (`:4000`/`:11434`) — inférence de modèles de langage, load-balancée par la
   gateway ; tourne sur **ram + emilia** (rem exclu tant que son disque n'est pas remplacé).
3. **Entraînement** (CT 9500, Jupyter `:8888`) — vrai CUDA dans un LXC sur nœud GPU ;
   disponible sur ram et **rem**.
```
