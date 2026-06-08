#!/usr/bin/env bash
# create-infra-vms.sh — Crée les VMs d'infrastructure réseau du cluster Omega.
#
# VMs créées :
#   pfSense  (VMID 2290) — routeur/firewall, inter-VLAN, NAT, DNS (Unbound)
#
# pfSense est installé manuellement depuis l'ISO (téléchargement séparé).
# La résolution DNS omega.local est assurée par le resolver Unbound de pfSense.
# Pas de VM DNS séparée — pfSense gère tout nativement.
#
# Usage :
#   scripts/create-infra-vms.sh --pfsense   Crée la VM pfSense
#
# Options communes :
#   --controller HOST   Nœud Proxmox cible. Défaut: OMEGA_CONTROLLER.
#   --ssh-key PATH      Clé SSH privée.
#   --user USER         Utilisateur SSH. Défaut: root.
#   --storage NAME      Storage Proxmox. Défaut: OMEGA_NET_INFRA_STORAGE.
#   --dry-run           Affiche les commandes sans les exécuter.
#   -h, --help          Aide.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/cluster.conf"

fail()  { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true

DO_PFSENSE=false
CONTROLLER="${OMEGA_CONTROLLER:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
BRIDGE_WAN="${OMEGA_NET_BRIDGE_WAN:-mgmt}"
BRIDGE_LAN="${OMEGA_NET_VM_BRIDGE:-vmbr1}"
PFSENSE_VMID="${OMEGA_NET_PFSENSE_VMID:-2290}"
PFSENSE_WAN_IP="${OMEGA_NET_PFSENSE_WAN_IP:-192.168.123.200}"
PFSENSE_WAN_GW="${OMEGA_NET_PFSENSE_WAN_GW:-192.168.123.1}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pfsense)     DO_PFSENSE=true; shift ;;
        --controller)  CONTROLLER="$2"; shift 2 ;;
        --user)        DEPLOY_USER="$2"; shift 2 ;;
        --ssh-key)     SSH_KEY="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

$DO_PFSENSE || fail "Spécifier --pfsense"
[[ -n "$CONTROLLER" ]] || fail "OMEGA_CONTROLLER vide. Configurer cluster.conf ou passer --controller."

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" && -f "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

ssh_ctrl() {
    if $DRY_RUN; then
        echo "  [DRY-RUN] ssh ${DEPLOY_USER}@${CONTROLLER} $*"
        return 0
    fi
    ssh "${SSH_OPTS[@]}" "${DEPLOY_USER}@${CONTROLLER}" "$@"
}

# ── VM pfSense ────────────────────────────────────────────────────────────────
create_pfsense_vm() {
    info "=== Création VM pfSense VMID=${PFSENSE_VMID} ==="

    if ssh_ctrl "qm status $PFSENSE_VMID" >/dev/null 2>&1; then
        warn "VM $PFSENSE_VMID existe déjà — ignorer"
        return 0
    fi

    ssh_ctrl bash <<EOF
set -euo pipefail

# Vérifier que l'ISO pfSense est disponible
PFSENSE_ISO=\$(find /var/lib/vz/template/iso/ -name 'pfSense*.iso' -o -name 'pfsense*.iso' 2>/dev/null | head -1)
if [[ -z "\$PFSENSE_ISO" ]]; then
    echo "ERREUR: ISO pfSense introuvable dans /var/lib/vz/template/iso/"
    echo "Télécharger depuis https://www.pfsense.org/download/ (Community Edition, AMD64, DVD Image)"
    echo "puis copier sur le nœud : scp pfSense-*.iso root@${CONTROLLER}:/var/lib/vz/template/iso/"
    exit 1
fi
echo "ISO pfSense trouvé : \$PFSENSE_ISO"

qm create ${PFSENSE_VMID} \\
    --name pfsense-omega \\
    --ostype other \\
    --machine q35 \\
    --cpu kvm64 \\
    --cores 2 \\
    --memory 2048 \\
    --scsihw virtio-scsi-single \\
    --scsi0 ${STORAGE}:32 \\
    --ide2 "\$PFSENSE_ISO,media=cdrom" \\
    --boot order="ide2;scsi0" \\
    --net0 "virtio,bridge=${BRIDGE_WAN},firewall=0" \\
    --net1 "virtio,bridge=${BRIDGE_LAN},firewall=0" \\
    --serial0 socket \\
    --vga std \\
    --tags "omega,infra,pfsense" \\
    --description "pfSense - routeur/firewall Omega. WAN=vmbr0 LAN=vmbr1. IP WAN: ${PFSENSE_WAN_IP}"
EOF

    ok "VM pfSense ${PFSENSE_VMID} créée"
    echo ""
    info "INSTALLATION MANUELLE REQUISE :"
    echo "  1) Démarrer la VM : qm start ${PFSENSE_VMID}"
    echo "  2) Ouvrir la console Proxmox et installer pfSense"
    echo "  3) Configuration initiale pfSense :"
    echo "       WAN  → vtnet0 (vmbr0)  — IP: ${PFSENSE_WAN_IP}/24, GW: ${PFSENSE_WAN_GW}"
    echo "       LAN  → vtnet1 (vmbr1)  — IP: 10.50.0.1/16 (trunk, pas de tag)"
    echo "  4) Après install, accéder à https://${PFSENSE_WAN_IP} pour l'interface web"
    echo "  5) Créer les interfaces VLAN :"
    echo "       VLAN 10 (Management) → vtnet1.10 → 10.50.10.1/24"
    echo "       VLAN 20 (Infra)      → vtnet1.20 → 10.50.20.1/24"
    echo "       VLAN 30 (Omega)      → vtnet1.30 → 10.50.30.1/24"
    echo "  6) Règles firewall (voir docs/architecture-reseau.md)"
}

$DO_PFSENSE && create_pfsense_vm

echo ""
ok "Infrastructure réseau : terminé"
echo ""
info "Récapitulatif :"
$DO_PFSENSE && echo "  pfSense  VMID=${PFSENSE_VMID}  WAN=${PFSENSE_WAN_IP}  LAN=10.50.0.1/16"
echo ""
info "DNS omega.local : configurer Unbound dans pfSense → Services → DNS Resolver → Host Overrides"
info "Voir docs/architecture-reseau.md pour les règles pfSense."
