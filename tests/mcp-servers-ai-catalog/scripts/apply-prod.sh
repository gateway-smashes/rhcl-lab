#!/usr/bin/env bash
# Apply req 017 — RHCL MCP servers from Quay (production manifests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MF="${ROOT}/manifests/prod"
NS="${RHCL_MCP_LAB_NAMESPACE:-rhcl-mcp-lab}"
SKIP_CATALOG=false
SKIP_MCPSERVER=false
SKIP_PLAYGROUND=false
SKIP_LIFECYCLE=false

export MCP_QUAY_REPO="${MCP_QUAY_REPO:-quay.io/rh_ee_tavelino/mcp}"
export MCP_IMAGE_TAG="${MCP_IMAGE_TAG:-latest}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Applies manifests from ${MF}/ using pre-built Quay images (no in-cluster build).

Environment:
  MCP_QUAY_REPO   Image repository (default: quay.io/rh_ee_tavelino/mcp)
  MCP_IMAGE_TAG   Tag suffix (default: latest → rhcl-*-mcp-latest)

Options:
  --skip-catalog      Skip mcp-catalog-sources patch
  --skip-mcpserver    Skip MCPServer CRs (when lifecycle operator absent)
  --skip-playground   Skip gen-ai-aa-mcp-servers ConfigMap
  --skip-lifecycle    Skip MCP Lifecycle Operator install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
echo "Using MCP_QUAY_REPO=${MCP_QUAY_REPO} MCP_IMAGE_TAG=${MCP_IMAGE_TAG}"

if [[ "$SKIP_LIFECYCLE" == false ]]; then
  bash "${ROOT}/scripts/install-mcp-lifecycle-operator.sh"
fi

oc apply -f "${MF}/00-namespace.yaml"

if [[ -f "${MF}/01-image-pull-secret.yaml" ]]; then
  oc apply -f "${MF}/01-image-pull-secret.yaml"
fi

envsubst < "${MF}/20-deployments.yaml" | oc apply -f -

if [[ -f "${MF}/01-image-pull-secret.yaml" ]]; then
  for deploy in rhcl-lab-info-mcp rhcl-text-tools-mcp rhcl-time-tools-mcp; do
    oc -n "$NS" patch deployment "$deploy" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"quay-mcp-pull"}]}
    ]' 2>/dev/null || \
    oc -n "$NS" patch deployment "$deploy" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"quay-mcp-pull"}]}
    ]' 2>/dev/null || true
  done
fi

oc apply -f "${MF}/21-services.yaml"
envsubst < "${MF}/30-routes.yaml" | oc apply -f -

if [[ "$SKIP_MCPSERVER" == false ]]; then
  if oc api-resources 2>/dev/null | grep -q 'mcpservers.*mcp.x-k8s.io'; then
    envsubst < "${MF}/40-mcpservers.yaml" | oc apply -f -
  else
    echo "MCPServer CRD not found — skipping 40-mcpservers.yaml (use Deployments only)."
  fi
fi

if [[ "$SKIP_CATALOG" == false ]]; then
  CATALOG_WORK="$(mktemp -d)"
  trap 'rm -rf "$CATALOG_WORK"' EXIT
  envsubst < "${MF}/catalog/rhcl-mcp-servers.yaml" > "${CATALOG_WORK}/rhcl-mcp-servers.yaml"
  cp "${MF}/catalog/rhcl-sources.yaml" "${CATALOG_WORK}/rhcl-sources.yaml"
  MCP_CATALOG_DIR="${CATALOG_WORK}" bash "${ROOT}/scripts/patch-catalog.sh"
  trap - EXIT
  rm -rf "$CATALOG_WORK"
fi

if [[ "$SKIP_PLAYGROUND" == false ]]; then
  oc apply -f "${MF}/60-gen-ai-aa-mcp-servers.yaml"
fi

echo "Done. Validate with: bash ${ROOT}/scripts/validate.sh"
