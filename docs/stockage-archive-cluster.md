# Stockage Archive Du Cluster

Ce document décrit la séparation retenue entre les nœuds de calcul Omega et les nœuds utilisés uniquement comme stockage/quorum, puis explique comment utiliser automatiquement le stockage partagé `omega-archive` depuis Proxmox, les scripts et les VMs.

---

## 1. Décision D'Architecture

Le cluster contient deux catégories de nœuds.

| Rôle | Nœuds | Usage |
|---|---|---|
| Compute Omega | `192.168.123.100`, `192.168.123.101`, `192.168.123.102` | VMs, tests Omega, migrations, GPU/proxy |
| Storage-only | `192.168.123.103`, `192.168.123.104`, `192.168.123.105`, `192.168.123.106` | Ceph, CephFS, archives, sauvegardes, versioning, quorum |

Les nœuds storage-only ne doivent pas recevoir de VMs Omega car ils n'exposent pas `/dev/kvm`.

Dans `scripts/cluster.conf`, la séparation est explicite :

```bash
OMEGA_NODES="192.168.123.100,192.168.123.101,192.168.123.102"
OMEGA_STORAGE_ONLY_NODES="192.168.123.103,192.168.123.104,192.168.123.105,192.168.123.106"
OMEGA_ARCHIVE_STORAGE="omega-archive"
```

Règle simple :
- `OMEGA_NODES` = machines capables de lancer des VMs ;
- `OMEGA_STORAGE_ONLY_NODES` = machines présentes dans Proxmox/Ceph, mais interdites pour le compute.

---

## 2. Stockage Créé

Un stockage Proxmox partagé a été créé :

```text
Nom Proxmox : omega-archive
Type        : dir
Backend     : CephFS
Chemin      : /mnt/pve/cephfs/omega-storage
Contenu     : backup, iso, vztmpl, snippets
Partagé     : oui
```

Arborescence :

```text
/mnt/pve/cephfs/omega-storage/
├── archives/
├── backups/
├── exports/
├── snapshots/
├── versioning/
├── dump/       # créé par Proxmox pour les backups vzdump
├── snippets/   # créé par Proxmox pour cloud-init snippets
└── template/   # créé par Proxmox pour ISO/templates
```

Vérification :

```bash
pvesm status | grep -E 'omega-archive|cephfs|stockage.ceph'
```

Résultat attendu :

```text
omega-archive   dir   active
cephfs          cephfs active
stockage.ceph   rbd   active
```

---

## 3. Utilisation Depuis Proxmox

### 3.1 Sauvegarder une VM automatiquement

Exemple avec une VM :

```bash
vzdump 2301 --storage omega-archive --mode snapshot --compress zstd
```

Pour plusieurs VMs :

```bash
vzdump 2301 2302 2303 --storage omega-archive --mode snapshot --compress zstd
```

Les fichiers arrivent dans :

```text
/mnt/pve/cephfs/omega-storage/dump/
```

### 3.2 Créer une tâche de backup Proxmox

Dans l'UI Proxmox :

```text
Datacenter -> Backup -> Add
Storage: omega-archive
Mode: Snapshot
Compression: ZSTD
Selection: VMs Omega ou pool dédié
```

En CLI, une tâche peut être créée avec `pvesh` selon la politique voulue. Exemple quotidien à 02:30 :

```bash
pvesh create /cluster/backup \
  --id omega-nightly \
  --storage omega-archive \
  --schedule '02:30' \
  --mode snapshot \
  --compress zstd \
  --enabled 1 \
  --vmid '2301,2302,2303,2304,2305,2306,2307,2308,2309,2310'
```

Vérifier :

```bash
pvesh get /cluster/backup
```

### 3.3 Stocker ISO, templates et snippets

Copier une ISO :

```bash
cp debian.iso /mnt/pve/cephfs/omega-storage/template/iso/
```

Lister depuis Proxmox :

```bash
pvesm list omega-archive
```

Utiliser un snippet cloud-init :

```bash
mkdir -p /mnt/pve/cephfs/omega-storage/snippets
nano /mnt/pve/cephfs/omega-storage/snippets/omega-bootstrap.yaml
qm set 2301 --cicustom user=omega-archive:snippets/omega-bootstrap.yaml
```

---

## 4. Utilisation Automatique Par Les VMs

Il y a deux méthodes propres. La méthode recommandée dépend du besoin.

### Méthode A — Proxmox gère tout

C'est la méthode recommandée pour les sauvegardes et exports système.

La VM ne monte pas directement CephFS. Proxmox sauvegarde la VM vers `omega-archive` avec `vzdump` ou une tâche planifiée.

Avantages :
- pas de clé Ceph dans les VMs ;
- pas de dépendance réseau Ceph dans l'invité ;
- restauration simple depuis l'UI Proxmox ;
- bon choix pour backups, ISO, exports, snapshots applicatifs.

Utiliser pour :

```text
backups Proxmox
exports qcow2
archives de releases
snippets cloud-init
ISO/templates
```

### Méthode B — La VM monte un espace archive dédié

À utiliser seulement si une application dans la VM doit écrire directement dans l'archive partagée.

Principe :
- créer une identité CephX limitée ;
- monter uniquement `/omega-storage/archives` ou un sous-dossier dédié ;
- ne jamais mettre la clé `client.admin` dans une VM.

Exemple côté cluster, à adapter selon la politique de sécurité :

```bash
ceph auth get-or-create client.omega-archive \
  mon 'allow r' \
  mds 'allow rw path=/omega-storage/archives' \
  osd 'allow rw tag cephfs data=cephfs' \
  -o /etc/ceph/ceph.client.omega-archive.keyring
```

Créer un dossier par projet :

```bash
mkdir -p /mnt/pve/cephfs/omega-storage/archives/projets
chmod 750 /mnt/pve/cephfs/omega-storage/archives/projets
```

Dans la VM, installer le client Ceph :

```bash
apt update
apt install -y ceph-common
```

Copier dans la VM :

```text
/etc/ceph/ceph.conf
/etc/ceph/ceph.client.omega-archive.keyring
```

Montage manuel dans la VM :

```bash
mkdir -p /mnt/omega-archive
mount -t ceph :/omega-storage/archives /mnt/omega-archive \
  -o name=omega-archive,fs=cephfs
```

Montage automatique via `/etc/fstab` :

```fstab
:/omega-storage/archives /mnt/omega-archive ceph name=omega-archive,fs=cephfs,_netdev,noatime 0 0
```

Tester :

```bash
mount -a
df -h /mnt/omega-archive
touch /mnt/omega-archive/test-vm-write
```

---

## 5. Automatisation Dans Les Scripts Omega

Les scripts doivent utiliser la variable :

```bash
OMEGA_ARCHIVE_STORAGE="omega-archive"
```

Pour écrire sur le stockage depuis un nœud Proxmox :

```bash
archive_root="/mnt/pve/cephfs/omega-storage"
mkdir -p "$archive_root/exports/$(date +%F)"
```

Pour lancer un backup depuis le contrôleur :

```bash
ssh root@192.168.123.100 \
  'vzdump 2301 --storage omega-archive --mode snapshot --compress zstd'
```

Pour exporter un disque ou un artefact :

```bash
ssh root@192.168.123.100 \
  'mkdir -p /mnt/pve/cephfs/omega-storage/exports/omega && cp /chemin/fichier /mnt/pve/cephfs/omega-storage/exports/omega/'
```

Pour un job applicatif dans une VM, préférer :
- upload vers une API interne ;
- `scp` vers un nœud Proxmox ;
- ou montage CephFS avec un compte CephX limité.

Ne pas écrire directement dans `stockage.ceph` depuis les VMs. `stockage.ceph` est le pool RBD des disques VM, pas une zone d'archives utilisateur.

---

## 6. Bonnes Pratiques

À faire :
- utiliser `omega-archive` pour backups, ISO, snippets, exports, archives ;
- garder les VMs uniquement sur les nœuds avec `/dev/kvm` ;
- utiliser des comptes CephX limités pour les VMs ;
- garder une copie externe des sauvegardes critiques.

À éviter :
- mettre `gandal`, `BLADE`, `GENESIS`, `Bris` dans `OMEGA_NODES` ;
- utiliser `omega-archive` comme disque principal de VM ;
- donner `client.admin` à une VM ;
- considérer Ceph comme une sauvegarde externe.

Rappel important : `omega-archive` protège contre la perte d'un disque ou d'un nœud Ceph, mais pas contre une suppression accidentelle répliquée, une erreur humaine, ou une corruption logique. Les sauvegardes critiques doivent aussi sortir du cluster.

---

## 7. Vérifications Rapides

État Ceph :

```bash
ceph -s
```

État stockage :

```bash
pvesm status | grep omega-archive
```

Espace disponible :

```bash
df -h /mnt/pve/cephfs/omega-storage
```

Liste des backups :

```bash
ls -lh /mnt/pve/cephfs/omega-storage/dump/
```

Liste des snippets :

```bash
ls -lh /mnt/pve/cephfs/omega-storage/snippets/
```

Nœuds compute Omega :

```bash
source scripts/cluster.conf
echo "$OMEGA_NODES"
```

Nœuds storage-only :

```bash
source scripts/cluster.conf
echo "$OMEGA_STORAGE_ONLY_NODES"
```
