#!/usr/bin/env bash
# Build and push RHCL lab MCP server images to Quay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${MCP_QUAY_REPO:-quay.io/rh_ee_tavelino/mcp}"
TAG="${MCP_IMAGE_TAG:-latest}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Builds the three MCP server Containerfiles and pushes to Quay.

Environment:
  MCP_QUAY_REPO   Target repository (default: quay.io/rh_ee_tavelino/mcp)
  MCP_IMAGE_TAG   Tag suffix (default: latest)

Images produced:
  \${MCP_QUAY_REPO}:rhcl-lab-info-mcp-\${MCP_IMAGE_TAG}
  \${MCP_QUAY_REPO}:rhcl-text-tools-mcp-\${MCP_IMAGE_TAG}
  \${MCP_QUAY_REPO}:rhcl-time-tools-mcp-\${MCP_IMAGE_TAG}

Log in first: podman login quay.io
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

build_push() {
  local name="$1"
  local dir="$2"
  local image="${REPO}:rhcl-${name}-mcp-${TAG}"

  echo "Building ${image} from servers/${dir}/"
  podman build -t "${image}" -f "${ROOT}/servers/${dir}/Containerfile" "${ROOT}/servers/${dir}"
  echo "Pushing ${image}"
  podman push "${image}"
}

build_push "lab-info" "lab-info"
build_push "text-tools" "text-tools"
build_push "time-tools" "time-tools"

echo "Done. Apply on cluster: bash ${ROOT}/scripts/apply-prod.sh"
