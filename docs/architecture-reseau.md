# Architecture réseau Omega

## Vue d'ensemble

```
Internet / Réseau école
        │
  192.168.123.0/24
        │
  ┌─────┴─────┐
  │   vmbr0   │  ← bridge physique sur TOUS les nœuds Proxmox
  │  (uplink) │    gestion PVE + WAN pfSense
  └─────┬─────┘
        │
  ┌─────┴──────────────┐
  │  pfSense VM 2290   │  WAN: 192.168.123.200
  │  routeur/firewall  │  LAN: 10.50.0.1/16 (trunk VLAN sur vmbr1)
  └─────┬──────────────┘
        │
  ┌─────┴─────┐
  │   vmbr1   │  ← bridge VLAN-aware, sans port physique, sur TOUS les nœuds
  │  (privé)  │    VMs et pfSense se voient via ce bridge
  └─────┬─────┘
        │
  ┌─────┴──────────────────────────────────────────┐
  │                                                │
  VLAN 10            VLAN 20           VLAN 30
  Management         Infra             Omega (test)
  10.50.10.0/24      10.50.20.0/24     10.50.30.0/24
  GW: 10.50.10.1     GW: 10.50.20.1    GW: 10.50.30.1
                          │
                     ┌────┴────┐
                     DNS 2291  │
                  10.50.20.10  │
                     zone:     │
                   omega.local │
                               │
                    VM 2300-2309 (VLAN 30)
                    10.50.30.101 → .110
```

## Règles d'isolation (pfSense)

### Principe de base

**Par défaut, une VM est totalement isolée :**
- ❌ Pas d'accès internet
- ❌ Pas de communication vers d'autres VMs (même VLAN)
- ✅ Peut contacter le DNS interne (10.50.20.10)
- ✅ Peut être pingée depuis le management (VLAN 10)

### Règles par zone

#### VLAN 10 — Management
| Source | Destination | Action | Commentaire |
|---|---|---|---|
| 10.50.10.0/24 | any | ALLOW | Les admins peuvent tout atteindre |
| any | 10.50.10.0/24 | BLOCK | Aucune VM ne peut initier vers mgmt |

#### VLAN 20 — Infra
| Source | Destination | Action | Commentaire |
|---|---|---|---|
| any | 10.50.20.10 port 53 | ALLOW | DNS accessible depuis toutes les zones |
| 10.50.20.0/24 | WAN | ALLOW | Infra peut sortir (mises à jour paquets) |
| 10.50.20.0/24 | 10.50.20.0/24 | ALLOW | Services infra communiquent entre eux |

#### VLAN 30 — Omega (VMs de test)
| Source | Destination | Action | Commentaire |
|---|---|---|---|
| 10.50.30.0/24 | 10.50.20.10 port 53 | ALLOW | DNS |
| 10.50.30.0/24 | 10.50.30.0/24 | ALLOW | VMs Omega se parlent entre elles |
| 10.50.30.0/24 | WAN | **BLOCK** | Pas d'internet par défaut |
| 10.50.30.0/24 | other VLANs | **BLOCK** | Pas d'accès aux autres zones |

> **Activer internet pour une VM :** Ajouter une règle pfSense `ALLOW src=10.50.30.X dst=WAN`.
>
> **Relier deux VMs de zones différentes :** Créer une règle bidirectionnelle sur les deux VLANs concernés, en ciblant les IPs précises.

### Canaux inter-VLAN (isolation fine)

Pour mettre deux VMs de zones différentes en réseau sans que leurs zones respectives se voient :

```
VLAN 100 (clientA)  ←→  VLAN 101 (clientB)
```

Règles pfSense à créer :
- `ALLOW 10.50.100.X → 10.50.101.Y`
- `ALLOW 10.50.101.Y → 10.50.100.X`
- Le reste de VLAN 100 et VLAN 101 reste bloqué.

## Plan d'adressage

| Zone | VLAN | Réseau | Gateway pfSense | Plage VMs |
|---|---|---|---|---|
| Management | 10 | 10.50.10.0/24 | 10.50.10.1 | 10.50.10.10-254 |
| Infra | 20 | 10.50.20.0/24 | 10.50.20.1 | 10.50.20.10-254 |
| Omega test | 30 | 10.50.30.0/24 | 10.50.30.1 | 10.50.30.101-254 |
| Client A | 100 | 10.50.100.0/24 | 10.50.100.1 | 10.50.100.10-254 |
| Client B | 101 | 10.50.101.0/24 | 10.50.101.1 | 10.50.101.10-254 |
| … | 102+ | 10.50.10X.0/24 | — | — |

### VMs réservées

| VMID | Nom | IP | Rôle |
|---|---|---|---|
| 2290 | pfsense-omega | 192.168.123.200 (WAN), 10.50.0.1 (LAN) | Routeur/firewall |
| 2291 | omega-dns | 10.50.20.10 | DNS interne (zone omega.local) |
| 2298 | Template | — | Template Proxmox (linked clone base) |
| 2300–2309 | omega-test-* | 10.50.30.101–.110 | VMs de test Omega |

## DNS interne (omega.local)

La VM DNS (dnsmasq) résout :

```
omega-dns.omega.local        → 10.50.20.10
pfsense.omega.local          → 192.168.123.200
omega-test-2300.omega.local  → 10.50.30.101
omega-test-2301.omega.local  → 10.50.30.102
...
omega-test-2309.omega.local  → 10.50.30.110
```

Resolver depuis un nœud Proxmox :
```bash
dig @10.50.20.10 omega-test-2300.omega.local
```

## Déploiement étape par étape

### Étape 1 — Bridge vmbr1 sur tous les nœuds

```bash
bash scripts/setup-network.sh
# Crée vmbr1 (VLAN-aware, sans port physique) sur les 7 nœuds
```

### Étape 2 — VM pfSense

```bash
bash scripts/create-infra-vms.sh --pfsense
# Crée la VM 2290, affiche les instructions d'installation manuelle
```

**Installation manuelle pfSense :**
1. Démarrer VM 2290 : `qm start 2290`
2. Console Proxmox → suivre l'installeur pfSense
3. Après install, sur l'interface CLI pfSense :
   - Interface 1 (WAN) = `vtnet0` → IP: `192.168.123.200/24`, GW: `192.168.123.1`
   - Interface 2 (LAN) = `vtnet1` → IP: `10.50.0.1/16`
4. Accéder à `https://192.168.123.200` → `admin / pfsense`
5. **Créer les VLAN** sur vtnet1 :
   ```
   Interfaces > VLANs > Add
   VLAN 10 : vtnet1.10 → 10.50.10.1/24
   VLAN 20 : vtnet1.20 → 10.50.20.1/24
   VLAN 30 : vtnet1.30 → 10.50.30.1/24
   ```
6. **Appliquer les règles firewall** (tableau ci-dessus)
7. **DHCP optionnel** : activer par VLAN si on ne veut pas injecter les IPs par cloud-init

### Étape 3 — VM DNS

```bash
bash scripts/create-infra-vms.sh --dns
# Crée la VM 2291 sur vmbr1 VLAN 20, installe et configure dnsmasq
```

### Étape 4 — Mettre à jour cluster.conf

```bash
# Dans scripts/cluster.conf, activer le réseau privé :
OMEGA_NET_VM_BRIDGE="vmbr1"
OMEGA_NET_VM_VLAN_TAG="30"
OMEGA_NET_VM_IP_PREFIX="10.50.30"
OMEGA_NET_VM_GATEWAY="10.50.30.1"
OMEGA_NET_VM_DNS_IP="10.50.20.10"
```

### Étape 5 — Re-provisionner les VMs de test

```bash
bash scripts/omega-lab.sh   # action [p]
# Les VMs 2300-2309 sont recréées avec :
#   - IP fixe 10.50.30.101-110
#   - VLAN tag 30
#   - DNS = 10.50.20.10
#   - Isolation pfSense active
```

## Ajout d'un nouveau VLAN client

```bash
# 1. Créer le VLAN dans pfSense (UI web) :
#    vtnet1.100 → 10.50.100.1/24

# 2. Créer des VMs sur ce VLAN :
bash scripts/create-omega-vm.sh \
    --vmids 3000,3001 \
    --storage stockage.ceph \
    --bridge vmbr1 \
    --vlan-tag 100 \
    --ipconfig0 "ip=10.50.100.10/24,gw=10.50.100.1" \
    --nameserver 10.50.20.10 \
    --template-id 2298 \
    --linked-clone \
    --start

# 3. Ajouter les entrées DNS dans la VM DNS :
ssh root@10.50.20.10 "echo 'address=/client-3000.omega.local/10.50.100.10' >> /etc/dnsmasq.d/omega.conf && systemctl reload dnsmasq"
```

## Vérifications

```bash
# Depuis un nœud Proxmox
ping 10.50.20.10              # VM DNS joignable
dig @10.50.20.10 omega-test-2300.omega.local  # résolution DNS

# Depuis la VM DNS (10.50.20.10)
ping 10.50.30.101             # VM 2300 joignable

# Depuis une VM Omega (10.50.30.101)
ping 10.50.20.10              # DNS OK
ping 8.8.8.8                  # doit échouer (isolée par défaut)
ping 10.50.30.102             # autre VM Omega OK (même VLAN)
```
