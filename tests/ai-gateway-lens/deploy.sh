#!/usr/bin/env bash
# REQ 75 — AI Gateway lens: token governance + in-console chat playground.
#
# Sets up the cluster side of the custom-console "AI Gateway" page:
#   1. the TokenRateLimitPolicy on the OpenAI-compatible route (from req060),
#   2. an `ai-chat` TLS-front proxy so the console plugin can call the chat
#      endpoint through the gateway (auth + token limit apply),
#   3. the ConsolePlugin `ai-chat` proxy alias.
#
# Idempotent. Requires: oc logged in as an admin on the RHCL cluster.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ROUTE_NS="${ROUTE_NS:-rhcl-apps}"
ROUTE_NAME="${ROUTE_NAME:-banking-api-connectivity}"
GATEWAY_SVC="${GATEWAY_SVC:-rhcl-apps-gateway-istio.openshift-ingress.svc.cluster.local}"
CONSOLE_PLUGIN="${CONSOLE_PLUGIN:-custom-rhcl-console}"

# The public hostname the AI route answers on (Host header the TLS front sends).
AI_ROUTE_HOST="${AI_ROUTE_HOST:-$(oc get httproute "$ROUTE_NAME" -n "$ROUTE_NS" -o jsonpath='{.spec.hostnames[0]}')}"
echo "AI route host: $AI_ROUTE_HOST"

echo "== 1/3 TokenRateLimitPolicy (req060) =="
oc apply -f "$HERE/../token-rate-limiting/manifests/30-tokenratelimitpolicy.yaml"

echo "== 2/3 ai-chat TLS front → gateway =="
sed -e "s|AI_ROUTE_HOST_CHANGE_ME|$AI_ROUTE_HOST|g" \
    -e "s|rhcl-apps-gateway-istio.openshift-ingress.svc.cluster.local|$GATEWAY_SVC|g" \
    "$HERE/manifests/10-ai-chat-proxy.yaml" | oc apply -f -
oc rollout status deploy/ai-chat-tls -n "$ROUTE_NS" --timeout=120s

echo "== 3/3 ConsolePlugin ai-chat proxy alias =="
if ! oc get consoleplugin "$CONSOLE_PLUGIN" -o jsonpath='{.spec.proxy[*].alias}' | tr ' ' '\n' | grep -qx ai-chat; then
  oc patch consoleplugin "$CONSOLE_PLUGIN" --type=json -p '[{"op":"add","path":"/spec/proxy/-","value":{"alias":"ai-chat","authorization":"None","endpoint":{"type":"Service","service":{"name":"ai-chat-tls","namespace":"'"$ROUTE_NS"'","port":8443}}}}]'
  oc -n openshift-console rollout restart deployment/console
else
  echo "  ai-chat alias already present."
fi

echo "Done. Open the console → Connectivity Link → AI Gateway."
