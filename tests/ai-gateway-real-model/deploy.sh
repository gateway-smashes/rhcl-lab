#!/usr/bin/env bash
# REQ 76 — a real model behind the RHCL AI Gateway (MaaS stand-in).
#
# Stands up an OpenAI-compatible model server (Ollama, CPU) and puts the RHCL
# gateway in front of it with API-key auth + a token budget — the same
# governance you'd wrap a production MaaS (vLLM/KServe on GPU) with.
#
# Idempotent. Requires: oc logged in as cluster-admin on the RHCL cluster.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

NS="${NS:-rhcl-apps}"
ROUTE_NAME="${ROUTE_NAME:-banking-api-connectivity}"     # to auto-detect the host
MODEL="${MODEL:-llama3.2:1b}"

AI_ROUTE_HOST="${AI_ROUTE_HOST:-$(oc get httproute "$ROUTE_NAME" -n "$NS" -o jsonpath='{.spec.hostnames[0]}')}"
echo "Host: $AI_ROUTE_HOST   Model: $MODEL"

echo "== 1/4 model server (Ollama) =="
oc apply -f "$HERE/manifests/10-ollama.yaml"
# ollama/ollama runs as root — grant anyuid on this throwaway lab (not for prod).
oc adm policy add-scc-to-user anyuid -z ollama -n "$NS" >/dev/null
oc rollout status deploy/ollama -n "$NS" --timeout=180s

echo "== 2/4 pull the model (first run downloads ~1.3 GB) =="
oc exec deploy/ollama -n "$NS" -- ollama pull "$MODEL"

echo "== 3/4 RHCL front (route + auth + token budget) =="
sed "s|AI_ROUTE_HOST_CHANGE_ME|$AI_ROUTE_HOST|g" "$HERE/manifests/20-route-and-policies.yaml" | oc apply -f -

echo "== 4/4 smoke test (give policies ~30s to enforce) =="
sleep 30
BASE="https://$AI_ROUTE_HOST"
code_no=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/v1/models" || true)
KEY=$(oc get secret banking-api-key-alice -n "$NS" -o jsonpath='{.data.api_key}' | base64 -d)
code_ok=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/v1/models" -H "api-key: $KEY" || true)
echo "  /v1/models  no-key=$code_no (expect 401)   with-key=$code_ok (expect 200)"

echo
echo "Done. Try the real model through the gateway:"
echo "  KEY=\$(oc get secret banking-api-key-alice -n $NS -o jsonpath='{.data.api_key}' | base64 -d)"
echo "  curl -sk https://$AI_ROUTE_HOST/v1/chat/completions -H \"api-key: \$KEY\" \\"
echo "    -H 'content-type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is an API gateway?\"}]}'"
