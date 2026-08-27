#!/usr/bin/env bash
# Logging of every errored request at the gateway.
# Applies the manifests in the correct order and waits for the data plane to
# absorb the EnvoyFilter before declaring success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 035 — Gateway error logging via OpenTelemetry"
echo "======================================================================"

# --- Prerequisites ---
echo ""
echo "[prereq] Checking the observability stack (req038)..."
if ! oc get opentelemetrycollector -n observability otel-rhcl &>/dev/null; then
  echo "  ✗ OTel Collector otel-rhcl/observability NOT found."
  echo "    Run first: bash tests/opentelemetry-traces-metrics/scripts/apply.sh"
  exit 1
fi
echo "  ✓ OTel Collector otel-rhcl present"

if ! oc get gateway -A | grep -q rhcl-apps-gateway; then
  echo "  ✗ Gateway rhcl-apps-gateway NOT found."
  echo "    Run first: ansible-playbook automation/playbooks/apps-install.yml"
  exit 1
fi
echo "  ✓ Gateway rhcl-apps-gateway present"

# --- Step 1: patch the Collector (logs pipeline + file exporter) ---
echo ""
echo "[1/3] Patch the OpenTelemetryCollector — adds the logs pipeline"
oc apply -f "$MANIFESTS/02-otel-collector-logs-pipeline.yaml"
echo "  → waiting for the rollout..."
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=180s

# --- Step 2: access-log EnvoyFilter on the gateway ---
echo ""
echo "[2/3] EnvoyFilter — Envoy OTel ALS on rhcl-apps-gateway"
oc apply -f "$MANIFESTS/01-envoyfilter-otel-access-logs.yaml"

# --- Step 3: reload the gateway pods to absorb the EnvoyFilter ---
echo ""
echo "[3/3] Reload the gateway data plane (xDS push)"
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s
echo "  → giving Envoy 20s to load the new config..."
sleep 20

echo ""
echo "======================================================================"
echo " ✓ Apply OK."
echo "======================================================================"
echo ""
echo "Next steps:"
echo "  • Validate with error traffic: bash $SCRIPT_DIR/validate.sh"
echo "  • Follow the live stream:"
echo "      COL=\$(oc get pods -n observability -l app.kubernetes.io/name=otel-rhcl-collector -o jsonpath='{.items[0].metadata.name}')"
echo "      oc exec -n observability \"\$COL\" -- tail -F /var/log/rhcl-errors.json"
echo ""
