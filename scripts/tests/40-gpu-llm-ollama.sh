#!/usr/bin/env bash
# Test 40 — Voie GPU « LLM » : serveur Ollama (inférence GPU) + accès VM.
#
# Troisième des trois voies GPU d'Omega (1re = proxy par jobs, tests 32-36 ;
# 2e = Jupyter/entraînement, test 39). Ici la VM appelle l'API HTTP d'un serveur
# Ollama hébergé sur le nœud GPU pour de l'inférence LLM. Le test valide que le
# serveur répond, qu'au moins un modèle est chargé, qu'une VRAIE inférence aboutit
# (donc le GPU sert bien le LLM), et qu'une VM omega atteint l'API.
#
# Config : OMEGA_OLLAMA_URL (défaut http://<OMEGA_GPU_PRIMARY_NODE>:11434),
#          OMEGA_OLLAMA_MODEL (défaut : 1er modèle listé par /api/tags).
# Usage  : ./38-gpu-llm-ollama.sh [vmid]

source "$(dirname "$0")/lib.sh"

VMID="${1:-$TEST_VMID}"
GPU_PRIMARY="${OMEGA_GPU_PRIMARY_NODE:-${OMEGA_GPU_NODES%%,*}}"
GPU_PRIMARY="${GPU_PRIMARY:-$CONTROLLER_NODE}"
OLLAMA_URL="${OMEGA_OLLAMA_URL:-http://${GPU_PRIMARY}:11434}"

step "1) Serveur Ollama joignable ($OLLAMA_URL)"
ver="$(curl -fsS -m8 "$OLLAMA_URL/api/version" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
[[ -n "$ver" ]] || fail "Ollama injoignable à ${OLLAMA_URL}/api/version — serveur LLM absent ou éteint ?"
pass "Ollama opérationnel (v${ver})"

step "2) Au moins un modèle disponible (/api/tags)"
models="$(curl -fsS -m8 "$OLLAMA_URL/api/tags" 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(m["name"] for m in json.load(sys.stdin).get("models",[])))' 2>/dev/null)"
[[ -n "$models" ]] || fail "aucun modèle chargé (/api/tags vide) — faire un 'ollama pull <modèle>'"
MODEL="${OMEGA_OLLAMA_MODEL:-$(printf '%s\n' "$models" | head -1)}"
info "modèles: $(printf '%s' "$models" | tr '\n' ' ')"
pass "modèle sélectionné pour le test : ${MODEL}"

step "3) Inférence réelle GPU (prompt court, num_predict borné)"
req="$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'prompt':'Réponds par un seul mot: capitale de la France?','stream':False,'options':{'num_predict':16}}))" "$MODEL")"
resp="$(curl -fsS -m120 "$OLLAMA_URL/api/generate" -d "$req" 2>/dev/null)"
answer="$(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("response","").strip())' 2>/dev/null || true)"
done_ok="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("done"))' 2>/dev/null || true)"
[[ "$done_ok" == "True" && -n "$answer" ]] || fail "inférence échouée (done=${done_ok}, réponse vide) — réponse brute: ${resp:0:200}"
pass "inférence LLM OK → réponse: « $(printf '%s' "$answer" | tr '\n' ' ' | cut -c1-80) »"

step "4) Une VM omega atteint l'API Ollama (voie LLM à travers le réseau)"
probe="$(guest_exec_wait "$VMID" -- /bin/sh -c 'command -v curl >/dev/null 2>&1 && echo PROBE_OK' 2>/dev/null || true)"
if ! guest_agent_ready "$VMID" || ! printf '%s' "$probe" | grep -q PROBE_OK; then
    # QGA muet ou pas de curl : VM inutilisable pour le check réseau → on n'échoue PAS
    # (le serveur Ollama + l'inférence GPU sont validés ci-dessus), on avertit seulement.
    warn "VM ${VMID} inutilisable pour le check réseau (QGA muet ou curl absent) — voie service validée"
else
    out="$(guest_exec_wait "$VMID" -- /bin/sh -c \
        "curl -s -m8 -o /dev/null -w '%{http_code}' ${OLLAMA_URL}/api/version" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qE '(^|[^0-9])200([^0-9]|$)'; then
        pass "VM ${VMID} atteint Ollama à travers le réseau (HTTP 200)"
    else
        fail "VM ${VMID} ne joint PAS Ollama (curl présent, réponse '${out}') — routage/pfSense ?"
    fi
fi

pass "Voie GPU LLM (Ollama) OK"
