#!/usr/bin/env bash
# Build the three RHCL lab MCP images in-cluster (binary Docker builds).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${RHCL_MCP_LAB_NAMESPACE:-rhcl-mcp-lab}"

SERVERS=(lab-info text-tools time-tools)
BCS=(rhcl-lab-info-mcp rhcl-text-tools-mcp rhcl-time-tools-mcp)

oc get ns "$NS" >/dev/null 2>&1 || {
  echo "Namespace ${NS} not found. Run scripts/apply.sh first (without --skip-build)." >&2
  exit 1
}

for i in "${!SERVERS[@]}"; do
  server="${SERVERS[$i]}"
  bc="${BCS[$i]}"
  echo "==> Building ${bc} from servers/${server}"
  oc -n "$NS" start-build "$bc" \
    --from-dir="${ROOT}/servers/${server}" \
    --follow
done

echo "Images ready in namespace ${NS}."
