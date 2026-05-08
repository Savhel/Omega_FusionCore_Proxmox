# Validation datacenter physique

Ce document sert a valider Omega sur un vrai cluster Proxmox, pas seulement sur une machine de developpement. Il couvre la creation de VMs conformes, les tests d'utilisation reels et les erreurs deja rencontrees pendant les essais.

## 1. Prerequis

- Cluster Proxmox VE avec au moins 2 noeuds, idealement 3 ou plus.
- Stockage partage pour les disques VM, idealement Ceph RBD.
- Reseau inter-noeuds stable entre les ports `9100`, `9200` et `9300`.
- Acces SSH root ou utilisateur admin vers tous les noeuds.
- `qemu-guest-agent` installe et actif dans les VMs de test.
- VMs de test sur bridge Proxmox routable ou avec NAT fonctionnel.
- Pour le paging distant reel: kernel avec `userfaultfd` autorise via capability ou sysctl.
- Pour le scheduler disque: cgroup v2 avec controleur `io` active sous `qemu.slice`.
- Pour GPU: render node `/dev/dri/renderD*` visible sur l'hote et, si test invite, passthrough ou paravirtualisation exposee a la VM.

Commandes de base sur chaque noeud:

```bash
systemctl status omega-daemon
curl -s http://127.0.0.1:9300/control/status | python3 -m json.tool
curl -s http://127.0.0.1:9300/control/vcpu/status | python3 -m json.tool
curl -s http://127.0.0.1:9300/control/disk/status | python3 -m json.tool
curl -s http://127.0.0.1:9300/control/gpu/status | python3 -m json.tool
```

## 2. Creation de VMs conformes

Le point important est de separer le minimum au demarrage du maximum hotpluggable:

```bash
qm showcmd 9001 --pretty | grep -- '-smp'
# Attendu: -smp '1,sockets=1,cores=4,maxcpus=4'
```

Creation recommandee avec le script du depot:

```bash
cd /opt/omega-remote-paging

./scripts/create-omega-vm.sh \
  --vmids 9001,9002,9003 \
  --name omega-test \
  --storage ceph-vms \
  --bridge vmbr0 \
  --image /var/lib/vz/template/iso/debian-12-generic-amd64.qcow2 \
  --sshkey /root/.ssh/id_rsa.pub \
  --memory 2048 \
  --balloon 512 \
  --cores 4 \
  --vcpus 1 \
  --disk-max-gib 20 \
  --gpu-vram-mib 0 \
  --start
```

Commande equivalente sans script, pour une VM:

```bash
VMID=9001
STORAGE=ceph-vms
BRIDGE=vmbr0
IMAGE=/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2

qm create "$VMID" \
  --name "omega-test-$VMID" \
  --ostype l26 \
  --machine q35 \
  --agent enabled=1 \
  --cpu kvm64 \
  --sockets 1 \
  --cores 4 \
  --vcpus 1 \
  --memory 2048 \
  --balloon 512 \
  --hotplug cpu,memory,disk,network \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${BRIDGE},firewall=0" \
  --serial0 socket \
  --vga serial0 \
  --tags omega,omega-test \
  --description "omega_min_vcpus=1 omega_max_vcpus=4 omega_memory_min_mib=512 omega_memory_max_mib=2048 omega_disk_max_gib=20 omega_gpu_vram_mib=0"

qm importdisk "$VMID" "$IMAGE" "$STORAGE"
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,iothread=1,ssd=1" \
  --boot order=scsi0 \
  --ide2 "${STORAGE}:cloudinit" \
  --ciuser root \
  --sshkeys /root/.ssh/id_rsa.pub \
  --ipconfig0 ip=dhcp \
  --nameserver 8.8.8.8
qm start "$VMID"
```

Pour une VM GPU, garder la meme base et changer uniquement le budget declare:

```bash
qm set 9001 --description "omega_min_vcpus=1 omega_max_vcpus=4 omega_memory_min_mib=512 omega_memory_max_mib=2048 omega_disk_max_gib=20 omega_gpu_vram_mib=2048"
qm set 9001 --tags omega,omega-test,omega-gpu
```

Si vous faites du passthrough manuel pour valider le rendu invite:

```bash
qm set 9001 --hostpci0 0000:03:00,pcie=1
```

## 3. Configuration du lab physique

Creer ou modifier `scripts/cluster.conf`:

```bash
OMEGA_NODES="10.10.0.11,10.10.0.12,10.10.0.13"
OMEGA_CONTROLLER="10.10.0.11"
OMEGA_TEST_VMIDS="9001,9002,9003"
OMEGA_TEST_VMID="9001"
DEPLOY_USER="root"
SSH_KEY="/root/.ssh/omega_ed25519"
STORE_PORT=9100
STATUS_PORT=9200
```

Validation SSH:

```bash
for n in 10.10.0.11 10.10.0.12 10.10.0.13; do
  ssh -i /root/.ssh/omega_ed25519 root@$n 'hostname && systemctl is-active omega-daemon'
done
```

## 4. Tests d'utilisation reels

Validation complete non destructive:

```bash
./scripts/omega-lab.sh --gpu --ceph --auto
```

Validation longue duree:

```bash
OMEGA_SOAK_SECS=7200 ./scripts/omega-lab.sh --gpu --ceph --long --auto
```

Validation avec panne reseau controlee, uniquement en fenetre de maintenance:

```bash
./scripts/omega-lab.sh --gpu --ceph --long --destructive --auto
```

Validation scalabilite 500 VMs:

```bash
# Exemple: VMs 9001 a 9500 deja creees avec scripts/create-omega-vm.sh
export OMEGA_SCALE_VMIDS="$(seq -s, 9001 9500)"
export OMEGA_SCALE_TARGET=500
export OMEGA_SCALE_BATCH_SIZE=20
export OMEGA_SCALE_SOAK_SECS=3600

./scripts/omega-lab.sh --gpu --ceph --long --scale --auto
```

Runner direct sans menu:

```bash
OMEGA_NODES=10.10.0.11,10.10.0.12,10.10.0.13 \
OMEGA_CONTROLLER=10.10.0.11 \
OMEGA_TEST_VMIDS=9001,9002,9003 \
DEPLOY_USER=root \
./scripts/tests/run-cluster.sh 9001 --gpu --ceph --long
```

Runner direct pour 500 VMs:

```bash
OMEGA_NODES=10.10.0.11,10.10.0.12,10.10.0.13 \
OMEGA_CONTROLLER=10.10.0.11 \
OMEGA_TEST_VMIDS=9001,9002,9003 \
OMEGA_SCALE_VMIDS="$(seq -s, 9001 9500)" \
OMEGA_SCALE_TARGET=500 \
OMEGA_SCALE_BATCH_SIZE=20 \
OMEGA_SCALE_SOAK_SECS=3600 \
DEPLOY_USER=root \
./scripts/tests/run-cluster.sh 9001 --gpu --ceph --long --scale
```

Test de conformite VM seul:

```bash
./scripts/tests/30-vm-conformity.sh 9001,9002,9003
```

## 5. Catalogue des tests physiques

| Test | Objectif |
|------|----------|
| `24-install-doctor` | Valide installation, wrapper QEMU, hookscript, services et diagnostic launcher. |
| `25-vm-network` | Valide agent invite, interface, route par defaut, ping IP, DNS et `apt update`. |
| `26-ceph-real` | Valide Ceph reel, librados, pool et exposition `ceph_enabled`. |
| `27-gpu-real-render` | Valide inventaire GPU hote, API GPU Omega et rendu minimal invite si possible. |
| `28-network-partition` | Simule une partition reseau controlee et verifie la resilience. Destructif. |
| `29-long-run-soak` | Charge longue CPU/RAM avec surveillance daemon et APIs. |
| `30-vm-conformity` | Verifie que les VMs sont compatibles Omega avant de lancer les tests lourds. |
| `31-scale-vms` | Demarre et surveille un grand nombre de VMs physiques, par defaut cible 500. |
| `M1` a `M7` | Scenarios mixtes RAM, CPU, GPU, migrations, rafales de demarrage et drain de noeud. |

## 5.1 Validation 500 VMs

Le test `31-scale-vms` ne prouve la scalabilite que si les 500 VMs existent deja et sont conformes. Il ne remplace pas le sizing materiel.

Preparation:

```bash
# Creer progressivement les VMs, par exemple par tranches de 50
for start in 9001 9051 9101 9151 9201 9251 9301 9351 9401 9451; do
  end=$((start + 49))
  vmids="$(seq -s, "$start" "$end")"
  ./scripts/create-omega-vm.sh \
    --vmids "$vmids" \
    --storage ceph-vms \
    --bridge vmbr0 \
    --image /var/lib/vz/template/iso/debian-12-generic-amd64.qcow2 \
    --sshkey /root/.ssh/id_rsa.pub \
    --memory 2048 \
    --balloon 512 \
    --cores 4 \
    --vcpus 1
done
```

Validation avant demarrage massif:

```bash
./scripts/tests/30-vm-conformity.sh "$(seq -s, 9001 9500)"
```

Demarrage et surveillance par lots:

```bash
OMEGA_SCALE_VMIDS="$(seq -s, 9001 9500)" \
OMEGA_SCALE_TARGET=500 \
OMEGA_SCALE_BATCH_SIZE=20 \
OMEGA_SCALE_SOAK_SECS=3600 \
./scripts/tests/31-scale-vms.sh
```

Variables utiles:

| Variable | Defaut | Role |
|----------|--------|------|
| `OMEGA_SCALE_VMIDS` | `OMEGA_TEST_VMIDS` | Liste exacte des VMs a tester. |
| `OMEGA_SCALE_TARGET` | `500` | Nombre de VMs attendues. |
| `OMEGA_SCALE_BATCH_SIZE` | `20` | Nombre de VMs demarrees par vague. |
| `OMEGA_SCALE_SOAK_SECS` | `1800` | Duree de surveillance apres demarrage. |
| `OMEGA_SCALE_START` | `1` | Autorise le test a demarrer les VMs non running. |
| `OMEGA_SCALE_STOP_AFTER` | `0` | Arrete les VMs a la fin si mis a `1`. |
| `OMEGA_SCALE_REQUIRE_TARGET` | `1` | Echoue si moins de VMs que la cible existent. |

Le test echoue si:

- moins de VMs que `OMEGA_SCALE_TARGET` existent;
- une VM n'est pas conforme a `vcpus/maxcpus/hotplug`;
- une VM ne demarre pas;
- un `omega-daemon` tombe;
- `/control/status` ou `/control/vcpu/status` devient inaccessible;
- une partie des VMs n'est plus `running` pendant la fenetre de soak.

## 6. Criteres d'acceptation production

Le projet est acceptable pour un essai physique encadre seulement si:

- `cargo test --workspace` passe.
- `bash -n scripts/**/*.sh` ne remonte pas d'erreur de syntaxe.
- `./scripts/tests/30-vm-conformity.sh` passe sur toutes les VMs de test.
- `./scripts/omega-lab.sh --gpu --ceph --auto` passe, avec `26`/`27` skip uniquement si Ceph/GPU ne sont pas dans le perimetre.
- Le test `29` passe sur au moins 2 heures pour un essai pre-production.
- Le test `31` passe si l'objectif est de supporter 500 VMs.
- Aucun log ne boucle sur `qm migrate ... auto`, `Device 'cpu-X' not found`, `aucun slot CPU hotpluggable`, `userfaultfd Operation not permitted` ou `io.weight non disponible` si ces fonctions sont exigees.

## 7. Depannage des erreurs deja rencontrees

### CPU hotplug: type CPU invalide

Symptome:

```text
Invalid CPU type, expected cpu type: 'kvm64-x86_64-cpu'
```

Cause: le daemon ajoutait un type CPU different du modele QEMU reel.

Verification:

```bash
qm monitor 9001
info hotpluggable-cpus
```

Correction: utiliser le type publie par QMP, pas une constante codee en dur.

### Aucun slot CPU hotpluggable

Symptome:

```text
aucun slot CPU hotpluggable hors-ligne — demarrer la VM avec -smp maxcpus=4
```

Cause: la VM a ete demarree avec tous les cores en ligne ou sans `maxcpus`.

Correction:

```bash
qm stop 9001
qm set 9001 --hotplug cpu,memory,disk,network
qm set 9001 --cores 4 --sockets 1 --vcpus 1
qm start 9001
qm showcmd 9001 --pretty | grep -- '-smp'
```

### `current_vcpus` bloque a 1

Cause la plus courante: le controller lit une config Proxmox incomplete ou la VM n'a pas de metadata `omega_max_vcpus`.

Correction:

```bash
qm set 9001 --description "omega_min_vcpus=1 omega_max_vcpus=4 omega_memory_min_mib=512 omega_memory_max_mib=2048 omega_disk_max_gib=20 omega_gpu_vram_mib=0"
curl -s http://127.0.0.1:9300/control/vcpu/status | python3 -m json.tool
```

### Hot-unplug CPU: device introuvable

Symptome:

```text
Device 'cpu-3' not found
```

Cause: l'identifiant QMP du CPU retire ne correspond pas au device reel.

Correction attendue cote code: retirer via les chemins QMP reels publies par `query-hotpluggable-cpus`/`query-cpus-fast`, puis rollback scheduler si QMP refuse.

### `io.weight` absent

Symptome:

```text
io.weight non disponible dans le cgroup VM
```

Verification:

```bash
cat /sys/fs/cgroup/qemu.slice/cgroup.controllers
cat /sys/fs/cgroup/qemu.slice/cgroup.subtree_control
ls -l /sys/fs/cgroup/qemu.slice/9001.scope/io.weight
```

Correction temporaire:

```bash
echo +io > /sys/fs/cgroup/qemu.slice/cgroup.subtree_control
systemctl restart omega-daemon
```

Si systemd retire `+io`, configurer le slice via drop-in systemd et redemarrer proprement le noeud en fenetre de maintenance.

### `userfaultfd Operation not permitted`

Symptome:

```text
SYS_userfaultfd echoue : Operation not permitted
```

Correction de test:

```bash
sysctl vm.unprivileged_userfaultfd=1
```

Correction production preferee: lancer le composant qui ouvre `userfaultfd` avec les capabilities necessaires, au minimum `CAP_SYS_PTRACE`, sans ouvrir globalement le sysctl si la politique securite l'interdit.

### VM sans reseau ou `ping 8.8.8.8` impossible

Dans la VM:

```bash
ip a
ip route
```

Sur l'hote Proxmox/NAT:

```bash
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o wlo1 -j MASQUERADE
iptables -A FORWARD -s 10.10.0.0/24 -o wlo1 -j ACCEPT
iptables -A FORWARD -d 10.10.0.0/24 -m state --state ESTABLISHED,RELATED -i wlo1 -j ACCEPT
```

Adapter `wlo1` a l'interface de sortie reelle. La faute `MASQUE RADE` vient d'un espace dans `MASQUERADE`.

### `apt update` bloque sur cdrom

Dans la VM Debian:

```bash
rm -f /etc/apt/sources.list.d/cdrom.list
cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF
apt update
```

Si DNS echoue, regler d'abord le reseau VM.

### Migration vers `auto`

Symptome:

```text
qm migrate 9001 auto --online
no such cluster node 'auto'
```

Cause: cible de migration non resolue.

Correction attendue: le controller doit convertir `auto` en nom de noeud Proxmox reel avant d'appeler `qm migrate`.

## 8. Ce qui valide vraiment le projet

Une validation serieuse doit combiner:

- VMs conformes avec `30`.
- Reseau invite valide avec `25`.
- CPU elastique et rollback avec `05`.
- RAM/paging/migration avec `08`, `22`, `M1`, `M2`, `M5`.
- Disque local et cgroup I/O avec `23C`.
- GPU avec `06`, `07`, `27`.
- Ceph avec `26`.
- Resilience avec `M7` et `28`.
- Stabilite avec `29`.
- Scalabilite grand nombre avec `31`.

Les tests locaux prouvent que les modules compilent et que les algorithmes de base fonctionnent. Les tests physiques prouvent que Proxmox, QEMU, cgroups, Ceph, GPU, reseau et systemd se comportent comme attendu dans le datacenter.
