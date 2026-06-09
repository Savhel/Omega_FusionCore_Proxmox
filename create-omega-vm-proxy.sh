#!/usr/bin/env bash
# DÉPRÉCIÉ — conservé pour compatibilité. La version canonique (corrigée :
# IP par VMID anti-collision + install proxy GANDAL non-bloquante au boot) vit
# désormais dans scripts/. Ce fichier ne fait que la rappeler.
#   → scripts/create-omega-vm-proxy.sh
# Voir aussi scripts/generate-proxy-cert.sh (génération mTLS).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HERE}/scripts/create-omega-vm-proxy.sh" "$@"
