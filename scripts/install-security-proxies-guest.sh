#!/usr/bin/env bash
# install-security-proxies-guest.sh — s'exécute À L'INTÉRIEUR de la VM.
#
# Installe les proxys de sécurité GANDAL (chiffreur + analyseur) de l'équipe SMA :
#   - récupère debs/certs/wheel depuis le deb-server (emilia:8000),
#   - pose les certs mTLS dans /opt/gandal/certs (chiffreur) et /etc/gandal-proxy/pki (analyseur),
#   - installe grpcio HORS-LIGNE (déballage du wheel, pas de pip/internet),
#   - configure (VM_ID, hôtes centraux ; token Proxmox conservé tel quel),
#   - active les services (Restart=always, démarrage auto au boot).
# Idempotent : ré-exécutable sans casse.
#
# Variables (passées par l'appelant via l'environnement) :
#   DEB_SERVER       (défaut http://192.168.123.100:8000)
#   VM_ID            (obligatoire — VMID Proxmox)
#   ANALYSEUR_HOST   (défaut 192.168.123.110)
#   ANALYSEUR_PORT   (défaut 5002)
#   CHIFFREUR_URL    (défaut http://192.168.123.100:5014)
set -u
DEB_SERVER="${DEB_SERVER:-http://192.168.123.100:8000}"
ANALYSEUR_HOST="${ANALYSEUR_HOST:-192.168.123.100}"
ANALYSEUR_PORT="${ANALYSEUR_PORT:-5002}"
CHIFFREUR_URL="${CHIFFREUR_URL:-https://192.168.123.100:5014}"
VM_ID="${VM_ID:-$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '[:space:]')}"
log() { echo "[sec-proxy] $*"; }
VM_IP="$(ip -4 -o addr show 2>/dev/null | awk '/ (10|192)\.(50|168)\./{print $4}' | cut -d/ -f1 | grep -v '^127' | head -1)"

cd /tmp || exit 1

# 1. Téléchargement du bundle (LAN, pas internet)
#    Certs SMA : proxy-chiffreur.{crt,key} (CN=proxy-chiffreur, exigé par l'agent central
#    chiffreur en mTLS) pour le chiffreur ; proxy.{crt,key} (CN=proxy) pour l'analyseur.
log "Téléchargement depuis ${DEB_SERVER}"
for f in proxy-chiffreur.deb proxy-analyseur.deb ca.crt proxy.crt proxy.key proxy-chiffreur.crt proxy-chiffreur.key; do
  curl -fsS -o "sp_$f" "${DEB_SERVER}/$f" || { log "ERREUR fetch $f"; exit 10; }
done

# 2. Certificats mTLS — /opt/gandal/certs (chiffreur, à plat) + /etc/gandal-proxy/pki (analyseur, sous-dossiers)
log "Pose des certificats"
mkdir -p /opt/gandal/certs/ca /opt/gandal/certs/proxy /etc/gandal-proxy/pki/ca /etc/gandal-proxy/pki/proxy
install -m644 sp_ca.crt    /opt/gandal/certs/ca.crt
install -m644 sp_proxy.crt /opt/gandal/certs/proxy.crt
install -m640 sp_proxy.key /opt/gandal/certs/proxy.key
# Cert SMA du chiffreur (CN=proxy-chiffreur) pour l'annonce mTLS au central
install -m644 sp_proxy-chiffreur.crt /opt/gandal/certs/proxy-chiffreur.crt
install -m640 sp_proxy-chiffreur.key /opt/gandal/certs/proxy-chiffreur.key
cp sp_ca.crt /opt/gandal/certs/ca/ca.crt; cp sp_proxy.crt /opt/gandal/certs/proxy/proxy.crt; install -m640 sp_proxy.key /opt/gandal/certs/proxy/proxy.key
cp sp_ca.crt /etc/gandal-proxy/pki/ca/ca.crt; cp sp_proxy.crt /etc/gandal-proxy/pki/proxy/proxy.crt; install -m640 sp_proxy.key /etc/gandal-proxy/pki/proxy/proxy.key

# 3. Dépendances Python hors-ligne (grpcio + protobuf + typing_extensions) :
#    fermeture complète servie en tarball, déballée via python3 -m zipfile.
#    (pip3 ET unzip sont absents sur Debian minimal → on n'utilise QUE python3.)
if ! python3 -c 'import grpc, google.protobuf' 2>/dev/null; then
  log "Installation des dépendances Python hors-ligne"
  if curl -fsS -o sp_py-deps.tgz "${DEB_SERVER}/py-deps.tgz" 2>/dev/null; then
    mkdir -p /tmp/sp_wh && tar xzf sp_py-deps.tgz -C /tmp/sp_wh 2>/dev/null
    for w in /tmp/sp_wh/*.whl; do python3 -m zipfile -e "$w" /usr/lib/python3/dist-packages/ 2>/dev/null; done
  fi
fi
python3 -c 'import grpc, google.protobuf' 2>/dev/null && log "deps Python OK" || log "WARN deps Python incomplètes (analyseur dégradé)"

# 4. Installation des paquets (grpc déjà présent → postinst analyseur n'appelle pas pip)
log "dpkg proxy-chiffreur"; dpkg -i sp_proxy-chiffreur.deb >/dev/null 2>&1 || log "WARN dpkg chiffreur"
log "dpkg proxy-analyseur"; dpkg -i sp_proxy-analyseur.deb >/dev/null 2>&1 || { dpkg --configure -a >/dev/null 2>&1; }
# Filet : si l'utilisateur système 'security' manque (postinst interrompu), le créer
id -u security >/dev/null 2>&1 || useradd --system --no-create-home --shell /bin/false security

# 5. Permissions des certs par service (chiffreur=proxy-chiffreur, analyseur=security)
chmod 755 /opt /opt/gandal 2>/dev/null
chown -R root:proxy-chiffreur /opt/gandal/certs 2>/dev/null; chmod -R 750 /opt/gandal/certs 2>/dev/null
# clés lisibles par le groupe proxy-chiffreur (restent en 640)
chmod 640 /opt/gandal/certs/proxy-chiffreur.key /opt/gandal/certs/proxy.key 2>/dev/null
chown -R root:security /etc/gandal-proxy/pki 2>/dev/null; chmod -R 750 /etc/gandal-proxy/pki 2>/dev/null

# 6. Config chiffreur (JSON lu via PROXY_CONFIG=/etc/proxy-chiffreur/proxy_config.json) — certs via env, sans token (mTLS)
mkdir -p /etc/proxy-chiffreur
cat > /etc/proxy-chiffreur/proxy_config.json <<JSON
{ "local_vm_id": ${VM_ID:-0}, "listen_port": 8400, "agent_central_url": "${CHIFFREUR_URL}", "agent_token": "", "chemin_session": "data/session.json", "chemin_cle_privee": "data/proxy_vm_secret.json", "local_deliver_url": "http://127.0.0.1:8080/deliver", "old_key_grace_sec": 60, "peers": {} }
JSON
chown root:proxy-chiffreur /etc/proxy-chiffreur/proxy_config.json 2>/dev/null; chmod 640 /etc/proxy-chiffreur/proxy_config.json 2>/dev/null
cat > /etc/default/proxy-chiffreur <<ENV
RUST_LOG=info
TLS_CA=/opt/gandal/certs/ca.crt
TLS_CERT=/opt/gandal/certs/proxy-chiffreur.crt
TLS_KEY=/opt/gandal/certs/proxy-chiffreur.key
PROXY_PUBLIC_IP=${VM_IP}
ENV

# 7. Config analyseur (proxy.env : VM_ID + ANALYSEUR_HOST ; PKI_DIR & token Proxmox conservés)
[ -f /etc/gandal-proxy/proxy.env ] || { [ -f /etc/gandal-proxy/proxy.env.dpkg-new ] && cp /etc/gandal-proxy/proxy.env.dpkg-new /etc/gandal-proxy/proxy.env; }
if [ -f /etc/gandal-proxy/proxy.env ]; then
  sed -i "s|^VM_ID=.*|VM_ID=${VM_ID}|; s|^ANALYSEUR_HOST=.*|ANALYSEUR_HOST=${ANALYSEUR_HOST}|; s|^ANALYSEUR_PORT=.*|ANALYSEUR_PORT=${ANALYSEUR_PORT}|" /etc/gandal-proxy/proxy.env
  chown root:security /etc/gandal-proxy/proxy.env 2>/dev/null; chmod 640 /etc/gandal-proxy/proxy.env 2>/dev/null
fi

# 8. Démarrage auto + Restart=always (chiffreur)
mkdir -p /etc/systemd/system/proxy-chiffreur.service.d
printf '[Service]\nRestart=always\n' > /etc/systemd/system/proxy-chiffreur.service.d/restart.conf
systemctl daemon-reload
systemctl enable proxy-chiffreur gandal-proxy >/dev/null 2>&1
# restart (pas seulement --now) : si déjà actif, recharge la nouvelle config/certs
systemctl restart proxy-chiffreur gandal-proxy >/dev/null 2>&1
sleep 3
log "RESULTAT : chiffreur=$(systemctl is-active proxy-chiffreur)/$(systemctl is-enabled proxy-chiffreur 2>/dev/null) analyseur=$(systemctl is-active gandal-proxy)/$(systemctl is-enabled gandal-proxy 2>/dev/null)"
