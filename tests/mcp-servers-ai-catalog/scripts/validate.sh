#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${RHCL_MCP_LAB_NAMESPACE:-rhcl-mcp-lab}"
ODS_NS="${OCP_AI_APPLICATIONS_NAMESPACE:-redhat-ods-applications}"

if [[ -z "${RHCL_ZONE_ROOT_DOMAIN:-}" ]]; then
  RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}')"
  export RHCL_ZONE_ROOT_DOMAIN
fi

echo "==> Pods in ${NS}"
oc -n "$NS" get deploy,pod,svc,route 2>/dev/null || true

echo
echo "==> MCP catalog ConfigMap keys (${ODS_NS:-rhoai-model-registries}/mcp-catalog-sources)"
CATALOG_NS="${OCP_AI_CATALOG_NAMESPACE:-rhoai-model-registries}"
if ! oc -n "$CATALOG_NS" get configmap mcp-catalog-sources >/dev/null 2>&1; then
  CATALOG_NS="odh-model-registries"
fi
oc -n "$CATALOG_NS" get configmap mcp-catalog-sources -o jsonpath='{.data}' 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(sorted(d)))" \
  || echo "mcp-catalog-sources not found"

echo
echo "==> gen-ai-aa-mcp-servers"
oc -n "$ODS_NS" get configmap gen-ai-aa-mcp-servers -o yaml 2>/dev/null \
  | grep -E 'RHCL-|url:' || echo "gen-ai-aa-mcp-servers not found"

echo
echo "==> MCP initialize probe (lab-info)"
HOST="https://rhcl-lab-info-mcp.${RHCL_ZONE_ROOT_DOMAIN}"
curl -kfsS -o /dev/null -w "HTTP %{http_code}\n" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"req017-validate","version":"1.0"}}}' \
  "${HOST}/mcp" \
  || echo "curl to ${HOST}/mcp failed (pod/route not ready yet?)"
