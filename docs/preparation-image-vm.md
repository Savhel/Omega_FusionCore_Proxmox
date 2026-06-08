# Préparation de l'image VM pour Omega

## La bonne méthode : ISO → install manuelle → qcow2

Prendre un ISO, installer l'OS dans une VM KVM, copier le `.qcow2` du disque, c'est **la bonne approche**. Elle donne une image propre, sans cloud-init, avec exactement les paquets voulus.

C'est mieux qu'une image cloud (Ubuntu Cloud Image, Debian Cloud) car :
- pas de dépendance à cloud-init pour QGA et le reste
- tout est installé hors-ligne, avant d'arriver sur le cluster
- marche avec n'importe quel ISO (Ubuntu Server, Debian, Rocky Linux, etc.)

**Limitation à corriger impérativement** : le `machine-id` est figé dans l'image. Tous les clones Proxmox auront le même identifiant → collision DHCP (tous obtiennent la même IP), collision SSH host key. Sur un cluster de 10 VMs, ça casse tout silencieusement.

---

## Ce que `prepare-omega-image.sh` ajoute

Le script `scripts/prepare-omega-image.sh` complète l'image existante (il ne réinstalle pas ce qui est déjà là) :

| Ce que le script fait | Pourquoi |
|---|---|
| `--install qemu-guest-agent,openssh-server,stress-ng` | no-op si déjà installé ; sinon installe offline |
| Installe le service `omega-qga-ensure` (oneshot, chaque boot) | Garantit QGA actif malgré la race condition udev/virtio au boot |
| Configure SSH root login (`PermitRootLogin yes`) | Nécessaire pour les scripts de provisioning Omega |
| Efface `/etc/machine-id` | Chaque clone génère son propre ID → DHCP et SSH uniques |

Le service `omega-qga-ensure` résout le vrai problème de QGA sur les images manuelles : il attend que le device virtio `/dev/virtio-ports/org.qemu.guest_agent.0` apparaisse avant de démarrer QGA, avec jusqu'à 10 tentatives espacées de 2s. Les images cloud ne sont pas affectées car udev déclenche QGA proprement ; les images installées manuellement ont une race condition que ce service contourne.

---

## Workflow complet

### 1. Préparer l'image (une seule fois, sur la machine dev)

```bash
make prepare-image IMAGE=/chemin/vers/debian_copy.qcow2
# → produit debian_copy-omega-prepared.qcow2
```

Si `virt-customize` n'est pas installé, le script l'installe automatiquement via `apt`.

Vérifier que `cluster.conf` pointe vers l'image préparée :
```bash
OMEGA_VM_IMAGE_LOCAL="/chemin/vers/debian_copy-omega-prepared.qcow2"
OMEGA_VM_IMAGE_PREPARED="1"
```

### 2. Pousser les clés SSH sur le cluster (via omega-lab.sh)

```bash
bash scripts/omega-lab.sh   # action [c] → ssh-copy-id sur tous les nœuds
```

### 3. Provisionner les VMs

```bash
bash scripts/omega-lab.sh   # action [p] → crée template 2298 + VMs 2300-2309
```

### 4. Déployer le daemon Omega

```bash
make deploy-deb
```

### 5. Vérifier QGA dans une VM après boot

```bash
ssh root@<ip-vm> 'systemctl is-active qemu-guest-agent; cat /var/log/omega-qga-ensure.log'
```

---

## Options de `prepare-omega-image.sh`

```
--image PATH         Image source (qcow2 ou raw). REQUIS.
--output PATH        Sortie. Défaut: <image>-omega-prepared.qcow2
--root-password PASS Mot de passe root. Défaut: root
--in-place           Modifie l'image source directement. DANGER.
--no-stress-ng       Ne pas installer stress-ng (si repo inaccessible).
--extra-packages CSV Paquets supplémentaires (séparés par virgule).
```

Exemple avec image Rocky Linux :
```bash
make prepare-image IMAGE=rocky9.qcow2 PREPARE_ARGS="--no-stress-ng"
```
