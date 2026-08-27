#!/usr/bin/env bash
# Apply req 017 — RHCL lab MCP servers + OpenShift AI catalog registration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MF="${ROOT}/manifests"
NS="${RHCL_MCP_LAB_NAMESPACE:-rhcl-mcp-lab}"
SKIP_BUILD=false
SKIP_CATALOG=false
SKIP_MCPSERVER=false
SKIP_PLAYGROUND=false
SKIP_LIFECYCLE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --skip-build        Do not run binary image builds
  --skip-catalog      Skip mcp-catalog-sources patch
  --skip-mcpserver    Skip MCPServer CRs (when lifecycle operator absent)
  --skip-playground   Skip gen-ai-aa-mcp-servers ConfigMap
  --skip-lifecycle    Skip MCP Lifecycle Operator install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true ;;
    --skip-catalog) SKIP_CATALOG=true ;;
    --skip-mcpserver) SKIP_MCPSERVER=true ;;
    --skip-playground) SKIP_PLAYGROUND=true ;;
    --skip-lifecycle) SKIP_LIFECYCLE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ -z "${RHCL_ZONE_ROOT_DOMAIN:-}" ]]; then
  RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}')"
  export RHCL_ZONE_ROOT_DOMAIN
fi

echo "Using RHCL_ZONE_ROOT_DOMAIN=${RHCL_ZONE_ROOT_DOMAIN}"

if [[ "$SKIP_LIFECYCLE" == false ]]; then
  bash "${ROOT}/scripts/install-mcp-lifecycle-operator.sh"
fi

oc apply -f "${MF}/00-namespace.yaml"
oc apply -f "${MF}/10-imagestreams.yaml"
oc apply -f "${MF}/11-buildconfigs.yaml"

if [[ "$SKIP_BUILD" == false ]]; then
  bash "${ROOT}/scripts/build-images.sh"
fi

oc apply -f "${MF}/20-deployments.yaml"
oc apply -f "${MF}/21-services.yaml"
envsubst < "${MF}/30-routes.yaml" | oc apply -f -

if [[ "$SKIP_MCPSERVER" == false ]]; then
  if oc api-resources 2>/dev/null | grep -q 'mcpservers.*mcp.x-k8s.io'; then
    oc apply -f "${MF}/40-mcpservers.yaml"
  else
    echo "MCPServer CRD not found — skipping 40-mcpservers.yaml (use Deployments only)."
  fi
fi

if [[ "$SKIP_CATALOG" == false ]]; then
  bash "${ROOT}/scripts/patch-catalog.sh"
fi

if [[ "$SKIP_PLAYGROUND" == false ]]; then
  oc apply -f "${MF}/60-gen-ai-aa-mcp-servers.yaml"
fi

echo "Done. Validate with: bash ${ROOT}/scripts/validate.sh"
