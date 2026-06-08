# Omega QGA watchdog

Objectif: corriger automatiquement les VMs Omega dont `qemu-guest-agent` ne revient pas apres reboot.

Le watchdog tourne sur chaque noeud Proxmox compute via `omega-qga-watchdog.timer`. A chaque passage, il scanne les VMs locales taguees `omega`, verifie le canal QGA Proxmox, active `agent enabled=1` si necessaire, puis repare l invite via SSH quand une IP est visible.

Installation depuis la machine de dev:

```bash
bash scripts/install-qga-watchdog-remote.sh \
  --nodes 192.168.123.100,192.168.123.101,192.168.123.102 \
  --root-password root \
  --interval 60
```

Par defaut, le watchdog ne reset pas une VM bloquee sans IP. Pour autoriser le reset automatique apres 3 echecs consecutifs:

```bash
bash scripts/install-qga-watchdog-remote.sh \
  --nodes 192.168.123.100,192.168.123.101,192.168.123.102 \
  --root-password root \
  --reset-stuck 1 \
  --interval 60
```

Commandes utiles sur un noeud Proxmox:

```bash
systemctl status omega-qga-watchdog.timer
systemctl start omega-qga-watchdog.service
tail -f /var/log/omega/qga-watchdog.log
```

Limite importante: si une VM est bloquee avant reseau et sans QGA, aucun agent externe ne peut installer un paquet dans l invite. Dans ce cas, le watchdog journalise l etat. Avec `--reset-stuck 1`, il tente un reset Proxmox apres plusieurs echecs.
