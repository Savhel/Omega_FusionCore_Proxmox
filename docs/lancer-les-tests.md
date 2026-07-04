# Lancer les tests Omega — guide pour l'équipe

Ce guide permet à **n'importe quel membre de l'équipe**, depuis **sa propre machine du
réseau**, de lancer la suite de tests du cluster Omega. La config du cluster est
versionnée (`scripts/cluster.conf`) : elle est identique pour tout le monde. Le seul
prérequis par machine est **l'accès SSH aux 3 nœuds**.

---

## 1. Prérequis (une fois par machine)

Le cluster : **emilia `192.168.123.100`**, **ram `192.168.123.101`**, **rem `192.168.123.102`**.

1. Cloner/mettre à jour le dépôt :
   ```bash
   git clone <repo> && cd omega-remote-paging   # ou: git pull
   ```
2. Avoir un **accès SSH root aux 3 nœuds**, sans mot de passe. Deux options :
   - clé omega à l'emplacement standard `~/.ssh/omega_ed25519` :
     ```bash
     ssh-copy-id -i ~/.ssh/omega_ed25519.pub root@192.168.123.100
     ssh-copy-id -i ~/.ssh/omega_ed25519.pub root@192.168.123.101
     ssh-copy-id -i ~/.ssh/omega_ed25519.pub root@192.168.123.102
     ```
   - ou n'importe quelle clé chargée dans l'agent SSH (`cluster.conf` a `SSH_KEY=""`
     → repli automatique sur le SSH par défaut).
3. Vérifier :
   ```bash
   for n in 100 101 102; do ssh root@192.168.123.$n hostname; done
   # doit afficher emilia / ram / rem sans demander de mot de passe
   ```

> ⚠️ Ne **jamais** mettre un chemin de clé absolu machine-spécifique dans `cluster.conf`
> (ça casse la portabilité pour les autres). Laisser `SSH_KEY=""`.

---

## 2. Lancer les tests

Le harnais : `scripts/omega-lab.sh`.

```bash
# Voir la liste des catégories
scripts/omega-lab.sh --list-categories

# Une catégorie
scripts/omega-lab.sh --category RAM

# Plusieurs
scripts/omega-lab.sh --category "CPU GPU"

# Toutes, dans l'ordre
scripts/omega-lab.sh --category all

# Un test précis (ou plusieurs)
scripts/omega-lab.sh --test 34
scripts/omega-lab.sh --test "34 35 36"
```

### Les catégories (par ressource testée)

| Catégorie | Ce qu'elle valide |
|---|---|
| **UNIT** | tests unitaires Rust/Python (aucune VM requise) |
| **CPU** | vCPU élastique : hotplug 1→N sous charge, downscale au repos |
| **RAM** | paging distant, réplication, éviction, recall, compaction, prefetch, balloon, migration mémoire |
| **DISK** | scheduler I/O local (cgroups v2/PSI), Ceph réel |
| **GPU** | proxy jobs CUDA, placement global, fallback réseau, concurrence, rendu réel |
| **NETWORK** | TLS TOFU (canal chiffré), réseau VM invitée, partition réseau |
| **MIGRATION** | failover store, CPU+RAM→migration, live-migration sous pression, drain de nœud |
| **MIXED** | pression combinée RAM+CPU+GPU (rafales, stress cluster) |
| **OPS** | smoke, orphelins, multi-VM, install-doctor, conformité, métriques, scale |

---

## 3. Les VM de test

`cluster.conf` → `OMEGA_TEST_VMIDS="3009,5051,3030,3031"` : **VM jetables `omega-test`**,
saines (guest agent OK), IP sur le VLAN 30 :

| VMID | Nœud | IP (VLAN 30) | Charge |
|---|---|---|---|
| **3009** | ram | 10.50.30.110 | **stress-ng** + stress |
| **5051** | emilia | 10.50.30.25 | **stress-ng** + stress |
| 3030 | ram | 10.50.30.22 | stress |
| 3031 | emilia | 10.50.30.24 | stress |

- **Ne jamais utiliser une VM d'étudiant** (3000-3019 : xcsm, moodle, mutuelle, database…)
  comme VM de test — les tests les stressent / reconfigurent.
- Elles sont **pinnées** au réconciliateur (`OMEGA_RECONCILE_PIN_VMIDS`) → pas de migration en plein test.

**Si une VM ne répond plus** (guest agent mort après un stress lourd) : la rebooter
(`ssh root@<node> "qm reboot <vmid>"`, l'arrêt omega prend ~2 min) ou basculer sur une
autre VM saine (`OMEGA_TEST_VMIDS`).

### Accès SSH aux VM (VLAN 30)

Les VM sont sur le réseau privé `10.50.30.0/24`, routé par **pfSense**. Depuis une
machine du LAN `192.168.123.x` :
```bash
sudo ip route add 10.50.30.0/24 via 192.168.123.200    # une fois (les nœuds l'ont déjà)
ssh root@10.50.30.110        # 3009 — mot de passe : root
```
> Si le login SSH est **lent** (banner), c'est le reverse-DNS : dans la VM,
> `printf 'UseDNS no\n' >/etc/ssh/sshd_config.d/10-omega-fast.conf && systemctl reload ssh`.

### Générer une charge dans une VM

```bash
# en SSH dans la VM :
stress    --cpu 4 --timeout 60s                       # CPU
stress    --vm 2 --vm-bytes 1G --timeout 90s          # RAM
stress-ng --cpu 0 --vm 1 --vm-bytes 70% --timeout 90s # combiné (si stress-ng présent)
# ou via le guest agent depuis un nœud (sans SSH) :
ssh root@192.168.123.101 "qm guest exec 3009 -- stress --cpu 4 --timeout 60s"
```

### Installer stress-ng dans une nouvelle VM de test

`apt` ne marche pas (VLAN isolé). Voie fiable = **scp du bundle** (binaire + libs) depuis
un nœud vers la VM (le transfert par chunks QGA corrompt les gros binaires → SIGBUS) :
```bash
# bundle prêt sur emilia : /opt/omega-remote-paging/sng-bundle.tgz (stress-ng 0.15.06 + libs, bookworm)
sshpass -p root scp -o StrictHostKeyChecking=no /opt/omega-remote-paging/sng-bundle.tgz root@<VM_IP>:/tmp/
sshpass -p root ssh -o StrictHostKeyChecking=no root@<VM_IP> \
    'tar xzf /opt/omega-remote-paging/sng-bundle.tgz -C / && ldconfig && stress-ng --version'
```

---

## 4. Lire les résultats

Chaque test affiche `✓ PASS` / `✗ FAIL` / `– SKIP` et un résumé final. Un échec **n'est
pas forcément un bug Omega** — plusieurs limites d'environnement sont attendues :

| Test | Échec attendu si… |
|---|---|
| `25` (réseau VM) | le cluster n'a **pas d'accès Internet** → DNS/Internet/apt échouent (interface/IP/route OK) |
| `28` (partition réseau) | lancé sans `OMEGA_DESTRUCTIVE=1` (test **destructif**, opt-in) |
| `31` (scalabilité) | pas de flotte provisionnée (`--scale`, ~500 VMs) |
| `M7` (drain nœud) | le réseau/les cibles ne peuvent absorber toutes les VMs d'un coup (Broken pipe sous charge) |

---

## 5. Santé du cluster (avant/après une campagne)

```bash
# sur chaque nœud
systemctl is-active omega-daemon omega-gpu-proxy
readlink -f /usr/bin/kvm            # doit finir par kvm-omega (wrapper paging actif)
curl -fsS http://127.0.0.1:9300/control/status | python3 -m json.tool | head
```

Points d'exploitation utiles :
- **Wrapper QEMU** : `/usr/bin/kvm → kvm-omega`. Une MAJ du paquet qemu le réverte ; le
  path-unit `omega-kvm-wrapper.path` le remet auto. Ne concerne que les VMs démarrées
  **après** activation.
- **Mot de passe root des VMs** : `root:root`, garanti à chaque boot (cloud-init bootcmd).
- **Node exporter Prometheus** sur `:9103` (pas `:9101`, réservé aux stores de test).
- **GPU** : seul **rem (192.168.123.102)** a l'environnement CUDA complet (CT-torch) ;
  `cluster.conf` y pointe `OMEGA_GPU_PRIMARY_NODE`. VRAM auto-détectée à l'install.

---

## 6. Dépannage rapide

| Symptôme | Cause / action |
|---|---|
| « qemu-guest-agent absent » alors que la VM tourne | la VM a été **redémarrée** (arrêt omega lent ~2 min) — attendre le boot, ou la VM de test est épuisée → rebooter / en changer |
| test GPU « aucun nœud GPU avec budget » | proxy à `total_vram=0` → relancer un déploiement (VRAM auto-détectée) ou `OMEGA_GPU_PROXY_TOTAL_VRAM_MIB` sur le nœud GPU |
| migration « Broken pipe / exit 255 » | instabilité réseau sous charge — réessayer, éviter les drains massifs simultanés |
| test isolé (02/store) « pas de réponse » | conflit de port (un service sur 9100/9101) — vérifier `ss -ltnp | grep 910` |

---

Voir aussi : `README.md` (section « Lancer les tests »), `docs/GPU-usage-et-session-2026-06-30.md`
(3 voies GPU + token), `docs/guide-test-et-depannage-complet.md` (détails historiques).
