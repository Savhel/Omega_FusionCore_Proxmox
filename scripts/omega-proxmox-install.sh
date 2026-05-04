#!/usr/bin/env bash
# omega-proxmox-install.sh — Installation complète d'Omega sur un nœud Proxmox A
#
# Ce script :
#   1. Installe les binaires Rust compilés dans INSTALL_DIR
#   2. Remplace /usr/bin/kvm par un wrapper omega-qemu-launcher (intercept QEMU)
#   3. Installe le hookscript Proxmox dans /var/lib/vz/snippets/
#   4. Installe les services systemd omega-daemon et node-bc-store
#   5. Enregistre le hookscript sur les VMs listées dans OMEGA_VMIDS
#
# Prérequis :
#   - Binaires compilés : make build
#   - Proxmox VE 7+ sur le nœud courant
#   - accès root
#
# Variables d'environnement :
#   OMEGA_STORES     : adresses stores B et C (défaut : 127.0.0.1:9100,127.0.0.1:9101)
#   OMEGA_RUN_DIR    : répertoire d'état runtime   (défaut : /var/lib/omega-qemu)
#   OMEGA_LOG_DIR    : répertoire de logs           (défaut : /var/log/omega)
#   INSTALL_DIR      : répertoire d'installation    (défaut : /usr/local/bin)
#   OMEGA_VMIDS      : VMIDs séparés par virgule pour enregistrer le hookscript
#                      (ex: "100,101,102") — vide = ne touche aucune VM
#   OMEGA_REAL_KVM   : chemin vers kvm réel (défaut : /usr/bin/kvm.real)
#   OMEGA_AGENT_BIN  : chemin vers node-a-agent (défaut : $INSTALL_DIR/node-a-agent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${OMEGA_STORES:=127.0.0.1:9100,127.0.0.1:9101}"
: "${OMEGA_RUN_DIR:=/var/lib/omega-qemu}"
: "${OMEGA_LOG_DIR:=/var/log/omega}"
: "${INSTALL_DIR:=/usr/local/bin}"
: "${OMEGA_REAL_KVM:=/usr/bin/kvm.real}"
: "${OMEGA_VMIDS:=}"
: "${SNIPPETS_DIR:=/var/lib/vz/snippets}"
: "${HOOKSCRIPT_NAME:=omega-hook.pl}"
: "${OMEGA_OBJECT_ID:=ram0}"
: "${OMEGA_START_TIMEOUT:=30}"
: "${OMEGA_STORE_TIMEOUT_MS:=2000}"
: "${BRIDGE_LIB_DIR:=/usr/local/lib}"
: "${BRIDGE_LIB:=${BRIDGE_LIB_DIR}/omega-uffd-bridge.so}"

info()    { echo -e "\033[32m[INFO]\033[0m   $*"; }
warn()    { echo -e "\033[33m[WARN]\033[0m   $*"; }
success() { echo -e "\033[32m[OK]\033[0m     $*"; }
fail()    { echo -e "\033[31m[ERROR]\033[0m  $*" >&2; exit 1; }
step()    { echo; echo -e "\033[34m──── $* ────\033[0m"; }

# ─── Vérifications ────────────────────────────────────────────────────────────

[[ "$(id -u)" == "0" ]] || fail "Ce script doit être exécuté en root"

LAUNCHER_SRC="${ROOT_DIR}/target/release/omega-qemu-launcher"
AGENT_SRC="${ROOT_DIR}/target/release/node-a-agent"
DAEMON_SRC="${ROOT_DIR}/target/release/omega-daemon"
BRIDGE_SRC="${ROOT_DIR}/omega-uffd-bridge/omega-uffd-bridge.so"

[[ -x "$LAUNCHER_SRC" ]] || fail "omega-qemu-launcher non compilé — lancez 'make build' d'abord"
[[ -x "$AGENT_SRC"    ]] || fail "node-a-agent non compilé — lancez 'make build' d'abord"

# ─── 1. Installer les binaires ────────────────────────────────────────────────

step "Installation des binaires dans ${INSTALL_DIR}"

install -m 755 "$LAUNCHER_SRC" "${INSTALL_DIR}/omega-qemu-launcher"
install -m 755 "$AGENT_SRC"    "${INSTALL_DIR}/node-a-agent"
[[ -x "$DAEMON_SRC" ]] && install -m 755 "$DAEMON_SRC" "${INSTALL_DIR}/omega-daemon" || true

# Bridge LD_PRELOAD (optionnel — absence = pas d'interception uffd QEMU)
if [[ -f "$BRIDGE_SRC" ]]; then
    mkdir -p "$BRIDGE_LIB_DIR"
    install -m 644 "$BRIDGE_SRC" "$BRIDGE_LIB"
    ldconfig "$BRIDGE_LIB_DIR" 2>/dev/null || true
    success "Bridge LD_PRELOAD installé : ${BRIDGE_LIB}"
else
    warn "omega-uffd-bridge.so non trouvé (${BRIDGE_SRC}) — compilez avec 'make build-bridge'"
fi

success "Binaires installés"

# ─── 2. Wrapper QEMU (intercept /usr/bin/kvm) ─────────────────────────────────

step "Installation du wrapper QEMU omega"

WRAPPER_PATH="${INSTALL_DIR}/kvm-omega"
OMEGA_AGENT_BIN="${OMEGA_AGENT_BIN:-${INSTALL_DIR}/node-a-agent}"

# Sauvegarder le kvm réel si ce n'est pas déjà fait
if [[ -e "/usr/bin/kvm" && ! -e "$OMEGA_REAL_KVM" ]]; then
    mv /usr/bin/kvm "$OMEGA_REAL_KVM"
    info "kvm réel sauvegardé dans ${OMEGA_REAL_KVM}"
elif [[ -L "/usr/bin/kvm" ]]; then
    # Déjà un symlink (peut-être vers notre wrapper) — ne rien toucher
    warn "/usr/bin/kvm est déjà un symlink — vérifier manuellement si besoin"
fi

# Générer le wrapper shell via omega-qemu-launcher write-proxmox-wrapper
BRIDGE_ARG=()
if [[ -f "$BRIDGE_LIB" ]]; then
    BRIDGE_ARG=(--bridge-lib "$BRIDGE_LIB")
fi

"${INSTALL_DIR}/omega-qemu-launcher" write-proxmox-wrapper \
    --stores         "$OMEGA_STORES" \
    --qemu-bin       "$OMEGA_REAL_KVM" \
    --agent-bin      "$OMEGA_AGENT_BIN" \
    --run-dir        "$OMEGA_RUN_DIR" \
    --object-id      "$OMEGA_OBJECT_ID" \
    --start-timeout-secs "$OMEGA_START_TIMEOUT" \
    --store-timeout-ms   "$OMEGA_STORE_TIMEOUT_MS" \
    "${BRIDGE_ARG[@]}" \
    --output         "$WRAPPER_PATH"

success "Wrapper écrit dans ${WRAPPER_PATH}"

# Créer le symlink /usr/bin/kvm → wrapper
if [[ -e "$OMEGA_REAL_KVM" && ! -L "/usr/bin/kvm" ]]; then
    ln -sf "$WRAPPER_PATH" /usr/bin/kvm
    success "Symlink /usr/bin/kvm → ${WRAPPER_PATH} créé"
elif [[ -L "/usr/bin/kvm" ]]; then
    ln -sf "$WRAPPER_PATH" /usr/bin/kvm
    success "Symlink /usr/bin/kvm mis à jour → ${WRAPPER_PATH}"
fi

# ─── 3. Hookscript Proxmox ────────────────────────────────────────────────────

step "Installation du hookscript Proxmox"

mkdir -p "$SNIPPETS_DIR"
HOOKSCRIPT_DEST="${SNIPPETS_DIR}/${HOOKSCRIPT_NAME}"

# Copier le hookscript en injectant les valeurs de configuration
sed \
    -e "s|/usr/local/bin/omega-qemu-launcher|${INSTALL_DIR}/omega-qemu-launcher|g" \
    -e "s|/var/lib/omega-qemu|${OMEGA_RUN_DIR}|g" \
    -e "s|127.0.0.1:9100,127.0.0.1:9101|${OMEGA_STORES}|g" \
    "${SCRIPT_DIR}/proxmox_hook.pl" > "$HOOKSCRIPT_DEST"
chmod +x "$HOOKSCRIPT_DEST"

success "Hookscript installé dans ${HOOKSCRIPT_DEST}"

# ─── 4. Service systemd omega-daemon ─────────────────────────────────────────

step "Installation du service systemd omega-daemon"

mkdir -p "$OMEGA_LOG_DIR" "$OMEGA_RUN_DIR"

cat > /etc/systemd/system/omega-daemon.service <<EOF
[Unit]
Description=Omega Remote Paging Daemon
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/omega-daemon
Restart=always
RestartSec=5
Environment=RUST_LOG=info
RuntimeDirectory=omega
LogsDirectory=omega
StateDirectory=omega

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable omega-daemon.service
success "Service omega-daemon installé (démarrage manuel : systemctl start omega-daemon)"

# ─── 5. Enregistrement hookscript sur les VMs ─────────────────────────────────

if [[ -n "$OMEGA_VMIDS" ]]; then
    step "Enregistrement du hookscript sur les VMs : ${OMEGA_VMIDS}"

    IFS=',' read -ra VMID_LIST <<< "$OMEGA_VMIDS"
    for vmid in "${VMID_LIST[@]}"; do
        vmid="${vmid// /}"
        if qm config "$vmid" &>/dev/null; then
            qm set "$vmid" --hookscript "local:snippets/${HOOKSCRIPT_NAME}"
            success "hookscript enregistré sur VM ${vmid}"
        else
            warn "VM ${vmid} introuvable sur ce nœud — hookscript non enregistré"
        fi
    done
fi

# ─── Résumé ───────────────────────────────────────────────────────────────────

echo
echo -e "\033[32m╔══════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[32m║          Omega Proxmox RAM — Installation terminée           ║\033[0m"
echo -e "\033[32m╚══════════════════════════════════════════════════════════════╝\033[0m"
echo
echo "  Binaires          : ${INSTALL_DIR}/omega-qemu-launcher"
echo "                      ${INSTALL_DIR}/node-a-agent"
echo "  Wrapper QEMU      : ${WRAPPER_PATH}"
echo "  kvm réel          : ${OMEGA_REAL_KVM}"
echo "  Hookscript        : ${HOOKSCRIPT_DEST}"
echo "  Service           : systemctl start omega-daemon"
echo "  Stores B/C        : ${OMEGA_STORES}"
echo "  Répertoire état   : ${OMEGA_RUN_DIR}"
echo
echo "  Pour enregistrer le hookscript sur une VM :"
echo "    qm set <vmid> --hookscript local:snippets/${HOOKSCRIPT_NAME}"
echo
echo "  Pour vérifier le wrapper :"
echo "    ls -la /usr/bin/kvm"
echo "    ${INSTALL_DIR}/omega-qemu-launcher status --vm-id <vmid>"
echo
