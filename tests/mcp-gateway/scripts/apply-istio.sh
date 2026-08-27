#!/usr/bin/env bash
# Apply req059 MCP Gateway manifests for clusters with GatewayClass `istio` only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MF="${ROOT}/tests/mcp-gateway/manifests"

export RHCL_ZONE_ROOT_DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
: "${RHCL_ZONE_ROOT_DOMAIN:?set RHCL_ZONE_ROOT_DOMAIN or log in with oc}"

export MCP_GATEWAY_CLASS="${MCP_GATEWAY_CLASS:-istio}"
export MCP_GATEWAY_SERVICE_TYPE="${MCP_GATEWAY_SERVICE_TYPE:-ClusterIP}"
export MCP_GATEWAY_SERVICE_NAME="${MCP_GATEWAY_SERVICE_NAME:-rhcl-mcp-gateway-istio}"

if ! oc get gatewayclass "${MCP_GATEWAY_CLASS}" >/dev/null 2>&1; then
  echo "GatewayClass ${MCP_GATEWAY_CLASS} not found. Available:"
  oc get gatewayclass
  exit 1
fi

echo "RHCL_ZONE_ROOT_DOMAIN=${RHCL_ZONE_ROOT_DOMAIN}"
echo "MCP_GATEWAY_CLASS=${MCP_GATEWAY_CLASS}"
echo "MCP_GATEWAY_SERVICE_NAME=${MCP_GATEWAY_SERVICE_NAME}"
echo "MCP_GATEWAY_SERVICE_TYPE=${MCP_GATEWAY_SERVICE_TYPE}"

oc apply -f "${MF}/10-mcp-gateway-namespace.yaml"

# Replace Gateway when switching from openshift-default → istio.
if oc get gateway rhcl-mcp-gateway -n mcp-gateway >/dev/null 2>&1; then
  CURRENT_CLASS="$(oc get gateway rhcl-mcp-gateway -n mcp-gateway -o jsonpath='{.spec.gatewayClassName}')"
  if [[ "${CURRENT_CLASS}" != "${MCP_GATEWAY_CLASS}" ]]; then
    echo "Replacing Gateway (was ${CURRENT_CLASS}, want ${MCP_GATEWAY_CLASS})..."
    oc delete gateway rhcl-mcp-gateway -n mcp-gateway --wait=true --timeout=180s || true
    oc delete svc -n mcp-gateway -l gateway.networking.k8s.io/gateway-name=rhcl-mcp-gateway --ignore-not-found
    oc delete deploy -n mcp-gateway -l gateway.networking.k8s.io/gateway-name=rhcl-mcp-gateway --ignore-not-found
  fi
fi

envsubst < "${MF}/30-rhcl-mcp-gateway-istio.yaml" | oc apply -f -
oc wait --for=condition=Programmed -n mcp-gateway gateway/rhcl-mcp-gateway --timeout=300s

# Compat Service only for openshift-default (name collides with istio controller Service).
if [[ "${MCP_GATEWAY_CLASS}" == "openshift-default" ]]; then
  oc apply -f "${MF}/30-gateway-istio-compat-service.yaml"
fi

oc apply -f "${MF}/21-referencegrant-mcp-httproute-to-backend.yaml"

envsubst < "${MF}/40-mcpgatewayextension.yaml" | oc apply -f -
envsubst < "${MF}/41-mcpserver-httproute.yaml" | oc apply -f -
envsubst < "${MF}/43-mcpserverregistration.yaml" | oc apply -f -
envsubst < "${MF}/44-mcp-custom-httproute.yaml" | oc apply -f -
envsubst < "${MF}/46-mcp-browser-route-istio.yaml" | oc apply -f -
oc apply -f "${MF}/47-mcp-cors-envoyfilter.yaml"

# AuthPolicies break POST /mcp when Kuadrant wasm + MCP ext_proc are both active (PoC workaround).
if [[ "${MCP_GATEWAY_AUTH_POLICIES_ENABLED:-false}" == "true" ]]; then
  oc apply -f "${MF}/31-mcp-gateway-deny-all-authpolicy.yaml"
  oc apply -f "${MF}/42-mcpserver-authpolicy.yaml"
  oc apply -f "${MF}/45-mcp-custom-httproute-authpolicy.yaml"
else
  echo "Skipping AuthPolicies (set MCP_GATEWAY_AUTH_POLICIES_ENABLED=true to apply)."
fi

oc wait --for=condition=Ready mcpgatewayextension/mcp-gateway -n mcp-gateway --timeout=300s || true
oc wait --for=condition=Ready mcpserverregistration/banking-api -n mcp-gateway --timeout=300s || true

echo "---"
oc get gateway,deploy,svc,endpoints,route -n mcp-gateway
GW_POD="$(oc get pods -n mcp-gateway -l gateway.networking.k8s.io/gateway-name=rhcl-mcp-gateway -o name 2>/dev/null | head -1)"
echo "Gateway pod: ${GW_POD:-<none — check deploy labels>}"
