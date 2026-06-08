# Cluster Omega — Setup complet

Ce document couvre tout ce qui a été fait pour installer, configurer et sécuriser le cluster Omega sur 7 nœuds Proxmox. Il sert de référence pour refaire l'installation depuis zéro.

---

## 1. Topologie du cluster

### Nœuds Proxmox

| IP | Hostname | Rôle |
|---|---|---|
| 192.168.123.100 | emilia | Contrôleur Omega, pfSense (2290), DNS (2291) |
| 192.168.123.101 | ram | Nœud worker (3 VMs test max) |
| 192.168.123.102 | rem | Nœud worker (3 VMs test max) |
| 192.168.123.103 | BLADE | Nœud worker (2 VMs max) |
| 192.168.123.104 | gandal | Nœud worker (2 VMs max) |
| 192.168.123.105 | GENESIS | Nœud worker (2 VMs max) |
| 192.168.123.106 | Bris | Nœud worker (2 VMs max) |

### Distribution des VMs de test

- emilia : max **1** VM (surcharge pfSense + DNS)
- ram, rem : max **3** VMs chacun
- Autres nœuds : max **2** VMs chacun (par défaut)

Configuré dans `cluster.conf` :
```bash
OMEGA_VM_NODE_DISTRIBUTION="192.168.123.100:1,192.168.123.101:3,192.168.123.102:3"
OMEGA_VM_NODE_DEFAULT_MAX="2"
```

---

## 2. Architecture réseau

### Bridges Proxmox

| Bridge | Type | Rôle | Physique |
|---|---|---|---|
| `vmbr1` | OVS | Uplink physique + pfSense WAN | `nic0` connecté |
| `vmbr2` | Linux bridge | Réseau privé VMs (**non utilisé**) | aucun |

> **Note** : `vmbr2` a été créé mais abandonné — les VMs utilisent directement `vmbr1+tag=30`. Le switch physique passe les frames 802.1Q entre nœuds.

### Réseau physique de gestion

```
192.168.123.0/24
  └── mgmt_pve (emilia, ram, rem...) — adresses des nœuds Proxmox
  └── 192.168.123.200 — pfSense WAN
```

### Réseau privé VMs (10.50.0.0/16)

```
pfSense WAN (192.168.123.200) → pfSense LAN (10.50.0.1/16)
  ├── vtnet1 → vmbr1+tag=10 → MGMT   10.50.10.0/24
  ├── vtnet2 → vmbr1+tag=20 → INFRA  10.50.20.0/24  (DNS: 10.50.20.10)
  └── vtnet3 → vmbr1+tag=30 → OMEGA  10.50.30.0/24  (VMs test)
```

### Règles de routage sur les nœuds

Chaque nœud Proxmox a une route persistante vers le réseau privé :
```bash
ip route add 10.50.0.0/16 via 192.168.123.200
# Persistée via post-up dans /etc/network/interfaces
```
Ajoutée automatiquement par `[n]` et `[d]`.

---

## 3. pfSense (VMID 2290)

### Configuration interfaces

| Interface | NIC QEMU | Bridge Proxmox | IP | Rôle |
|---|---|---|---|---|
| WAN | vtnet0 | vmbr1 (no tag) | 192.168.123.200/24 | Internet + accès admin |
| MGMT | vtnet1 | vmbr1+tag=10 | 10.50.10.1/24 | Zone management |
| INFRA | vtnet2 | vmbr1+tag=20 | 10.50.20.1/24 | Zone infrastructure |
| OMEGA | vtnet3 | vmbr1+tag=30 | 10.50.30.1/24 | Zone VMs de test |

### Règles firewall pfSense

**WAN :**
- PASS : 192.168.123.0/24 → 10.50.0.0/16 (Protocol: any) — accès admin nodes → VMs
- PASS : 192.168.123.0/24 → 192.168.123.200:443 — accès interface web pfSense

**OMEGA :**
- PASS : OMEGA subnets → 192.168.123.0/24 — retour trafic admin
- PASS : OMEGA subnets → 10.50.20.10:53 (TCP/UDP) — DNS
- BLOCK : OMEGA subnets → any — isolation par défaut

**INFRA :**
- PASS : INFRA subnets → INFRA subnets — services internes
- BLOCK : INFRA subnets → any

**MGMT :**
- PASS : MGMT subnets → any — accès total admin
- BLOCK : any → MGMT subnets

**Floating :**
- PASS : MGMT+INFRA+OMEGA → 10.50.20.10:53 — DNS depuis toutes les zones

**NAT Outbound (Hybrid) :**
- Source: 10.50.0.0/16, Interface: WAN, Translation: WAN address

### Accès à l'interface web

```
https://192.168.123.200
admin / (mot de passe configuré)
```

**Important** : "Block private networks" doit être **désactivé** sur WAN (car réseau lab = RFC1918).

---

## 4. DNS (VMID 2291)

- **IP** : 10.50.20.10 (VLAN 20 via vmbr1+tag=20)
- **Service** : dnsmasq, zone `omega.local`
- **Entrées automatiques** : omega-dns, pfsense, omega-test-3000 → 3009

### Ajouter un enregistrement DNS

```bash
# Via omega-lab.sh [D]
[D] → register → nom: myapp → IP: 3000 → port: 8080

# Ou directement
bash scripts/dns-register.sh --name myapp --vmid 3000 --port 8080 --proto http
```

### Requêtes DNS

```bash
dig A myapp.omega.local @10.50.20.10
dig SRV _http._tcp.myapp.omega.local @10.50.20.10
```

---

## 5. VMs de test (VMID 3000–3009)

### Profil

| Paramètre | Valeur |
|---|---|
| Bridge | vmbr1, tag=30 (VLAN OMEGA) |
| IP | 10.50.30.101 → 10.50.30.110 (position dans la liste) |
| Gateway | 10.50.30.1 (pfSense OMEGA) |
| DNS | 10.50.20.10 |
| RAM | 6144 MiB max, 512 MiB balloon initial |
| vCPU | 1 boot / 6 max (hotplug Omega) |
| OS | Ubuntu Server (image préparée) |
| Firewall | `firewall=1` (pve-firewall actif) |

### Image source

- Fichier : `debian_copy-omega-prepared.qcow2` (7.8 Go)
- Préparée avec : `make prepare-image IMAGE=debian_copy.qcow2`
- Contient : QGA, openssh, stress-ng, cloud-init, omega-qga-ensure
- cloud-init drive injecte : IP statique, gateway, DNS, SSH key, bootstrap script

### Calcul d'IP

L'IP est calculée par **position dans la liste** de provisioning (pas par VMID) :
```
1er VMID → 10.50.30.101
2e VMID  → 10.50.30.102
...
```
Compatible avec n'importe quelle plage de VMIDs.

---

## 6. Isolation réseau des VMs

L'isolation est assurée par **deux couches complémentaires** :

### Couche 1 — iptables OMEGA-ISOLATION (inter-VM même VLAN)

Traffic VM→VM sur VLAN 30 **bypass pfSense** (même L2). Bloqué par iptables sur chaque nœud Proxmox.

**Chaîne `OMEGA-ISOLATION` dans FORWARD :**
```
1. ACCEPT  source=10.50.30.1          (vers gateway pfSense : toujours autorisé)
2. ACCEPT  dest=10.50.30.1            (depuis gateway pfSense : toujours autorisé)
3. [ACCEPT source=IP_A dest=IP_B]     (liens explicites ajoutés par vm-link.sh)
4. DROP    source=10.50.30.0/24 dest=10.50.30.0/24  (isolation par défaut)
```

Persistée via `iptables-persistent` / `netfilter-persistent`.

### Couche 2 — pve-firewall (inbound par VM)

Chaque VM a `/etc/pve/firewall/VMID.fw` avec `policy_in: DROP` + règles ACCEPT explicites :

```ini
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source 192.168.123.0/24   # nœuds Proxmox admin
IN ACCEPT -source 10.50.30.1         # gateway pfSense
IN ACCEPT -source 10.50.20.0/24      # zone INFRA
# Liens inter-VM ajoutés ici par vm-link.sh
```

### Couche 3 — pfSense (inter-zones et internet)

Traffic entre zones différentes ou vers internet passe par pfSense (routé via 10.50.30.1). Bloqué par défaut, autorisé explicitement.

---

## 7. Activer la communication entre VMs

### Paire de VMs

```bash
# Via omega-lab.sh [k]
[k] → enable → paire → A: 3000 → B: 3001

# Ou directement
bash scripts/vm-link.sh --vmid-a 3000 --vmid-b 3001 --enable
```

Ajoute dans `OMEGA-ISOLATION` sur tous les nœuds :
```
ACCEPT  10.50.30.101 → 10.50.30.102
ACCEPT  10.50.30.102 → 10.50.30.101
```

### Groupe de VMs (maillage complet)

```bash
bash scripts/vm-link.sh --group 3000,3001,3002 --group-name backend --enable
# → 3 paires ACCEPT créées (3000↔3001, 3000↔3002, 3001↔3002)
# A↔B et A↔C n'impliquent PAS B↔C
```

### Supprimer un lien

```bash
bash scripts/vm-link.sh --vmid-a 3000 --vmid-b 3001 --disable
bash scripts/vm-link.sh --group-name backend --disable
```

---

## 8. Activer l'accès internet pour une VM

```bash
# Via omega-lab.sh [w]
[w] → enable → 3000

# Ou directement
bash scripts/vm-internet.sh --vmid 3000 --enable
```

Ajoute dans pfSense WAN :
- Règle PASS : 10.50.30.101 → WAN
- Règle NAT outbound : 10.50.30.101/32 → WAN address

```bash
# Désactiver
bash scripts/vm-internet.sh --vmid 3000 --disable

# Lister les VMs avec internet
bash scripts/vm-internet.sh --list
```

---

## 9. Workflow complet — installation depuis zéro

```
omega-lab.sh
├── [c]  Configurer le cluster (nœuds, VMIDs, bridge, image)
├── [n]  Setup réseau
│         → vmbr2 sur tous les nœuds (inutilisé mais créé)
│         → cluster.fw pve-firewall (ACCEPT admin + gateway)
│         → chaîne OMEGA-ISOLATION iptables + persistance
│         → route 10.50.0.0/16 via pfSense sur tous les nœuds
├── [v]  Supprimer VMs infra existantes (pfSense, DNS, routeur...)
├── [N]  Créer VMs infra
│         → pfSense VMID 2290 (install manuelle depuis console)
│         → DNS VMID 2291 (automatique : dnsmasq + zone omega.local)
├── [I]  Installer Omega
│         → désinstallation propre (services, dpkg, sysctl, kvm wrapper)
│         → compilation Rust + bridge C
│         → déploiement .deb
│         → OMEGA-ISOLATION réinitialisée
│         → route réseau privé ajoutée
└── [p]  Provisionner les VMs de test
          → distribution par nœud (cluster.conf)
          → IP fixe par position dans la liste
          → VLAN 30 sur vmbr1
          → firewall=1 + .fw par VM
          → cloud-init : IP, gateway, DNS, SSH, bootstrap
```

### Commandes séquentielles

```bash
bash scripts/omega-lab.sh
# Ordre recommandé après un wipe complet :
# 1. [c] → configurer
# 2. [n] → setup réseau
# 3. [v] → supprimer anciens infra VMs
# 4. [N] → créer pfSense + DNS
#    → installer pfSense manuellement (voir docs/architecture-reseau.md)
# 5. [I] → installer Omega
# 6. [p] → provisionner VMs
```

---

## 10. Accès aux VMs

### Depuis la machine dev ou un nœud Proxmox

```bash
# SSH direct (via pfSense qui route)
ssh root@10.50.30.101   # VM 3000
ssh root@10.50.30.110   # VM 3009

# Depuis un nœud Proxmox (la route est automatiquement configurée)
ssh root@192.168.123.101  # ram
ping 10.50.30.103         # VM 3002
ssh root@10.50.30.103
```

### Console (sans réseau)

```bash
# Sur le nœud hébergeant la VM
qm terminal 3002   # console série
# Ou via l'UI Proxmox : VM → Console
```

---

## 11. Nettoyage et reconstruction des VMs

```bash
# Supprimer toutes les VMs omega-test
bash scripts/omega-lab.sh  # [v] → liste les VMIDs infra + omega-test

# Ou manuellement
ssh root@192.168.123.101 "
for vmid in 3000 3001 3002 ...; do
  qm stop $vmid --skiplock; qm destroy $vmid --purge
done"
```

---

## 12. Fichiers de configuration principaux

| Fichier | Rôle |
|---|---|
| `scripts/cluster.conf` | Configuration principale : nœuds, VMs, réseau, distribution |
| `/etc/pve/firewall/cluster.fw` | Règles pve-firewall datacenter (allow admin inbound) |
| `/etc/pve/firewall/VMID.fw` | Règles pve-firewall par VM (policy_in:DROP + ACCEPT explicites) |
| `/etc/iptables/rules.v4` | Règles iptables persistées (chaîne OMEGA-ISOLATION) |
| `/etc/network/interfaces` | Routes persistantes 10.50.0.0/16 (post-up) |
| `/etc/dnsmasq.d/omega.conf` | Zone DNS omega.local (sur VM 2291) |
| `/etc/dnsmasq.d/omega-custom.conf` | Entrées DNS personnalisées (ajoutées par dns-register.sh) |

---

## 13. Diagnostics rapides

```bash
# Vérifier isolation sur ram
ssh root@192.168.123.101 "iptables -L OMEGA-ISOLATION -n -v"

# Vérifier règles pve-firewall VM
ssh root@192.168.123.101 "iptables -L tap3002i0-IN -n -v"

# Vérifier IPs des VMs
ssh root@192.168.123.101 "
for v in \$(qm list | awk 'NR>1 && /omega-test/ {print \$1}'); do
  ip=\$(qm guest cmd \$v network-get-interfaces 2>/dev/null \
    | python3 -c \"import json,sys
for i in json.load(sys.stdin):
 for a in i.get('ip-addresses',[]):
  ip=a.get('ip-address','')
  if ip and not ip.startswith('127.') and ':' not in ip: print(ip); exit()
\" 2>/dev/null || echo '?')
  echo \"VM \$v: \$ip\"
done"

# Tester DNS depuis un nœud
dig @10.50.20.10 omega-test-3000.omega.local

# Voir les liens VM actifs
bash scripts/vm-link.sh --list

# Voir les VMs avec internet
bash scripts/vm-internet.sh --list
```

---

## 14. Points importants / pièges

1. **`vmbr1` est le bridge physique** (OVS avec `nic0`) — pas `vmbr0` qui n'existe pas sur emilia/ram/rem.

2. **pfSense WAN bridge = `vmbr1`** (sans tag) — le switch physique passe les frames VLAN entre nœuds.

3. **"Block private networks" sur WAN = désactivé** — réseau lab = RFC1918, pfSense bloquerait tout sinon.

4. **pve-firewall `cluster.fw` ne s'applique pas aux VMs** — les règles IN pour les VMs doivent être dans chaque `VMID.fw`.

5. **Isolation intra-VLAN via iptables** — pfSense ne voit pas le trafic VM↔VM sur le même VLAN. C'est `OMEGA-ISOLATION` qui gère ça au niveau du nœud Proxmox.

6. **IP calculée par position** — VMID 3000 = `.101`, 3001 = `.102`, etc. Fonctionne avec n'importe quelle plage de VMIDs.

7. **cloud-init ne s'exécute qu'une fois** — si CFS lock échoue pendant la création du disque cloud-init, l'IP n'est pas injectée. Fix : `qm cloudinit update VMID && qm stop VMID && qm start VMID`.

8. **QGA garantie par `omega-qga-ensure`** — service systemd oneshot qui démarre après `sysinit.target`, attend le device virtio et (re)démarre QGA. S'exécute à chaque boot.

9. **pfSense SSH** — pfSense gère ses clés SSH via config.xml, pas via `.ssh/authorized_keys`. Ajouter la clé via : System → User Manager → admin → Authorized SSH Keys. SSH doit être activé (option 14 console ou System → Advanced → Admin Access). Port 22 doit être ouvert sur WAN (easyrule ou Firewall → Rules → WAN).

10. **VM DNS (2291) — bootstrap manuel requis** — la VM DNS n'est pas créée par le provisioning standard. Elle nécessite : un snippet `omega-bootstrap-2291.yaml` dans `/var/lib/vz/snippets/`, l'accès internet temporaire via `[w]`, et `package_update: false` dans le snippet pour éviter les mises à jour inutiles.

---

## 15. Approche "Golden Image" — comment éviter les vérifications manuelles

### Le problème actuel

Chaque VM fait `apt-get install` au boot via cloud-init → lent, dépend du réseau, peut échouer silencieusement.

### Ce que font AWS, GCP, Azure

**Golden AMI / Machine Image** : l'image de base contient DÉJÀ tous les logiciels installés. cloud-init ne fait que la **configuration** (hostname, IP, clé SSH) — jamais l'installation.

```
Image "bête" (Ubuntu brut)     →  boot = 10 min (apt-get tout)
Image "golden" (tout pré-baked) →  boot = 30 secondes (config seulement)
```

### Comment appliquer ça à Omega

**Règle : une image par rôle**

| Rôle | Image | Contenu pré-installé |
|---|---|---|
| VMs test | `base-omega.qcow2` | QGA, SSH, stress-ng, omega-qga-ensure |
| VM DNS | `dns-omega.qcow2` | Base + dnsmasq |
| VM infra future | `infra-omega.qcow2` | Base + outils spécifiques |

**Construction via omega-lab.sh :**
```
[G] → dns    ← construit debian_copy-dns-omega.qcow2 sur le contrôleur
[G] → base   ← copie l'image base locale sur le cluster
[G] → all    ← les deux
```

Le `[G]` installe `libguestfs-tools` si absent, copie l'image base, installe dnsmasq via `virt-customize`, et vérifie le binaire.

**Construction manuelle (sur le nœud contrôleur) :**
```bash
# Image de base — depuis la machine dev
make prepare-image IMAGE=debian_copy.qcow2   # → debian_copy-omega-prepared.qcow2

# Image DNS — sur le contrôleur Proxmox (a internet + libguestfs)
apt install -y libguestfs-tools
cp debian_copy-omega-prepared.qcow2 debian_copy-dns-omega.qcow2
LIBGUESTFS_BACKEND=direct virt-customize \
  -a debian_copy-dns-omega.qcow2 \
  --run-command "apt-get update -qq && apt-get install -y dnsmasq-base -qq" \
  --run-command "apt-get clean"
# → /var/lib/vz/template/iso/debian_copy-dns-omega.qcow2
```

**Note** : Ubuntu Universe requis pour dnsmasq. Le script installe `dnsmasq-base` (même binaire, disponible sans Universe).

**Dans `cluster.conf` :**
```bash
OMEGA_VM_IMAGE_LOCAL="...debian_copy-omega-prepared.qcow2"          # VMs clientes
OMEGA_NET_INFRA_DNS_IMAGE_REMOTE="/var/lib/vz/template/iso/debian_copy-dns-omega.qcow2"  # VM DNS
```

### Validation automatique

Le provisioning omega-lab.sh `[p]` valide déjà QGA, SSH et stress-ng pour chaque VM. En mode `OMEGA_PROVISION_RESOURCE_ONLY=0`, il attend que QGA réponde avant de passer à la VM suivante.

Le **watchdog QGA** (`omega-qga-watchdog.timer`) surveille toutes les VMs et redémarre QGA si nécessaire — sans intervention manuelle.

### Les 3 principes

1. **Image pré-baked** : tout logiciel dans l'image, jamais apt-get au boot
2. **cloud-init = config seulement** : hostname, IP, clé SSH, `package_update: false`
3. **Monitoring automatique** : watchdog QGA + provision avec validation intégrée
