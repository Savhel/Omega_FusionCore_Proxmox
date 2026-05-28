#!/usr/bin/env bash
# Test 38 — Déploiement par paquet Debian (.deb)
#
# Valide que :
#   1. Le .deb se construit (dpkg-deb présent)
#   2. Sur chaque nœud cible : dpkg -l omega-remote-paging retourne ii
#   3. Les binaires sont présents dans /opt/omega-remote-paging/bin
#   4. omega-node-install est dans le PATH (/usr/sbin)
#   5. /etc/omega/cluster.env et le token GPU proxy ont été créés par postinst
#   6. omega-daemon.service est actif
#   7. apt remove laisse la conf en place mais coupe les services (test optionnel)
#
# Usage :
#   bash scripts/tests/38-deb-install.sh

set -euo pipefail
source "$(dirname "$0")/lib.sh"

header "Test 38 — Déploiement .deb"

require_cluster

# ─── Étape 1 : vérifier que le .deb est buildable ─────────────────────────────

step "Vérification dpkg-deb local"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb introuvable sur la machine de build"
pass "dpkg-deb présent"

# Trouver le .deb le plus récent (on suppose qu'il a été construit avant le test)
DEB_PATH="${OMEGA_DEB_PATH:-}"
if [[ -z "$DEB_PATH" ]]; then
    DEB_PATH="$(ls -t "${REPO_ROOT}"/target/deb/omega-remote-paging_*_amd64.deb 2>/dev/null | head -1 || true)"
fi
[[ -n "$DEB_PATH" && -f "$DEB_PATH" ]] \
    || fail "Aucun .deb trouvé (construire avec : make deb)"
pass ".deb trouvé : $(basename "$DEB_PATH") ($(du -h "$DEB_PATH" | cut -f1))"

# ─── Étape 2 : vérifier le contenu du .deb ───────────────────────────────────

step "Validation contenu .deb"
expected_files=(
    "./opt/omega-remote-paging/bin/omega-daemon"
    "./opt/omega-remote-paging/bin/node-a-agent"
    "./opt/omega-remote-paging/bin/node-bc-store"
    "./opt/omega-remote-paging/bin/omega-qemu-launcher"
    "./opt/omega-remote-paging/scripts/omega-proxmox-install.sh"
    "./usr/sbin/omega-node-install"
)
listing="$(dpkg-deb -c "$DEB_PATH")"
for f in "${expected_files[@]}"; do
    grep -qF " $f" <<<"$listing" \
        || fail ".deb : fichier manquant $f"
done
pass ".deb contient les ${#expected_files[@]} fichiers attendus"

# Vérif des hooks postinst/prerm/postrm
for hook in postinst prerm postrm; do
    dpkg-deb -I "$DEB_PATH" | grep -q "$hook" \
        || fail ".deb : hook $hook manquant"
done
pass ".deb contient les hooks postinst/prerm/postrm"

# ─── Étape 3 : vérifier l'installation sur chaque nœud ───────────────────────

for node in "${OMEGA_NODES_ARR[@]}"; do
    step "Nœud $node — dpkg status"

    status=$(ssh_run "$node" "dpkg-query -W -f='\${Status}' omega-remote-paging 2>/dev/null || true")
    [[ "$status" == "install ok installed" ]] \
        || fail "$node : omega-remote-paging non installé (status='$status'). Lancer 'make deploy-deb' d'abord."
    pass "$node : paquet installé (status=ok)"

    version=$(ssh_run "$node" "dpkg-query -W -f='\${Version}' omega-remote-paging 2>/dev/null")
    pass "$node : version installée = $version"

    step "Nœud $node — fichiers du paquet"
    for f in /opt/omega-remote-paging/bin/omega-daemon \
             /opt/omega-remote-paging/bin/node-a-agent \
             /opt/omega-remote-paging/bin/node-bc-store \
             /opt/omega-remote-paging/bin/omega-qemu-launcher \
             /usr/sbin/omega-node-install
    do
        ssh_run "$node" "test -x '$f'" \
            || fail "$node : $f introuvable ou non exécutable"
    done
    pass "$node : binaires + installer présents"

    step "Nœud $node — postinst (cluster.env + token GPU)"
    ssh_run "$node" "test -f /etc/omega/cluster.env" \
        || fail "$node : /etc/omega/cluster.env manquant (postinst non exécuté ?)"
    ssh_run "$node" "test -s /etc/omega/gpu-proxy.token" \
        || fail "$node : /etc/omega/gpu-proxy.token vide ou manquant"
    token_perms=$(ssh_run "$node" "stat -c '%a' /etc/omega/gpu-proxy.token")
    [[ "$token_perms" == "600" ]] \
        || fail "$node : token GPU proxy a des perms $token_perms (attendu 600)"
    pass "$node : cluster.env + token GPU OK (perms 600)"

    step "Nœud $node — service omega-daemon"
    active=$(ssh_run "$node" "systemctl is-active omega-daemon 2>/dev/null || true")
    [[ "$active" == "active" ]] \
        || fail "$node : omega-daemon non actif (status=$active)"
    pass "$node : omega-daemon actif"

    step "Nœud $node — invocation directe des binaires"
    ssh_run "$node" "/opt/omega-remote-paging/bin/omega-daemon --help >/dev/null" \
        || fail "$node : omega-daemon --help échoue"
    ssh_run "$node" "/opt/omega-remote-paging/bin/node-a-agent --help >/dev/null" \
        || fail "$node : node-a-agent --help échoue"
    pass "$node : binaires lancent --help sans crash"
done

# ─── Étape 4 : test de rétrocompatibilité — réinstaller le même .deb ─────────

if [[ "${OMEGA_TEST_REINSTALL:-0}" == "1" ]]; then
    step "Test idempotence : réinstaller le .deb sur le contrôleur"
    DEB_NAME="$(basename "$DEB_PATH")"
    ssh_run "$CONTROLLER_NODE" "true" # warm-up connection
    # On envoie et réinstalle
    scp -o StrictHostKeyChecking=accept-new "$DEB_PATH" \
        "root@${CONTROLLER_NODE}:/tmp/${DEB_NAME}" >/dev/null
    ssh_run "$CONTROLLER_NODE" "apt-get install -y --reinstall /tmp/${DEB_NAME} 2>&1 | tail -3"
    active=$(ssh_run "$CONTROLLER_NODE" "systemctl is-active omega-daemon 2>/dev/null || true")
    [[ "$active" == "active" ]] \
        || fail "$CONTROLLER_NODE : omega-daemon non actif après réinstallation"
    pass "Réinstallation idempotente OK sur $CONTROLLER_NODE"
fi

pass "Déploiement .deb validé sur ${#OMEGA_NODES_ARR[@]} nœud(s)"
