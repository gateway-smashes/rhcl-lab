#!/usr/bin/env bash
# Install the MCP Lifecycle Operator (kubernetes-sigs) when absent.
set -euo pipefail

if oc api-resources 2>/dev/null | grep -q 'mcpservers.*mcp.x-k8s.io'; then
  echo "MCPServer CRD already present."
  exit 0
fi

URL="${MCP_LIFECYCLE_OPERATOR_INSTALL_URL:-https://github.com/kubernetes-sigs/mcp-lifecycle-operator/releases/latest/download/install.yaml}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Installing MCP Lifecycle Operator from ${URL}"
curl -fsSL "$URL" -o "${WORKDIR}/install.yaml"
oc apply -f "${WORKDIR}/install.yaml"

echo "Waiting for MCP Lifecycle Operator deployment..."
for i in $(seq 1 60); do
  if oc api-resources 2>/dev/null | grep -q 'mcpservers.*mcp.x-k8s.io'; then
    echo "MCPServer CRD available."
    break
  fi
  sleep 5
done

oc get deploy -A 2>/dev/null | grep -i mcp-lifecycle || true
