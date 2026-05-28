#!/usr/bin/env bash
# prepare-omega-image.sh — Prépare N'IMPORTE QUELLE image disque (qcow2/raw) pour Omega,
# de façon robuste et indépendante de cloud-init.
#
# À exécuter sur la MACHINE DE DEV (qui a accès Internet), PAS sur le cluster.
# Le résultat est une image "<nom>-omega-prepared.qcow2" garantissant :
#   - qemu-guest-agent installé ET démarré à chaque boot (service de secours auto)
#   - openssh-server + root login par mot de passe
#   - stress-ng (pour les tests de charge Omega)
#   - machine-id réinitialisé (clones uniques, pas de collision DHCP/SSH)
#
# Pourquoi offline (virt-customize) plutôt que cloud-init :
#   - Marche même si l'image n'a pas cloud-init (install manuelle depuis ISO)
#   - Marche même si le cluster n'a pas Internet (l'install se fait ici)
#   - Multi-distro : virt-customize --install détecte apt/dnf/yum/zypper/pacman
#   - Le service de secours "omega-qga-ensure" force QGA à CHAQUE boot, ce qui
#     élimine les courses udev/réseau qui rendaient QGA "parfois actif".
#
# Usage :
#   scripts/prepare-omega-image.sh --image /chemin/vers/debian_copy.qcow2 [options]
#
# Options :
#   --image PATH         Image source (qcow2 ou raw). REQUIS.
#   --output PATH        Image préparée en sortie. Défaut: <image>-omega-prepared.qcow2
#   --root-password PASS Mot de passe root. Défaut: root
#   --in-place           Modifie l'image source directement (pas de copie). DANGER.
#   --no-stress-ng       N'installe pas stress-ng (si repo indisponible).
#   --extra-packages CSV Paquets supplémentaires à installer (séparés par virgule).
#   -h, --help           Aide.
#
# Exemple :
#   scripts/prepare-omega-image.sh --image debian_copy.qcow2 --root-password root
#   # → produit debian_copy-omega-prepared.qcow2 prêt à pousser sur le cluster

set -euo pipefail

fail() { echo -e "\033[31m[ERREUR]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m  $*"; }

select_supermin_kernel() {
    local require_readable="$1"
    local kernel
    while IFS= read -r kernel; do
        [[ -d "/lib/modules/${kernel}" && -e "/boot/vmlinuz-${kernel}" ]] || continue
        if [[ "$require_readable" == "false" || -r "/boot/vmlinuz-${kernel}" ]]; then
            printf '%s\n' "$kernel"
            return 0
        fi
    done < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -Vr)
    return 1
}

configure_supermin_kernel() {
    # libguestfs/supermin construit une appliance avec les modules du noyau hote.
    # Sur certains hotes, le noyau courant n'a pas ses modules, ou /boot/vmlinuz-*
    # est lisible seulement par root. Dans ce cas on force un couple noyau/modules
    # explicite et on copie seulement le noyau via sudo dans un chemin lisible.
    [[ -n "${SUPERMIN_KERNEL:-}" || -n "${SUPERMIN_MODULES:-}" ]] && return 0

    local current_kernel
    current_kernel="$(uname -r)"

    if [[ -d "/lib/modules/${current_kernel}" && -r "/boot/vmlinuz-${current_kernel}" ]]; then
        return 0
    fi

    local fallback_kernel=""
    fallback_kernel="$(select_supermin_kernel true || true)"
    if [[ -n "$fallback_kernel" ]]; then
        export SUPERMIN_KERNEL="/boot/vmlinuz-${fallback_kernel}"
        export SUPERMIN_MODULES="/lib/modules/${fallback_kernel}"
        warn "Fallback supermin: SUPERMIN_KERNEL=${SUPERMIN_KERNEL}"
        warn "Fallback supermin: SUPERMIN_MODULES=${SUPERMIN_MODULES}"
        return 0
    fi

    fallback_kernel="$(select_supermin_kernel false || true)"
    if [[ -n "$fallback_kernel" && -x "$(command -v sudo 2>/dev/null || true)" ]]; then
        local readable_kernel="/var/tmp/omega-supermin-vmlinuz-${fallback_kernel}"
        warn "Noyaux /boot/vmlinuz-* non lisibles par l'utilisateur courant."
        warn "Copie lisible via sudo: /boot/vmlinuz-${fallback_kernel} -> ${readable_kernel}"
        if sudo install -m 0644 "/boot/vmlinuz-${fallback_kernel}" "$readable_kernel"; then
            export SUPERMIN_KERNEL="$readable_kernel"
            export SUPERMIN_MODULES="/lib/modules/${fallback_kernel}"
            warn "Fallback supermin: SUPERMIN_KERNEL=${SUPERMIN_KERNEL}"
            warn "Fallback supermin: SUPERMIN_MODULES=${SUPERMIN_MODULES}"
            return 0
        fi
    fi

    warn "Aucun noyau utilisable trouve pour supermin dans /lib/modules + /boot."
    warn "Corrige l'hote avec: sudo apt install linux-modules-extra-\$(uname -r)"
    warn "Si /boot/vmlinuz-* existe mais est non lisible: sudo install -m 0644 /boot/vmlinuz-<version> /var/tmp/omega-supermin-vmlinuz-<version>"
}

run_virt_customize() {
    virt-customize "$@"
}

virt_customize_configure() {
    local err_log
    err_log="$(mktemp)"
    if run_virt_customize "$@" 2>"$err_log"; then
        rm -f "$err_log"
        return 0
    fi

    cat "$err_log" >&2
    if grep -q "supermin exited with\|cannot open '/boot/vmlinuz" "$err_log"; then
        warn "libguestfs/supermin echoue avant la modification de l'image."
        warn "Causes probables: modules du noyau hote manquants, ou /boot/vmlinuz-* non lisible."
        warn "Solutions hote: sudo apt install linux-modules-extra-\$(uname -r)"
        warn "Ou copie un noyau lisible: sudo install -m 0644 /boot/vmlinuz-<version> /var/tmp/omega-supermin-vmlinuz-<version>"
        warn "Ou relance avec SUPERMIN_KERNEL=/boot/vmlinuz-<version> et SUPERMIN_MODULES=/lib/modules/<version>."
    fi
    rm -f "$err_log"
    return 1
}

IMAGE=""
OUTPUT=""
ROOT_PASSWORD="root"
IN_PLACE=false
WITH_STRESS=true
EXTRA_PACKAGES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
        --in-place) IN_PLACE=true; shift ;;
        --no-stress-ng) WITH_STRESS=false; shift ;;
        --extra-packages) EXTRA_PACKAGES="$2"; shift 2 ;;
        -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$IMAGE" ]] || fail "--image requis"
[[ -f "$IMAGE" ]] || fail "image introuvable: $IMAGE"

# ─── virt-customize disponible ? ──────────────────────────────────────────────
if ! command -v virt-customize >/dev/null 2>&1; then
    warn "virt-customize absent — tentative d'installation de libguestfs-tools"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y libguestfs-tools \
            || fail "impossible d'installer libguestfs-tools (essayer: sudo apt install libguestfs-tools)"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y libguestfs-tools \
            || fail "impossible d'installer libguestfs-tools"
    else
        fail "installer libguestfs-tools manuellement (paquet fournissant virt-customize)"
    fi
fi

# ─── Préparer l'image de sortie ───────────────────────────────────────────────
if $IN_PLACE; then
    TARGET="$IMAGE"
    warn "Mode --in-place : modification directe de $IMAGE"
else
    if [[ -z "$OUTPUT" ]]; then
        base="${IMAGE%.*}"
        OUTPUT="${base}-omega-prepared.qcow2"
    fi
    info "Copie ${IMAGE} → ${OUTPUT}"
    rm -f "$OUTPUT"

    # Si l'image est deja qcow2, eviter qemu-img convert: sur certaines images il
    # peut re-materialiser des blocs et grossir au point de saturer le disque.
    IMAGE_FORMAT=""
    if command -v qemu-img >/dev/null 2>&1; then
        IMAGE_FORMAT="$(qemu-img info --output=json "$IMAGE" 2>/dev/null | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi

    if [[ "$IMAGE_FORMAT" == "qcow2" ]]; then
        cp --reflink=auto --sparse=always "$IMAGE" "$OUTPUT" 2>/dev/null \
            || cp --sparse=always "$IMAGE" "$OUTPUT"
    elif command -v qemu-img >/dev/null 2>&1; then
        qemu-img convert -O qcow2 "$IMAGE" "$OUTPUT"
    else
        cp --reflink=auto --sparse=always "$IMAGE" "$OUTPUT" 2>/dev/null \
            || cp --sparse=always "$IMAGE" "$OUTPUT"
    fi

    [[ -s "$OUTPUT" ]] || fail "copie image echouee: sortie absente ou vide: $OUTPUT"
    TARGET="$OUTPUT"
fi

# ─── Script de secours QGA (multi-distro, idempotent, exécuté à chaque boot) ──
QGA_ENSURE_SCRIPT="$(cat <<'ENSURE'
#!/bin/sh
# omega-qga-ensure — garantit qemu-guest-agent actif. Multi-distro, idempotent.
# Exécuté à chaque boot : élimine les courses udev/réseau.
LOG=/var/log/omega-qga-ensure.log
{
echo "=== omega-qga-ensure $(date) ==="

install_qga() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update 2>/dev/null && apt-get install -y qemu-guest-agent 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y qemu-guest-agent 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y qemu-guest-agent 2>/dev/null
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install qemu-guest-agent 2>/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm qemu-guest-agent 2>/dev/null
    fi
}

# 1. Installer si binaire absent (nécessite réseau ; sinon no-op silencieux)
if ! command -v qemu-ga >/dev/null 2>&1; then
    echo "qemu-ga absent — tentative d'installation"
    install_qga || echo "install échouée (pas de réseau/repo ?) — on continue"
fi

# 2. Lever les masques éventuels (certaines images masquent le service)
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true

# 3. Activer service ET socket (Ubuntu = socket/udev-activated)
systemctl enable qemu-guest-agent.service 2>/dev/null || true
systemctl enable qemu-guest-agent.socket  2>/dev/null || true

# 4. Attendre le device virtio-serial puis démarrer (retry contre la course de boot)
i=0
while [ "$i" -lt 10 ]; do
    if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
        systemctl restart qemu-guest-agent.service 2>/dev/null \
            || systemctl start qemu-guest-agent.service 2>/dev/null || true
        systemctl start qemu-guest-agent.socket 2>/dev/null || true
        break
    fi
    i=$((i+1))
    sleep 2
done

systemctl is-active qemu-guest-agent 2>/dev/null && echo "qemu-guest-agent ACTIF" || echo "qemu-guest-agent INACTIF"
} >>"$LOG" 2>&1
ENSURE
)"

QGA_ENSURE_UNIT="$(cat <<'UNIT'
[Unit]
Description=Omega - garantit qemu-guest-agent actif a chaque boot
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/omega-qga-ensure
RemainAfterExit=no
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT
)"

SSHD_DROPIN="PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes"

# ─── Construire les arguments virt-customize ─────────────────────────────────
PACKAGES="qemu-guest-agent,openssh-server"
$WITH_STRESS && PACKAGES="${PACKAGES},stress-ng"
[[ -n "$EXTRA_PACKAGES" ]] && PACKAGES="${PACKAGES},${EXTRA_PACKAGES}"

info "Préparation de l'image (virt-customize)…"
info "  Paquets       : ${PACKAGES}"
info "  Root password : ${ROOT_PASSWORD}"
info "  Cible         : ${TARGET}"

# libguestfs : éviter les soucis de noyau/appliance sur certains hôtes
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
configure_supermin_kernel

# --install peut échouer si le repo de l'image est inaccessible depuis la dev.
# Dans ce cas le service de secours omega-qga-ensure prendra le relais au boot.
if ! run_virt_customize -a "$TARGET" --install "$PACKAGES"; then
    warn "virt-customize --install a échoué (repo image inaccessible ?)."
    warn "Le service de secours omega-qga-ensure tentera l'install au premier boot."
    warn "Pour une garantie hors-ligne totale, prépare l'image sur une machine"
    warn "ayant les mêmes repos que l'image, ou ajoute un miroir local."
fi

# Pose des fichiers + activation, indépendamment du succès de --install.
TMP_SCRIPT="$(mktemp)"; printf '%s\n' "$QGA_ENSURE_SCRIPT" > "$TMP_SCRIPT"
TMP_UNIT="$(mktemp)";   printf '%s\n' "$QGA_ENSURE_UNIT"   > "$TMP_UNIT"
TMP_SSHD="$(mktemp)";   printf '%s\n' "$SSHD_DROPIN"       > "$TMP_SSHD"
trap 'rm -f "$TMP_SCRIPT" "$TMP_UNIT" "$TMP_SSHD"' EXIT

virt_customize_configure -a "$TARGET" \
    --root-password "password:${ROOT_PASSWORD}" \
    --mkdir /usr/local/sbin \
    --upload "${TMP_SCRIPT}:/usr/local/sbin/omega-qga-ensure" \
    --chmod "0755:/usr/local/sbin/omega-qga-ensure" \
    --upload "${TMP_UNIT}:/etc/systemd/system/omega-qga-ensure.service" \
    --mkdir /etc/ssh/sshd_config.d \
    --upload "${TMP_SSHD}:/etc/ssh/sshd_config.d/99-omega-root-login.conf" \
    --run-command "systemctl enable qemu-guest-agent.service 2>/dev/null || true" \
    --run-command "systemctl enable qemu-guest-agent.socket 2>/dev/null || true" \
    --run-command "systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true" \
    --run-command "systemctl enable omega-qga-ensure.service 2>/dev/null || true" \
    --run-command "cloud-init clean --logs 2>/dev/null || true" \
    --run-command "rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* 2>/dev/null || true" \
    --run-command "rm -f /var/lib/dbus/machine-id" \
    --run-command "truncate -s 0 /etc/machine-id" \
    || fail "virt-customize (configuration) a échoué"

info "Image préparée : ${TARGET}"
echo
echo "  Étapes suivantes :"
echo "    1) Pointer cluster.conf vers cette image :"
echo "         OMEGA_VM_IMAGE_LOCAL=\"$(realpath "$TARGET")\""
echo "         OMEGA_VM_IMAGE_PREPARED=\"1\"   # déjà préparée, pas de virt-customize côté cluster"
echo "    2) Lancer le provisioning :"
echo "         bash scripts/omega-lab.sh   # action [p]"
echo
echo "  Vérifier QGA dans une VM après boot :"
echo "    ssh root@<ip-vm> 'systemctl is-active qemu-guest-agent; cat /var/log/omega-qga-ensure.log'"
