# GPU Omega — guide d'usage + récap session du 30 juin 2026

## 1. Les 3 voies d'accès au GPU (RTX 3090 Ti, 24 Go, sur le nœud `rem`)

Le GPU n'est **jamais** en passthrough : il reste sur l'hôte et les 3 voies partagent
simultanément la même carte. Le quota VRAM par VM (`omega_gpu_vram_mib`) évite la famine.

| Voie | Service | Pour quoi | Accès |
|---|---|---|---|
| **Proxy par jobs** | `rem:9400` (`omega-gpu-proxy`) | calculs ponctuels (matmul, inference, encode nvenc, render Blender, custom) | API REST + token ; la VM n'a besoin d'aucun driver |
| **Entraînement** | CT 9500 `omega-train-rem`, `192.168.123.60:8888` (Jupyter) + SSH | entraînement interactif (notebooks, train.py) | navigateur / SSH ; quota VRAM via MPS |
| **Ollama / LLM** | `rem:11434` | inférence de modèles de langage | API Ollama HTTP |

### Voie 1 — Proxy GPU par jobs (`rem:9400`)
Token : `/etc/omega/gpu-proxy.token` sur rem. Endpoints :
- `POST /v1/vm/<vmid>/budget` `{"vram_budget_mib":N}` — pose le quota VRAM
- `POST /v1/jobs` `{"vm_id":N,"kind":"matrix_multiply","vram_mib":M,"payload":{"n":512,"seed":1,"require_cuda":true}}`
- `GET /v1/jobs/<job_id>` — suit l'état (`queued→running→succeeded`)
- `GET /gpu/status` — état backend/VRAM

Limites : `matrix_multiply` n ≤ 512. Client CLI fourni : `scripts/omega-gpu-client.sh`.

**Architecture (réglée le 30/06)** : le proxy tourne sur l'HÔTE rem mais PyTorch est dans le
CT 9500. Wrapper hôte `/usr/local/bin/omega-gpu-worker-ct` = `pct exec 9500 -- /opt/gpu-venv/bin/python /opt/omega-gpu-worker/omega-gpu-worker-app.py`.
Config : `OMEGA_GPU_PROXY_BACKEND_COMMAND=/usr/local/bin/omega-gpu-worker-ct` dans `/etc/omega/cluster.env`.

### Voie 2 — Entraînement (CT 9500, Jupyter + SSH)
- Jupyter : `http://192.168.123.60:8888/?token=omega-train`
- SSH : `ssh <compte>@192.168.123.60`
- venv ML : `/opt/ml` (Jupyter) ; venv proxy : `/opt/gpu-venv`. Quota VRAM via NVIDIA MPS
  (`CUDA_MPS_PINNED_DEVICE_MEM_LIMIT` = `omega_gpu_vram_mib` de la VM).
- Accès depuis une VM isolée : `scripts/train-access.sh --vmid N --enable` (règle pfSense étroite).

### Voie 3 — Ollama / LLM (`rem:11434`)
Modèles chargés : `phi4`, `deepseek-coder-v2:16b`, `llama3.1:8b`, `mistral:v0.3`,
`mistral-nemo:12b`, `qwen2.5-coder:14b`, `qwen2.5-coder:7b`. API Ollama standard
(`POST /api/generate`, `/api/chat`, `GET /api/tags`).

### Token du proxy (`TOK`)
Le proxy `:9400` exige `Authorization: Bearer <token>` (sinon HTTP 401). Le token est dans
**`/etc/omega/gpu-proxy.token`** sur rem (chmod 600). Le récupérer :
`ssh rem 'tr -d " \n\r\t" < /etc/omega/gpu-proxy.token'`. C'est un secret partagé — le
régénérer = écrire une nouvelle valeur dans ce fichier + `systemctl restart omega-gpu-proxy`.
Le client `omega-gpu-client.sh` le lit via `OMEGA_GPU_PROXY_API_TOKEN` ou
`OMEGA_GPU_PROXY_API_TOKEN_FILE`.

### Accès depuis une VM + concurrence (IMPORTANT)
Les VMs Omega sont isolées (VLAN 30). Pour qu'une VM joigne un service GPU, on pose une règle
pfSense PASS étroite via `train-access.sh` (CT/proxy/ollama, tous ports tcp vers UN hôte) ou
`llm-access.sh` (gateway LLM :4000/:11434).

**Modèle de concurrence — plusieurs VMs en parallèle = OUI :**
- La règle `train-access` est **par VM** : tag `omega-train-<ip-vm>`. Donc VM A→CT et VM B→CT
  sont deux règles distinctes qui **coexistent** → N VMs peuvent accéder au même hôte GPU
  simultanément.
- **Seule limite** : une MÊME VM ne peut pointer que vers **un seul hôte à la fois** (CT *ou*
  rem). Pour qu'une VM atteigne plusieurs hôtes GPU, utiliser un **alias pfSense** (hôtes
  multiples) plutôt que `train-access` mono-hôte.
- **Partage du 3090** (pas de passthrough) : Jupyter/SSH multi-sessions ; GPU partagé via
  **NVIDIA MPS**, chaque VM plafonnée à son `omega_gpu_vram_mib` → plusieurs entraînements
  concurrents sur les 24 Go sans famine.
- **Voie 1 (proxy jobs)** : N VMs peuvent soumettre, mais le proxy exécute **1 job à la fois**
  (`OMEGA_GPU_PROXY_MAX_CONCURRENT=1`, les autres en file) — ajustable dans `/etc/omega/cluster.env`.

Récap par voie : Voie 2 (entraînement) = N VMs ∥ ✅ · Voie 3 (Ollama) = N VMs ∥ ✅ ·
Voie 1 (proxy) = soumission ∥ mais exécution sérialisée (file).

### Fix clé du proxy CUDA (30/06)
`nvidia-smi` marchait dans le CT mais `torch.cuda` non : **`libcuda.so` (API driver) manquait**.
Les vrais fichiers driver de l'hôte sont dans `/usr/lib/x86_64-linux-gnu/nvidia/current/`
(les symlinks passent par `/etc/alternatives`, cassés dans le CT). Fix : copier ce dossier
de l'hôte vers le CT + `echo /usr/lib/x86_64-linux-gnu/nvidia/current > /etc/ld.so.conf.d/nvidia-omega.conf && ldconfig`.
→ `torch.cuda.is_available()=True`, `get_device_name(0)=NVIDIA GeForce RTX 3090 Ti`.
La version userspace doit matcher l'hôte (550.163.01) ; recopier si l'hôte met à jour le driver.

---

## 2. Récap des correctifs/fonctionnalités de la session (30 juin 2026)

### Création / cycle de vie des VMs
- **Ceph rétabli** : un deep-scrub sur le disque **SMR osd.1** (ram) faisait hang les clones RBD
  → scrubs coupés + OSD SMR drainé (`ceph osd out 1`) + OSD sain osd.5 réintégré. `rbd create`
  repassé de « hang » à 2 s. (Vrai fix durable = remplacer le disque SMR.)
- **Taille de disque à la création** : `create-omega-vm.sh` ne redimensionnait jamais le disque
  → ajout `qm resize scsi0 <N>G` + `growpart`/`resize_rootfs` cloud-init + transmission de
  `size_rom` de l'API (étudiant) jusqu'au script.
- **SSH root** : drop-in renommé `99-`→`00-omega-root-login.conf` (prioritaire sur cloud-init) +
  `ensure_ssh_root_remote` dans le chemin `--resource-only`.
- **Retry SSH transitoire** (congestion) : `OmegaRunner._is_connect_failure` retente UNIQUEMENT
  les échecs de connexion (connect/timeout/`kex_exchange_identification`/banner) — JAMAIS une
  opération mutante (sinon doublon de provisioning). Réservé aux lectures (topologie/specs).
- **Adoption sur erreur post-création** : `provision_new_vm` n'échoue plus si le script crée la
  VM mais bute sur une étape annexe (proxy/QGA) → la VM est adoptée (anti-doublon).
- **Auto-guérison du provisioning** : thread de fond dans l'API (`provision_reconciler.py`)
  re-provisionne tout seul, toutes les 2 min, les VMs restées en `waiting` (registre en mémoire
  anti-doublon). Aucune intervention manuelle.
- **Suppression de VM** : retiré `--destroy-unreferenced-disks` du `pvesh delete` (déclenchait un
  `rbd ls` du pool qui échoue sur ce Ceph → tâche qmdestroy plantée → VM « non supprimée » + 500).

### Réseau / distribution
- **Réconciliateur de distribution** réparé : (a) `grep '^INFO'` sans match sous `set -e` avortait
  le script avant migration → `|| true` ; (b) `qm migrate` lancé sur le contrôleur → « target is
  local node » → passé par `pvesh /nodes/$src/qemu/$vmid/migrate` (exécution sur le nœud source).
  Migre désormais (échoue encore tant que le réseau de gestion est congestionné — broken pipe).

### Interface GANDAL
- **RBAC enseignant** : un prof non-super-admin ne voit que les VMs de ses étudiants supervisés
  (avant : toute la flotte). Demandes de VM routées au superviseur, pas au super admin.
- **Options étudiant restreintes** : un étudiant ne peut pas s'auto-attribuer Internet/GPU/Always-on
  à la création (backend les ignore + formulaire les masque) — réservé à l'enseignant/admin.
- **Affichage FR** des rôles (student/teacher/admin → Étudiant/Enseignant/Administrateur).
- **Dark mode** des formulaires (texte invisible corrigé), **taille disque** réelle dans
  l'inspecteur, **interface vide** corrigée (topologie résiliente aux drops SSH + parsing snapshots).

### GPU
- **Proxy GPU par jobs opérationnel sur le 3090** (voir §1) : torch cu124 dans le CT + fix libcuda
  + worker dispatché par `pct exec`. Prouvé : matmul `device=cuda`, RTX 3090 Ti, 176 ms.
