#!/usr/bin/env bash
# generate-proxy-cert.sh
# Génère un certificat mTLS avec SAN pour un proxy VM GANDAL.
#
# Usage:
#   ./generate-proxy-cert.sh --vm-id omega-9101 --vm-ip 10.50.30.15 \
#                            --ca-dir ~/Documents/Projets4GI/Security\ Monitoring/ca \
#                            --out-dir /tmp/certs-9101
#
# Produit dans --out-dir :
#   proxy.crt   certificat signé avec SAN (CN=<vm-id>, IP:<vm-ip>)
#   proxy.key   clé privée
#   ca.crt      copie du CA (pour injection dans la VM)

set -euo pipefail

fail() { echo "ERREUR: $*" >&2; exit 1; }

VM_ID=""
VM_IP=""
CA_DIR=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-id)  VM_ID="$2";  shift 2 ;;
        --vm-ip)  VM_IP="$2";  shift 2 ;;
        --ca-dir) CA_DIR="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) fail "option inconnue: $1" ;;
    esac
done

[[ -n "$VM_ID" ]]  || fail "--vm-id requis (ex: omega-9101)"
[[ -n "$VM_IP" ]]  || fail "--vm-ip requis (ex: 10.50.30.15)"
[[ -n "$CA_DIR" ]] || fail "--ca-dir requis"
[[ -n "$OUT_DIR" ]] || fail "--out-dir requis"

CA_CRT="${CA_DIR}/ca.crt"
CA_KEY="${CA_DIR}/ca.key"
CA_SRL="${CA_DIR}/ca.srl"

[[ -f "$CA_CRT" ]] || fail "ca.crt introuvable dans $CA_DIR"
[[ -f "$CA_KEY" ]] || fail "ca.key introuvable dans $CA_DIR"
[[ -f "$CA_SRL" ]] || fail "ca.srl introuvable dans $CA_DIR"

command -v openssl >/dev/null 2>&1 || fail "openssl non installé"

mkdir -p "$OUT_DIR"

EXT_FILE="${OUT_DIR}/proxy-san.ext"
KEY_FILE="${OUT_DIR}/proxy.key"
CSR_FILE="${OUT_DIR}/proxy.csr"
CRT_FILE="${OUT_DIR}/proxy.crt"

echo "▶ Génération du certificat pour $VM_ID ($VM_IP)..."

# Fichier de config SAN
cat > "$EXT_FILE" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${VM_ID}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${VM_ID}
IP.1  = ${VM_IP}
EOF

# Clé privée
openssl genrsa -out "$KEY_FILE" 4096 2>/dev/null
echo "  ✅ Clé générée"

# CSR
openssl req -new \
    -key "$KEY_FILE" \
    -config "$EXT_FILE" \
    -out "$CSR_FILE" 2>/dev/null
echo "  ✅ CSR généré"

# Signature avec la CA commune (utilise ca.srl existant)
openssl x509 -req \
    -in "$CSR_FILE" \
    -CA "$CA_CRT" \
    -CAkey "$CA_KEY" \
    -CAserial "$CA_SRL" \
    -out "$CRT_FILE" \
    -days 365 \
    -extensions v3_req \
    -extfile "$EXT_FILE" 2>/dev/null
echo "  ✅ Certificat signé"

# Copie du CA dans out-dir pour injection cloud-init
cp "$CA_CRT" "${OUT_DIR}/ca.crt"

# Vérification SAN
SAN_CHECK=$(openssl x509 -in "$CRT_FILE" -text -noout 2>/dev/null | grep -A2 "Subject Alternative" || true)
if echo "$SAN_CHECK" | grep -q "$VM_IP"; then
    echo "  ✅ SAN vérifié : $SAN_CHECK"
else
    fail "SAN absent du certificat généré — vérifier openssl"
fi

# Nettoyage fichiers temporaires
rm -f "$EXT_FILE" "$CSR_FILE"

echo ""
echo "✅ Certificats prêts dans $OUT_DIR :"
ls -lh "$OUT_DIR"
echo ""
echo "CN  : $VM_ID"
echo "SAN : DNS:${VM_ID}, IP:${VM_IP}"
echo "CA  : $CA_CRT"
