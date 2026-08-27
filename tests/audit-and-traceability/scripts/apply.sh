#!/usr/bin/env bash
# req066 — Audit and traceability of calls
# Applies the JSON access-log EnvoyFilter on the RHCL gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 066 — Audit and traceability of calls"
echo "======================================================================"

# --- Prerequisites ---
echo ""
echo "[prereq] Checking RHCL / Kuadrant..."
if oc get kuadrant -n kuadrant-system &>/dev/null; then
  echo "  ✓ Kuadrant installed"
else
  echo "  ✗ Kuadrant NOT found in kuadrant-system."
  exit 1
fi

echo ""
echo "[prereq] Detecting the RHCL gateway..."
GW_DEPLOY=$(oc -n openshift-ingress get deploy -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || echo "")
if [ -n "$GW_DEPLOY" ]; then
  echo "  ✓ Gateway deployment: $GW_DEPLOY"
else
  echo "  ⚠ Gateway deployment not found automatically."
  GW_DEPLOY="rhcl-apps-gateway-openshift-default"
  echo "    Using default: $GW_DEPLOY"
fi

echo ""
echo "[prereq] Checking the tracing stack (req038)..."
if oc -n observability get opentelemetrycollector otel-rhcl &>/dev/null; then
  echo "  ✓ OpenTelemetryCollector otel-rhcl found (full trace correlation)"
else
  echo "  ⚠ Tracing stack (req038) NOT found."
  echo "    Access logs work without it, but trace correlation will be limited."
  echo "    For the full stack: bash tests/opentelemetry-traces-metrics/scripts/apply.sh"
fi

# --- Step 1: Remove the old EnvoyFilter (if it exists with a stale annotation) ---
echo ""
echo "=== Step 1/2: Cleanup of the previous EnvoyFilter ==="
if oc -n openshift-ingress get envoyfilter access-log-json &>/dev/null; then
  echo "  Removing the previous EnvoyFilter for a clean re-apply..."
  oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found
  sleep 2
  echo "  ✓ Previous EnvoyFilter removed"
else
  echo "  (no previous EnvoyFilter found)"
fi

# --- Step 2: Apply the JSON access-log EnvoyFilter ---
echo ""
echo "=== Step 2/2: EnvoyFilter — JSON access log for auditing ==="
oc apply -f "$MANIFESTS/01-envoyfilter-access-log-json.yaml"
echo "  ✓ EnvoyFilter access-log-json applied"

echo ""
echo "  Waiting for Envoy to reload via xDS (5s)..."
sleep 5

# Check whether Envoy accepted the config (no rejection errors)
REJECT_COUNT=$(oc -n openshift-ingress logs "deploy/$GW_DEPLOY" \
  -c istio-proxy --tail=10 --since=10s 2>/dev/null | \
  grep -c "rejected\|Not supported field" 2>/dev/null || echo "0")

if [ "$REJECT_COUNT" -gt 0 ]; then
  echo "  ✗ ERROR: Envoy rejected the config!"
  echo "    Check: oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=10"
  exit 1
else
  echo "  ✓ No rejection errors detected"
fi

echo ""
echo "======================================================================"
echo " APPLY COMPLETE"
echo "======================================================================"
echo ""
echo "What was created:"
echo "  EnvoyFilter:  access-log-json (namespace: openshift-ingress)"
echo "  Role:         JSON access log with audit fields on the gateway stdout"
echo "  New fields: consumer_id, auth_reason, flow_trace_id, traceparent, TLS info"
echo ""
echo "WHERE TO SEE THE EVIDENCE:"
echo "  oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=10"
echo "  (NOT in Observe → Traces — that is the req038 feature)"
echo ""
echo "Next steps:"
echo "  1. Validate:  bash $SCRIPT_DIR/validate.sh"
echo "  2. Generate an authenticated request:"
echo "     curl -sk -H 'x-flow-trace-id: audit-001' -H 'api-key: alice-gold-secret' \\"
echo "       https://banking-api.example.com/api/v1/echo"
echo "  3. View the JSON access log:"
echo "     oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=20 | grep audit-001"
echo ""
