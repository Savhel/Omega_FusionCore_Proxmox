# Plan Network Adapte Au Cluster Omega

Ce document corrige le plan `plan_implementation_gandal.html` pour l'adapter au cluster Omega reel et formalise le modele reseau attendu pour les VMs.

Objectif principal : creer automatiquement des reseaux prives pour les VMs, avec une isolation stricte par defaut, une sortie Internet optionnelle, et des communications VM-to-VM explicites via VNets/VLANs.

---

## 1. Contraintes Du Cluster Reel

Le cluster Proxmox contient 7 noeuds, mais seuls 3 doivent heberger des VMs.

| Role | Noeuds | Usage |
|---|---|---|
| Compute Omega | `192.168.123.100`, `192.168.123.101`, `192.168.123.102` | VMs, migrations, services Network |
| Storage-only | `192.168.123.103`, `192.168.123.104`, `192.168.123.105`, `192.168.123.106` | Ceph, archives, sauvegardes, quorum |

Les noeuds storage-only ne doivent pas recevoir de VMs car ils n'ont pas `/dev/kvm`.

Dans `scripts/cluster.conf` :

```bash
OMEGA_NODES="192.168.123.100,192.168.123.101,192.168.123.102"
OMEGA_STORAGE_ONLY_NODES="192.168.123.103,192.168.123.104,192.168.123.105,192.168.123.106"
OMEGA_ARCHIVE_STORAGE="omega-archive"
```

Le plan Network doit donc deployer les VMs de service uniquement sur `OMEGA_NODES`.

---

## 2. Principe Reseau Produit

Chaque VM creee dans Omega suit ces regles :

1. Une VM nait isolee.
2. Elle recoit une IP privee dans `10.x.x.x` uniquement sur les reseaux auxquels elle est explicitement attachee.
3. Elle ne communique avec aucune autre VM par defaut.
4. Elle peut avoir Internet seulement si l'autorisation est activee.
5. La sortie Internet passe par un routeur/NAT Omega qui sort vers le reseau physique `192.168.123.0/24`, avec `192.168.123.1` comme gateway amont.
6. Toute communication VM-to-VM doit etre declaree, puis materialisee par un VNet/VLAN.
7. Une VM peut appartenir a plusieurs VNets si elle doit communiquer avec plusieurs groupes separes.

Important : les VMs ne doivent pas avoir `192.168.123.1` directement comme gateway. Elles restent en `10.x.x.x`. Le routeur/NAT Omega porte une interface cote `10.x.x.x` et une interface cote `192.168.123.0/24`, puis route/NAT vers `192.168.123.1`.

---

## 3. Modele De Communication

### 3.1 VM creee seule

Etat initial :

```text
VM A
- aucun VNet prive partage
- aucune communication avec les autres VMs
- Internet: non, sauf si autorise
```

Si Internet est autorise :

```text
VM A -> VNet egress dedie ou partage controle -> routeur/NAT Omega -> 192.168.123.1 -> Internet
```

Si Internet n'est pas autorise :

```text
VM A -> aucun chemin sortant
```

### 3.2 Relier deux VMs

Si on decide que `VM A` doit communiquer avec `VM B`, Omega cree automatiquement un VNet/VLAN dedie :

```text
VNet link-AB
- subnet: 10.x.y.0/24
- membres: VM A, VM B
```

Les deux VMs recoivent chacune une interface reseau supplementaire dans ce VNet.

### 3.3 Ajouter une troisieme VM sans exposer tout le groupe

Cas : `VM A` communique deja avec `VM B`, puis on veut ajouter `VM C` pour communiquer avec `VM A`, mais pas avec `VM B`.

Il ne faut pas ajouter `VM C` au VNet `link-AB`, sinon `VM C` pourrait parler a `VM B`.

Il faut creer un second VNet :

```text
VNet link-AB
- membres: VM A, VM B

VNet link-AC
- membres: VM A, VM C
```

`VM A` aura deux interfaces privees : une dans `link-AB`, une dans `link-AC`.

### 3.4 Creer un groupe de communication

Une personne peut aussi creer un VNet explicite et y ajouter plusieurs VMs :

```text
VNet app-prod
- membres: VM frontend
- membres: VM backend
- membres: VM db
```

Toutes les VMs du VNet peuvent communiquer entre elles, sauf si une politique firewall vient restreindre les flux.

### 3.5 Invitation d'une autre personne

La notion de personnes/utilisateurs n'est pas encore geree ici. Pour l'instant, on modelise seulement :

```text
VMs
VNets
relations VM <-> VNet
```

Plus tard, l'invitation d'une personne reviendra a autoriser cette personne a ajouter certaines de ses VMs dans un VNet existant.

---

## 4. Plan D'Adressage 10.x.x.x

Toutes les VMs doivent recevoir des adresses `10.x.x.x`.

Proposition simple :

| Type de reseau | Plage | Usage |
|---|---|---|
| Infra Network | `10.10.0.0/24` | DNS, DHCP, routeurs, services Network |
| Monitoring | `10.10.1.0/24` | Prometheus, Grafana, Loki |
| Security | `10.10.2.0/24` | Firewall, WireGuard, NAT |
| Storage services | `10.10.3.0/24` | Services internes lies au stockage |
| VNets dynamiques | `10.64.0.0/10` | VNets utilisateurs/VM-to-VM automatiques |

Allocation recommandee pour les VNets dynamiques :

```text
10.64.0.0/24      premier VNet dynamique
10.64.1.0/24      deuxieme VNet dynamique
10.64.2.0/24      troisieme VNet dynamique
...
```

Chaque VNet dynamique recoit :

```text
VLAN tag Proxmox/SDN unique
subnet /24 unique
nom stable
liste de VM membres
politique Internet oui/non
```

---

## 5. Internet Optionnel

Internet ne doit pas etre implicite.

### VM sans Internet

```text
VM A
- pas de route par defaut vers Internet
- pas de NAT
- seulement les VNets prives explicitement attaches
```

### VM avec Internet autorise

```text
VM A
- IP 10.x.x.x sur un VNet egress
- gateway 10.x.x.1, portee par le routeur/NAT Omega
- NAT vers 192.168.123.0/24
- sortie finale via 192.168.123.1
```

Le routeur/NAT Omega peut etre :
- une VM pfSense/opnSense ;
- une VM Linux avec nftables ;
- plus tard, un service Network Omega dedie.

Regle : l'autorisation Internet est une propriete de la VM ou du VNet, pas un effet secondaire de la creation de VM.

---

## 6. Representation Minimale Dans Omega

La cellule Network doit raisonner avec ces objets minimum :

```text
VmNetworkAttachment
- vmid
- vnet_id
- mac_address
- ip_address
- firewall_profile

VNet
- id
- name
- vlan_tag
- subnet_cidr
- gateway_ip
- internet_allowed
- created_for

NetworkRelation
- relation_id
- relation_type: pair | group
- members: vmids[]
- vnet_id
```

Exemples :

```text
create_vm(2301)
-> VM isolee, pas de VNet relationnel

allow_internet(2301)
-> attache VM 2301 a un VNet egress controle

connect_vms(2301, 2302)
-> cree VNet link-2301-2302
-> ajoute une NIC a 2301
-> ajoute une NIC a 2302

connect_vms(2301, 2303, isolated_from=2302)
-> cree VNet link-2301-2303
-> ajoute une nouvelle NIC a 2301
-> ajoute une NIC a 2303
```

---

## 7. Implementation Proxmox SDN

Le plan original propose SDN Proxmox. C'est acceptable, mais l'ordre doit etre corrige.

Ordre recommande :

1. Homogeneiser les paquets Proxmox/SDN sur tous les noeuds.
2. Ne pas modifier Corosync/Ceph au debut.
3. Creer une zone SDN simple pour les VNets dynamiques.
4. Creer les VNets avec tags VLAN uniques.
5. Attacher les VMs aux VNets selon les relations demandees.
6. Ajouter le routeur/NAT pour Internet autorise.
7. Ajouter Kea/PowerDNS ensuite.
8. Tester migration VM entre les trois noeuds compute.

Ne pas commencer par separer Corosync/Ceph. C'est une operation critique, a faire seulement quand le SDN VM fonctionne deja et que les interfaces physiques sont bien inventoriees.

---

## 8. Exemple De VNet Dynamique

Creation d'un VNet pour relier `2301` et `2302` :

```bash
pvesh create /cluster/sdn/vnets \
  --vnet link-2301-2302 \
  --zone omega-dynamic \
  --tag 2001

pvesh create /cluster/sdn/vnets/link-2301-2302/subnets \
  --subnet 10.64.1.0/24 \
  --gateway 10.64.1.1

pvesh set /cluster/sdn
```

Attacher les VMs :

```bash
qm set 2301 --net1 virtio,bridge=link-2301-2302
qm set 2302 --net1 virtio,bridge=link-2301-2302
```

Selon le type d'image, l'IP peut etre attribuee par :
- cloud-init ;
- DHCP Kea ;
- configuration statique injectee par Omega.

---

## 9. Ce Qui Change Dans Le Plan Original

A corriger dans `plan_implementation_gandal.html` :

| Element original | Correction Omega |
|---|---|
| Deployer des VMs de service sur les 7 noeuds | Deployer uniquement sur `192.168.123.100`, `.101`, `.102` |
| Utiliser GANDAL comme noeud VM | GANDAL est storage-only |
| Toucher Corosync/Ceph en Phase 1 | Reporter apres validation SDN VM |
| Reseau VM implicite | VM isolee par defaut |
| Internet implicite | Internet optionnel via NAT vers `192.168.123.1` |
| Communication client large | VNet cree explicitement par relation |
| Ajouter une VM a un groupe existant sans verification | Ajouter uniquement si elle doit parler a tous les membres du groupe |
| Cas A parle a B et C, mais B ne doit pas parler a C | A doit etre multi-attachee a deux VNets separes |

---

## 10. Regles De Validation

Avant de declarer la cellule Network prete :

```bash
pvecm status
ceph -s
pvesm status
pvesh get /cluster/sdn
```

Pour chaque VM test :

```bash
ip addr
ip route
ping <gateway-vnet>
ping 1.1.1.1        # seulement si Internet autorise
ping <autre-vm>     # seulement si meme VNet relationnel
```

Tests obligatoires :

1. VM seule sans Internet : ne ping personne, pas de route Internet.
2. VM seule avec Internet : ping Internet, ne ping pas les autres VMs.
3. Deux VMs reliees : elles se pingent entre elles.
4. Trois VMs A/B/C avec A-B et A-C separes : A ping B et C, mais B ne ping pas C.
5. VNet groupe : tous les membres du groupe se pingent.
6. Migration d'une VM entre `.100`, `.101`, `.102` : l'IP et la connectivite restent stables.

---

## 11. Resume Produit

La logique attendue est :

```text
VM creee = isolee
Internet = autorisation explicite
Communication VM-to-VM = VNet/VLAN explicite
Communication de groupe = VNet/VLAN de groupe
Communication partielle = plusieurs VNets, VM multi-attachee
Utilisateurs/personnes = hors scope pour l'instant
```

C'est ce modele que la cellule Network doit implementer avant d'ajouter la gestion des personnes, invitations et permissions avancees.
