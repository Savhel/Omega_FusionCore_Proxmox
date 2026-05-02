# Omega Remote Paging — Guide Complet

> Cluster Proxmox homogène — toutes les machines font tourner Proxmox et des VMs.
> Axes : RAM · CPU · GPU · Disque

---

## Table des matières

1. [Ce que fait Omega](#1-ce-que-fait-omega)
2. [Architecture réelle](#2-architecture-réelle)
3. [Ce qui tourne sur chaque machine](#3-ce-qui-tourne-sur-chaque-machine)
4. [Prérequis](#4-prérequis)
5. [Étape 1 — Compilation](#5-étape-1--compilation)
6. [Étape 2 — Installation sur chaque nœud](#6-étape-2--installation-sur-chaque-nœud)
7. [Étape 3 — Démarrer les services](#7-étape-3--démarrer-les-services)
8. [Étape 4 — Enregistrer les VMs](#8-étape-4--enregistrer-les-vms)
9. [Étape 5 — Démarrer le controller](#9-étape-5--démarrer-le-controller)
10. [Tester que tout fonctionne](#10-tester-que-tout-fonctionne)
11. [Visualiser l'activité en temps réel](#11-visualiser-lactivité-en-temps-réel)
12. [Cluster 2 nœuds, 4 nœuds ou plus](#12-cluster-2-nœuds-4-nœuds-ou-plus)
13. [Commandes utiles au quotidien](#13-commandes-utiles-au-quotidien)
14. [Dépannage](#14-dépannage)
15. [Référence des ports et fichiers](#15-référence-des-ports-et-fichiers)

---

## 1. Ce que fait Omega

Quand ta RAM est pleine sur un nœud Proxmox, au lieu de swapper sur disque local (lent), Omega déplace les pages mémoire froides vers la RAM des autres nœuds du cluster via le réseau. Pour la VM, rien ne change — elle continue à tourner normalement.

En plus de la RAM, Omega gère aussi :
- **CPU** : ajoute ou retire des vCPUs à chaud selon la charge
- **GPU** : partage un GPU physique entre plusieurs VMs
- **Disque** : donne plus d'I/O aux VMs qui en ont besoin, ralentit celles qui monopolisent le disque
- **Migrations** : déplace automatiquement les VMs vers le nœud le plus adapté

---

## 2. Architecture réelle

Dans un cluster Proxmox homogène, **toutes les machines sont équivalentes**. Chacune peut à la fois héberger des VMs ET stocker les pages évincées par les autres.

```
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│   Machine 1         │   │   Machine 2         │   │   Machine 3         │
│   192.168.1.1       │   │   192.168.1.2       │   │   192.168.1.3       │
│                     │   │                     │   │                     │
│  VMs (QEMU)         │   │  VMs (QEMU)         │   │  VMs (QEMU)         │
│  node-a-agent×N     │   │  node-a-agent×N     │   │  node-a-agent×N     │
│  omega-daemon ◄─────┼───►  omega-daemon ◄─────┼───►  omega-daemon       │
│  (store :9100)      │   │  (store :9100)      │   │  (store :9100)      │
│  (API    :9200)     │   │  (API    :9200)     │   │  (API    :9200)     │
│  (ctrl   :9300)     │   │  (ctrl   :9300)     │   │  (ctrl   :9300)     │
│                     │   │                     │   │                     │
│  omega-controller ──┼───►────────────────────►│   │                     │
│  (Python, 1 seul)   │   │                     │   │                     │
└─────────────────────┘   └─────────────────────┘   └─────────────────────┘
```

Quand une VM sur la machine 1 a besoin d'évincer de la RAM → ses pages partent vers les machines 2 et 3.
Quand une VM sur la machine 2 a besoin d'évincer → ses pages partent vers les machines 1 et 3.
Et ainsi de suite.

---

## 3. Ce qui tourne sur chaque machine

### Sur les 3 machines (identique)

| Composant | Comment | Description |
|---|---|---|
| `omega-daemon` | service systemd | Reçoit les pages des autres, surveille les VMs locales, gère CPU/GPU/disque |
| `kvm-omega` | remplace `/usr/bin/kvm` | Intercepte le démarrage QEMU, injecte le backend mémoire omega |
| `node-a-agent` | lancé automatiquement | Un agent par VM, gère les pages en RAM de cette VM |
| hookscript Proxmox | enregistré sur chaque VM | Démarre/arrête l'agent au démarrage/arrêt de chaque VM |

### Sur une seule machine (au choix)

| Composant | Comment | Description |
|---|---|---|
| `omega-controller` | service systemd (Python) | Surveille tout le cluster, décide des migrations automatiques |

---

## 4. Prérequis

### Sur chaque nœud Proxmox

```bash
# Vérifier la version du kernel (>= 5.7 requis)
uname -r

# Vérifier que cgroups v2 est actif
cat /proc/mounts | grep cgroup2
# Si rien ne s'affiche, activer cgroups v2 :
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.unified_cgroup_hierarchy=1"' \
    >> /etc/default/grub
update-grub
reboot

# Vérifier userfaultfd (gestion des page faults mémoire)
ls /dev/userfaultfd
# Si absent :
echo 1 > /proc/sys/vm/unprivileged_userfaultfd
# Pour le rendre permanent :
echo 'vm.unprivileged_userfaultfd = 1' >> /etc/sysctl.conf
```

> **Cluster virtuel KVM (lab nested)** : ces prérequis s'appliquent également à l'intérieur
> des VMs Proxmox qui tournent sous KVM. `userfaultfd` est souvent absent par défaut dans
> les kernels nested — vérifier et activer sur chaque nœud. Les performances seront dégradées
> (double overhead de virtualisation) mais suffisantes pour tester. Voir `docs/cluster-kvm.md`
> pour la mise en place du lab.

### Sur la machine de compilation (peut être l'un des nœuds)

```bash
# Installer Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
rustup default stable

# Dépendances système
apt install -y build-essential pkg-config libssl-dev libdrm-dev \
               python3 python3-pip git curl perl
```

---

## 5. Étape 1 — Compilation

```bash
git clone <url-du-repo> omega-remote-paging
cd omega-remote-paging

# Compiler tous les binaires (prend 2-5 minutes)
make build
# ou :
cargo build --release --workspace
```

Binaires produits dans `target/release/` :

| Fichier | Rôle |
|---|---|
| `omega-daemon` | daemon principal (un par nœud) |
| `node-a-agent` | agent mémoire par VM |
| `omega-qemu-launcher` | wrapper QEMU |
| `node-bc-store` | store standalone (uniquement pour machines dédiées — pas ton cas) |

Lancer les tests pour vérifier que tout compile correctement :

```bash
make test-rust
# Résultat attendu : 152 tests, 0 échecs
```

---

## 6. Étape 2 — Installation sur chaque nœud

À faire sur chaque machine (adapter les IPs).

### Machine 1 (192.168.1.1)

```bash
cd omega-remote-paging

# Installer le daemon, le wrapper QEMU et le hookscript
OMEGA_STORES="192.168.1.2:9100,192.168.1.3:9100" \
INSTALL_DIR="/usr/local/bin" \
OMEGA_RUN_DIR="/var/lib/omega-qemu" \
    bash scripts/omega-proxmox-install.sh
```

### Machine 2 (192.168.1.2)

```bash
OMEGA_STORES="192.168.1.1:9100,192.168.1.3:9100" \
INSTALL_DIR="/usr/local/bin" \
OMEGA_RUN_DIR="/var/lib/omega-qemu" \
    bash scripts/omega-proxmox-install.sh
```

### Machine 3 (192.168.1.3)

```bash
OMEGA_STORES="192.168.1.1:9100,192.168.1.2:9100" \
INSTALL_DIR="/usr/local/bin" \
OMEGA_RUN_DIR="/var/lib/omega-qemu" \
    bash scripts/omega-proxmox-install.sh
```

Ce script fait automatiquement :
1. Copie les binaires dans `/usr/local/bin/`
2. Sauvegarde `/usr/bin/kvm` → `/usr/bin/kvm.real`
3. Génère `/usr/local/bin/kvm-omega` (le wrapper)
4. Crée le symlink `/usr/bin/kvm` → `kvm-omega`
5. Copie le hookscript dans `/var/lib/vz/snippets/omega-hook.pl`
6. Crée le service systemd `omega-daemon`

Vérifier que le wrapper est en place :

```bash
ls -la /usr/bin/kvm
# → /usr/bin/kvm -> /usr/local/bin/kvm-omega   ✓
```

### Configurer omega-daemon sur chaque nœud

Créer `/etc/default/omega-daemon` (adapter les IPs sur chaque machine) :

```bash
# Sur la machine 1 :
cat > /etc/default/omega-daemon <<'EOF'
OMEGA_NODE_ID=pve-node1
OMEGA_NODE_ADDR=192.168.1.1
OMEGA_PEERS=192.168.1.2:9200,192.168.1.3:9200
OMEGA_EVICT_THRESHOLD_PCT=75
OMEGA_GPU_ENABLED=true
RUST_LOG=info
EOF

# Sur la machine 2 :
cat > /etc/default/omega-daemon <<'EOF'
OMEGA_NODE_ID=pve-node2
OMEGA_NODE_ADDR=192.168.1.2
OMEGA_PEERS=192.168.1.1:9200,192.168.1.3:9200
OMEGA_EVICT_THRESHOLD_PCT=75
OMEGA_GPU_ENABLED=true
RUST_LOG=info
EOF

# Sur la machine 3 :
cat > /etc/default/omega-daemon <<'EOF'
OMEGA_NODE_ID=pve-node3
OMEGA_NODE_ADDR=192.168.1.3
OMEGA_PEERS=192.168.1.1:9200,192.168.1.2:9200
OMEGA_EVICT_THRESHOLD_PCT=75
OMEGA_GPU_ENABLED=true
RUST_LOG=info
EOF
```

Mettre à jour le service systemd pour charger ce fichier :

```bash
# Sur chaque nœud :
sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/omega-daemon|' \
    /etc/systemd/system/omega-daemon.service

# Ajouter EnvironmentFile juste avant ExecStart :
sed -i '/\[Service\]/a EnvironmentFile=/etc/default/omega-daemon' \
    /etc/systemd/system/omega-daemon.service

systemctl daemon-reload
```

---

## 7. Étape 3 — Démarrer les services

### Sur chaque nœud (dans cet ordre)

```bash
# 1. Démarrer omega-daemon
systemctl start omega-daemon
systemctl enable omega-daemon   # démarrage automatique au boot

# 2. Vérifier qu'il tourne
systemctl status omega-daemon
# Chercher : "Active: active (running)"

# 3. Vérifier les logs de démarrage
journalctl -u omega-daemon -n 30
# Chercher des lignes comme :
# omega-daemon V4 démarré node_id=pve-node1 store_port=9100 api_port=9200
# store TCP démarré sur 0.0.0.0:9100
# API HTTP démarrée sur 0.0.0.0:9200
# canal de contrôle HTTP démarré sur 0.0.0.0:9300
```

### Vérifier la connectivité entre nœuds

```bash
# Depuis la machine 1, vérifier que les machines 2 et 3 répondent
curl -s http://192.168.1.2:9200/api/node | python3 -m json.tool
curl -s http://192.168.1.3:9200/api/node | python3 -m json.tool
# Doit afficher le JSON d'état du nœud distant

# Vérifier les stores TCP
nc -zv 192.168.1.2 9100 && echo "store machine2 OK"
nc -zv 192.168.1.3 9100 && echo "store machine3 OK"
```

---

## 8. Étape 4 — Enregistrer les VMs

Le hookscript doit être enregistré sur chaque VM pour que le cycle de vie soit géré.

```bash
# Enregistrer une VM spécifique
qm set 100 --hookscript local:snippets/omega-hook.pl
qm set 101 --hookscript local:snippets/omega-hook.pl

# Enregistrer TOUTES les VMs du nœud d'un coup
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    qm set "$vmid" --hookscript local:snippets/omega-hook.pl
    echo "VM $vmid ✓"
done

# Vérifier
qm config 100 | grep hookscript
# → hookscript: local:snippets/omega-hook.pl
```

---

## 9. Étape 5 — Démarrer le controller

Le controller est le cerveau du cluster. Il tourne sur **une seule machine** (peu importe laquelle).

### Installer les dépendances Python

```bash
cd omega-remote-paging
pip install -r controller/requirements.txt
```

### Tester en mode dry-run d'abord

```bash
python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --poll-interval 5 \
    --dry-run
```

Tu dois voir des logs comme :
```
[10:00:01] [info]  cycle daemon nodes=['node-a', 'node-b', 'node-c']
[10:00:01] [info]  aucune migration nécessaire
```

Si `dry-run` fonctionne, lancer pour de vrai :

```bash
python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --poll-interval 5 \
    --proxmox-url https://192.168.1.1:8006 \
    --proxmox-token "root@pam!omega=<ton-token-api>"
```

### En service systemd (pour le garder actif)

```bash
cat > /etc/systemd/system/omega-controller.service <<EOF
[Unit]
Description=Omega Controller (migration automatique)
After=network.target omega-daemon.service

[Service]
Type=simple
WorkingDirectory=/opt/omega-remote-paging
ExecStart=python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --poll-interval 5 \
    --proxmox-url https://192.168.1.1:8006 \
    --log-format json
Restart=always
RestartSec=10
Environment=PYTHONPATH=/opt/omega-remote-paging

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now omega-controller
```

---

## 10. Tester que tout fonctionne

### Test 1 — Démarrer une VM et vérifier l'agent

```bash
qm start 100

# Sur le nœud qui héberge la VM 100, vérifier que l'agent est actif
omega-qemu-launcher status --vm-id 100
# Résultat attendu :
# {
#   "vm_id": 100,
#   "agent_running": true,
#   "agent_pid": 12345,
#   ...
# }

# Vérifier les logs de démarrage du hookscript
grep "vmid=100" /var/log/omega-hook.log
# Chercher : "agent memfd prêt pour vmid=100"
```

### Test 2 — Vérifier que les stores se joignent

```bash
# Depuis le nœud 1, voir l'état du cluster entier
curl -s http://127.0.0.1:9200/api/cluster | python3 -m json.tool
# Doit afficher les 3 nœuds avec leurs métriques
```

### Test 3 — Simuler une pression mémoire et observer l'éviction

```bash
# Dans la VM 100, créer de la pression mémoire
# (dans la VM elle-même) :
stress-ng --vm 1 --vm-bytes 80% --timeout 60s &

# Sur le nœud hôte, observer les pages évincées
watch -n 1 'curl -s http://127.0.0.1:9300/control/pages/100'
# Le compteur "remote_pages" doit augmenter
```

### Test 4 — Vérifier le monitoring CPU

```bash
# Voir le statut des vCPUs de toutes les VMs
curl -s http://127.0.0.1:9300/control/vcpu/status | python3 -m json.tool
```

### Test 5 — Vérifier le GPU

```bash
# Voir l'état GPU du nœud
curl -s http://127.0.0.1:9200/api/gpu | python3 -m json.tool
# Doit afficher : backend, total_vram_mib, free_vram_mib, vms_using_gpu
```

### Test 6 — Tous les tests unitaires

```bash
# Tests Rust (152 tests)
make test-rust

# Tests Python (controller)
make test-python
```

---

## 11. Visualiser l'activité en temps réel

### Vue d'ensemble du cluster

```bash
# Statut de tous les nœuds en une commande
python3 -m controller.main status \
    --stores 192.168.1.1:9100,192.168.1.2:9100,192.168.1.3:9100
```

### Monitoring continu (terminal dédié)

```bash
# Boucle de monitoring toutes les 10 secondes
python3 -m controller.main monitor \
    --stores 192.168.1.1:9100,192.168.1.2:9100,192.168.1.3:9100 \
    --interval 10

# Sortie typique :
# [10:00:01] [info]  cycle monitoring mem_usage_pct=62.3 swap_usage_pct=0.0
#                    psi_some_avg10=0.12 decision=local_only
# [10:00:11] [info]  cycle monitoring mem_usage_pct=78.1 ...
#                    decision=enable_remote   ← éviction activée
```

### Voir les pages évincées par VM

```bash
# Toutes les 2 secondes, voir les pages distantes de la VM 100
watch -n 2 'curl -s http://127.0.0.1:9300/control/pages/100 | python3 -m json.tool'
```

### Logs en temps réel

```bash
# Daemon (RAM, CPU, GPU, disque) — terminal 1
journalctl -u omega-daemon -f

# Controller (décisions de migration) — terminal 2
journalctl -u omega-controller -f

# Hookscript (cycle de vie des VMs) — terminal 3
tail -f /var/log/omega-hook.log

# Agent d'une VM spécifique — terminal 4
tail -f /var/lib/omega-qemu/vm-100/agent.log
```

### API complète disponible

```bash
BASE_DAEMON="http://127.0.0.1:9200"
BASE_CTRL="http://127.0.0.1:9300"

# État détaillé du nœud local
curl -s $BASE_DAEMON/api/node | python3 -m json.tool

# État de tout le cluster (tous les nœuds peers)
curl -s $BASE_DAEMON/api/cluster | python3 -m json.tool

# État GPU
curl -s $BASE_DAEMON/api/gpu | python3 -m json.tool

# Statut général (santé du daemon)
curl -s $BASE_CTRL/control/status | python3 -m json.tool

# Pages distantes d'une VM
curl -s $BASE_CTRL/control/pages/100 | python3 -m json.tool

# Statut vCPUs de toutes les VMs
curl -s $BASE_CTRL/control/vcpu/status | python3 -m json.tool
```

---

## 12. Cluster 2 nœuds, 4 nœuds ou plus

Le controller supporte N nœuds via `--node` répétable. Le daemon Rust supporte aussi N peers dans `OMEGA_PEERS`.

### 2 nœuds — sans réplication

```bash
# Machine 1 : évince vers machine 2 (un seul store, pas de réplica)
OMEGA_STORES="192.168.1.2:9100" bash scripts/omega-proxmox-install.sh

# Machine 2 : évince vers machine 1
OMEGA_STORES="192.168.1.1:9100" bash scripts/omega-proxmox-install.sh

# omega-daemon — OMEGA_PEERS dans /etc/default/omega-daemon
OMEGA_PEERS=192.168.1.2:9200   # sur machine 1
OMEGA_PEERS=192.168.1.1:9200   # sur machine 2

# Controller
python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300
```

### 4 nœuds

```bash
# Installation sur chaque machine (adapter OMEGA_STORES = les autres nœuds)
OMEGA_STORES="192.168.1.2:9100,192.168.1.3:9100,192.168.1.4:9100" \
    bash scripts/omega-proxmox-install.sh

# omega-daemon — lister tous les autres nœuds en peers
OMEGA_PEERS=192.168.1.2:9200,192.168.1.3:9200,192.168.1.4:9200   # sur machine 1

# Controller avec 4 nœuds — ajouter autant de --node que nécessaire
python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --node http://192.168.1.4:9300
```

### N nœuds (générique)

```bash
# Controller — répéter --node pour chaque nœud du cluster
python3 -m controller.main daemon \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    # ... autant de nœuds que nécessaire
    --poll-interval 5

# drain-node — même syntaxe, --source-node = node-a, node-b, node-c, node-d, ...
python3 -m controller.main drain-node \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --source-node node-b \
    --dry-run
```

---

## 13. Commandes utiles au quotidien

```bash
# Voir l'état d'une VM
omega-qemu-launcher status --vm-id 100

# Forcer l'arrêt de l'agent d'une VM (si QEMU est déjà mort)
omega-qemu-launcher stop --vm-id 100

# Déclencher une migration manuelle
python3 -m controller.main migrate \
    --source http://192.168.1.1:9300 \
    --vm-id 100 \
    --target pve-node2 \
    --type live

# Vider un nœud avant maintenance (migre toutes ses VMs)
python3 -m controller.main drain-node \
    --node http://192.168.1.1:9300 \
    --node http://192.168.1.2:9300 \
    --node http://192.168.1.3:9300 \
    --source-node node-a \
    --dry-run          # enlever --dry-run pour exécuter réellement

# Nettoyer les pages distantes d'une VM arrêtée
curl -X DELETE http://127.0.0.1:9300/control/pages/100

# Recompiler après modifications
make build && systemctl restart omega-daemon
```

---

## 14. Dépannage

### La VM ne démarre pas

```bash
# Vérifier que le wrapper kvm est bien en place
ls -la /usr/bin/kvm
# Doit afficher : /usr/bin/kvm -> /usr/local/bin/kvm-omega

# Voir les logs du hookscript au démarrage
grep "vmid=100" /var/log/omega-hook.log | tail -20

# Voir les logs de l'agent de la VM
cat /var/lib/omega-qemu/vm-100/agent.log

# Tester manuellement le prepare (sans démarrer QEMU)
omega-qemu-launcher prepare \
    --vm-id 100 \
    --size-mib 2048 \
    --stores "192.168.1.2:9100,192.168.1.3:9100"
```

### omega-daemon ne démarre pas

```bash
journalctl -u omega-daemon -n 50 --no-pager
# Causes fréquentes :
# - port 9100 déjà utilisé → vérifier : ss -tlnp | grep 9100
# - /dev/dri/renderD128 absent → désactiver GPU : OMEGA_GPU_ENABLED=false
# - peers injoignables → normal au premier démarrage, ils se connectent ensuite
```

### Les stores ne se joignent pas

```bash
# Vérifier que le port 9100 est ouvert sur les autres nœuds
nc -zv 192.168.1.2 9100

# Vérifier le firewall Proxmox
iptables -L -n | grep 9100
# Si bloqué, ouvrir :
iptables -A INPUT -p tcp --dport 9100 -j ACCEPT
iptables -A INPUT -p tcp --dport 9200 -j ACCEPT
iptables -A INPUT -p tcp --dport 9300 -j ACCEPT
```

### Le controller ne voit pas tous les nœuds

```bash
# Tester manuellement chaque nœud
curl -s http://192.168.1.1:9300/control/status
curl -s http://192.168.1.2:9300/control/status
curl -s http://192.168.1.3:9300/control/status
# Chacun doit répondre un JSON avec "status": "ok"
```

### Restaurer le kvm original (rollback complet)

```bash
# Supprimer le wrapper et restaurer le kvm original
rm /usr/bin/kvm
mv /usr/bin/kvm.real /usr/bin/kvm

# Désactiver les services
systemctl stop omega-daemon omega-controller
systemctl disable omega-daemon omega-controller

# Désactiver le hookscript sur toutes les VMs
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    qm set "$vmid" --delete hookscript 2>/dev/null || true
done
```

---

## 15. Référence des ports et fichiers

### Ports réseau (ouvrir dans le firewall entre nœuds)

| Port | Protocole | Usage |
|---|---|---|
| **9100** | TCP | Store de pages (reçoit les pages évincées par les autres nœuds) |
| **9200** | HTTP | API cluster (état du nœud, métriques) |
| **9300** | HTTP | Canal de contrôle (migrations, quotas, statut) |

### Fichiers importants sur chaque nœud

| Chemin | Description |
|---|---|
| `/usr/bin/kvm` | → symlink vers `kvm-omega` |
| `/usr/bin/kvm.real` | kvm Proxmox original (sauvegardé) |
| `/usr/local/bin/kvm-omega` | wrapper shell généré par le launcher |
| `/usr/local/bin/omega-daemon` | daemon principal |
| `/usr/local/bin/omega-qemu-launcher` | gestionnaire agent par VM |
| `/usr/local/bin/node-a-agent` | agent mémoire (lancé par le launcher) |
| `/var/lib/vz/snippets/omega-hook.pl` | hookscript Proxmox |
| `/etc/default/omega-daemon` | configuration du daemon |
| `/var/lib/omega-qemu/vm-{id}/memory.json` | métadonnées memfd de la VM |
| `/var/lib/omega-qemu/vm-{id}/agent.log` | logs de l'agent de la VM |
| `/var/log/omega-hook.log` | logs du hookscript (démarrage/arrêt VMs) |

### Résumé services par machine

```
Chaque nœud Proxmox :
  systemctl status omega-daemon        ← toujours actif

Un seul nœud (au choix) :
  systemctl status omega-controller    ← toujours actif
```

---

*omega-remote-paging — mis à jour le 2026-05-02*
