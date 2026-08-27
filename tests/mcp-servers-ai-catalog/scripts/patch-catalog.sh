#!/usr/bin/env bash
# Merge the RHCL lab MCP catalog into OpenShift AI mcp-catalog-sources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG_DIR="${MCP_CATALOG_DIR:-${ROOT}/manifests/catalog}"

detect_catalog_namespace() {
  if [[ -n "${OCP_AI_CATALOG_NAMESPACE:-}" ]]; then
    echo "$OCP_AI_CATALOG_NAMESPACE"
    return
  fi
  for candidate in rhoai-model-registries odh-model-registries redhat-ods-applications; do
    if oc -n "$candidate" get configmap mcp-catalog-sources >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  echo "rhoai-model-registries"
}

NS="$(detect_catalog_namespace)"
CM="${MCP_CATALOG_SOURCES_CONFIGMAP:-mcp-catalog-sources}"

merge_sources() {
  python3 - "$@" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required: pip install pyyaml\n")
    sys.exit(1)

def load(path: Path):
    text = path.read_text()
    if not text.strip():
        return {}
    data = yaml.safe_load(text)
    return data if isinstance(data, dict) else {}

existing_path, incoming_path, out_path = map(Path, sys.argv[1:4])
existing = load(existing_path)
incoming = load(incoming_path)
catalogs = existing.setdefault("mcp_catalogs", [])
by_id = {item.get("id"): item for item in catalogs if isinstance(item, dict)}
for item in incoming.get("mcp_catalogs", []):
    by_id[item["id"]] = item
existing["mcp_catalogs"] = list(by_id.values())
out_path.write_text(yaml.safe_dump(existing, sort_keys=False))
PY
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if ! oc -n "$NS" get configmap "$CM" >/dev/null 2>&1; then
  echo "Creating ${NS}/${CM} with RHCL lab MCP catalog."
  oc -n "$NS" create configmap "$CM" \
    --from-file=sources.yaml="${CATALOG_DIR}/rhcl-sources.yaml" \
    --from-file=rhcl-mcp-servers.yaml="${CATALOG_DIR}/rhcl-mcp-servers.yaml"
  exit 0
fi

echo "Merging RHCL catalog into ${NS}/${CM} (preserving other keys)."

oc -n "$NS" get configmap "$CM" -o json > "${WORKDIR}/cm.json"

python3 - "${WORKDIR}/cm.json" "${WORKDIR}" <<'PY'
import json
import sys
from pathlib import Path

cm = json.loads(Path(sys.argv[1]).read_text())
work = Path(sys.argv[2])
data = cm.get("data") or {}
for key, value in data.items():
    Path(work, key).write_text(value)
PY

if [[ -f "${WORKDIR}/sources.yaml" ]]; then
  merge_sources "${WORKDIR}/sources.yaml" "${CATALOG_DIR}/rhcl-sources.yaml" "${WORKDIR}/sources.yaml"
else
  cp "${CATALOG_DIR}/rhcl-sources.yaml" "${WORKDIR}/sources.yaml"
fi

cp "${CATALOG_DIR}/rhcl-mcp-servers.yaml" "${WORKDIR}/rhcl-mcp-servers.yaml"
rm -f "${WORKDIR}/cm.json"

ARGS=()
for file in "${WORKDIR}/sources.yaml" "${WORKDIR}/rhcl-mcp-servers.yaml"; do
  [[ -f "$file" ]] || continue
  ARGS+=(--from-file="$(basename "$file")=${file}")
done

oc -n "$NS" create configmap "$CM" "${ARGS[@]}" --dry-run=client -o yaml | oc apply -f -

oc -n "$NS" rollout restart deployment/model-catalog 2>/dev/null || true
oc -n "$NS" rollout status deployment/model-catalog --timeout=180s 2>/dev/null || true

echo "Patched ${NS}/${CM} — refresh OpenShift AI → AI hub → MCP catalog (Ctrl+Shift+R)."
