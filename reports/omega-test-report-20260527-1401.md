# Rapport de test Omega cluster

Date: 2026-05-27 14:01 Africa/Douala  
Log brut: `reports/omega-cluster-test-20260527-133447.log`  
Commande: `OMEGA_SKIP=M7 OMEGA_TEST08_TARGET_NODE=192.168.123.102 bash scripts/tests/run-cluster.sh 2304 --ceph`

## Verdict

**Pas encore deployable en permanent.** Le coeur Omega passe beaucoup de tests, et le probleme QGA est maintenant pris en charge par watchdog automatique, mais la passe contient encore 10 echecs.

Bilan runner: **17 PASS, 10 FAIL, 10 SKIP**.

## Points valides

- Watchdog QGA installe sur `192.168.123.100`, `192.168.123.101`, `192.168.123.102`, intervalle `10s`.
- QGA post-tests OK sur `2304`, `2306`, `2309`.
- Tests unitaires: 275 tests OK.
- Eviction, replication, failover, recall LIFO, prefetch, TLS TOFU: OK.
- Multi-VM: `2304`, `2306`, `2309` OK simultanement.
- Ceph reel: test 26 OK.
- Stress cluster M4 et rafale M6: OK.

## Resume des tests

```text
  PASS  00 Tests unitaires
  PASS  01 Smoke test
  PASS  02 Réplication 2 stores
  PASS  03 Failover store
  PASS  04 Éviction daemon
  PASS  10 Multi-VM 3 agents
  PASS  18 Recall LIFO
  PASS  20 Prefetch stride
  PASS  21 TLS TOFU
  PASS  23 Disk I/O scheduler
  FAIL  30A Normalisation VMs Omega
  FAIL  05 vCPU élastique
  FAIL  08 Migration RAM
  PASS  09 Orphan cleaner
  PASS  19 Compaction cluster
  FAIL  22 Balloon thin-provisioning
  PASS  23C Disk I/O scheduler cluster
  FAIL  30 Conformité VMs Omega
  FAIL  24 Installation doctor
  FAIL  25 Réseau VM invitée
  FAIL  38 Déploiement .deb
  PASS  26 Ceph réel
  FAIL  M1 RAM + CPU simultanés
  PASS  M2 CPU+RAM saturés → migration
  PASS  M4 Stress cluster complet
  FAIL  M5 Migration live sous pression
  PASS  M6 Rafale démarrages simultanés
```

## Echecs et causes observees

### 30A / 30 - Conformite VMs Omega

`2306` et `2309` ont QGA OK, mais leur profil CPU Proxmox est incoherent:

- `2306`: `cores=1`, `vcpus=1`, description `omega_max_vcpus=2`.
- `2309`: `cores=1`, `vcpus=1`, description `omega_max_vcpus=6`.

Correction attendue: remettre `cores` au max declare, garder `vcpus=1`, puis stop/start propre.

### 05 - vCPU elastique

Le test attend `1` vCPU au demarrage de l'agent, mais la VM passe deja a `2` vCPU avant la verification. A investiguer cote scheduler vCPU/test harness: la montee arrive trop tot pour le test.

### 08 / M5 - Migration live

La migration Proxmox de `2304` de `ram` vers `rem` echoue avec timeout QMP:

```text
VM 2304 qmp command 'query-named-block-nodes' failed - got timeout
VM 2304 qmp command 'query-machines' failed - got timeout
```

Ce n'est pas un probleme QGA direct. C'est a traiter cote Proxmox/QMP/migration sous charge, potentiellement avec charge trop forte, fleecing cleanup, ou etat QEMU degrade.

### 22 - Balloon thin-provisioning

Le balloon grandit, mais l'escalade migration n'est pas observee. Les logs montrent aussi une erreur de noeud:

```text
qm monitor 2304 balloon 1536: Configuration file 'nodes/emilia/qemu-server/2304.conf' does not exist
```

L'agent essaie de piloter `2304` depuis `emilia` alors que la VM est sur `ram`. A corriger dans la resolution du noeud courant / execution distante.

### 24 - Installation doctor

Le doctor signale que sur `192.168.123.100`, `/usr/bin/kvm` pointe vers `/usr/bin/qemu-system-x86_64` et pas vers le wrapper Omega. Il faut redeployer/reparer le wrapper avant un deploiement permanent.

### 25 - Reseau VM invitee

Le test a echoue dans la passe complete apres des tests de migration/balloon. QGA est pourtant OK apres coup via watchdog. A relancer seul apres stabilisation de `2304`.

### 38 - Deploiement .deb

Aucun paquet `.deb` trouve. Construire avec:

```bash
make deb
```

### M1 - RAM + CPU simultanes

Le test a vu QGA indisponible pendant la passe, probablement apres les tests qui ont mis `2304` en etat QMP/migration instable. Le watchdog confirme QGA OK ensuite. A relancer apres correction migration/balloon.

## Etat QGA apres tests

```text
2304: running, QGA_OK, node=ram
2306: running, QGA_OK, node=emilia
2309: running, QGA_OK, node=emilia
```

Le probleme initial "QGA ne revient pas apres reboot" est couvert par `omega-qga-watchdog.timer`.

## Prochaines actions recommandees

1. Corriger les profils CPU de `2306` et `2309`, puis relancer `30`.
2. Reparer le wrapper `/usr/bin/kvm` via deploy/install, puis relancer `24`.
3. Stabiliser `2304` ou choisir une autre VM source pour migration; relancer `08` et `M5` sans pression excessive.
4. Corriger le pilotage balloon/migration pour executer `qm monitor` sur le noeud proprietaire de la VM.
5. Construire le paquet `.deb`, puis relancer `38`.
6. Relancer une passe courte: `30`, `05`, `08`, `22`, `24`, `25`, `38`, `M1`, `M5`.
