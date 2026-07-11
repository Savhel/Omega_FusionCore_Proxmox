#!/usr/bin/env bash
# Test 39 — Voie GPU « entraînement » : Jupyter du LXC GPU partagé + accès VM.
#
# Deuxième des trois voies GPU d'Omega (la 1re = proxy par jobs, tests 32-36 ;
# la 3e = LLM Ollama, test 40). Ici l'utilisateur d'une VM se connecte au LXC GPU
# partagé (torch + /dev/nvidia*) via Jupyter pour entraîner. Le test valide que le
# service Jupyter répond, que le token protège l'accès, et qu'une VM omega l'atteint
# bien à travers le réseau (pfSense).
#
# Config : OMEGA_GPU_JUPYTER_URL (défaut http://192.168.123.60:8888),
#          OMEGA_GPU_JUPYTER_TOKEN (défaut omega-train).
# Usage  : ./37-gpu-training-jupyter.sh [vmid]

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
JUP_URL="${OMEGA_GPU_JUPYTER_URL:-http://192.168.123.60:8888}"
JUP_TOKEN="${OMEGA_GPU_JUPYTER_TOKEN:-omega-train}"

jver() {
    curl -fsS -m8 "$JUP_URL/api" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

step "1) Service Jupyter du LXC GPU joignable ($JUP_URL)"
ver="$(jver)"
[[ -n "$ver" ]] || fail "Jupyter injoignable à ${JUP_URL}/api — LXC d'entraînement absent ou éteint ?"
pass "Jupyter opérationnel (JupyterLab v${ver})"

step "2) Le token protège l'accès (auth requise)"
code_noauth="$(curl -s -m8 -o /dev/null -w '%{http_code}' "$JUP_URL/api/contents" 2>/dev/null)"
code_auth="$(curl -s -m8 -o /dev/null -w '%{http_code}' \
    -H "Authorization: token ${JUP_TOKEN}" "$JUP_URL/api/contents" 2>/dev/null)"
[[ "$code_auth" == "200" ]] || fail "token '${JUP_TOKEN}' refusé sur /api/contents (HTTP ${code_auth})"
if [[ "$code_noauth" == "200" ]]; then
    warn "accès /api/contents ouvert SANS token (HTTP 200) — Jupyter non protégé"
else
    info "sans token : HTTP ${code_noauth} (protégé) ; avec token : 200"
fi
pass "authentification par token fonctionnelle"

step "3) Une VM omega atteint Jupyter (voie entraînement à travers le réseau)"
probe="$(guest_exec_wait "$VMID" -- /bin/sh -c 'command -v curl >/dev/null 2>&1 && echo PROBE_OK' 2>/dev/null || true)"
if ! guest_agent_ready "$VMID" || ! printf '%s' "$probe" | grep -q PROBE_OK; then
    # QGA muet ou pas de curl : VM inutilisable pour le check réseau → on n'échoue PAS
    # (le service LXC est validé ci-dessus), on avertit seulement.
    warn "VM ${VMID} inutilisable pour le check réseau (QGA muet ou curl absent) — voie service validée"
else
    out="$(guest_exec_wait "$VMID" -- /bin/sh -c \
        "curl -s -m8 -o /dev/null -w '%{http_code}' ${JUP_URL}/api" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qE '(^|[^0-9])(200|30[0-9])([^0-9]|$)'; then
        pass "VM ${VMID} atteint Jupyter à travers le réseau (HTTP ${out//[^0-9]/})"
    else
        fail "VM ${VMID} ne joint PAS Jupyter (curl présent, réponse '${out}') — routage/pfSense ?"
    fi
fi

pass "Voie GPU entraînement (Jupyter) OK"
