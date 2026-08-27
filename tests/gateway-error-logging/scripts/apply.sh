#!/usr/bin/env bash
# Logging of every errored request at the gateway.
# Aplica os manifests na ordem correta e aguarda o data plane absorver
# o EnvoyFilter antes de declarar sucesso.
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
  echo "  ✗ OTel Collector otel-rhcl/observability NÃO encontrado."
  echo "    Rode antes: bash tests/opentelemetry-traces-metrics/scripts/apply.sh"
  exit 1
fi
echo "  ✓ OTel Collector otel-rhcl presente"

if ! oc get gateway -A | grep -q rhcl-apps-gateway; then
  echo "  ✗ Gateway rhcl-apps-gateway NÃO encontrado."
  echo "    Rode antes: ansible-playbook automation/playbooks/apps-install.yml"
  exit 1
fi
echo "  ✓ Gateway rhcl-apps-gateway presente"

# --- Passo 1: patch do Collector (pipeline logs + file exporter) ---
echo ""
echo "[1/3] Patch no OpenTelemetryCollector — adiciona pipeline logs"
oc apply -f "$MANIFESTS/02-otel-collector-logs-pipeline.yaml"
echo "  → aguardando rollout..."
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=180s

# --- Passo 2: EnvoyFilter de access log no gateway ---
echo ""
echo "[2/3] EnvoyFilter — Envoy OTel ALS no rhcl-apps-gateway"
oc apply -f "$MANIFESTS/01-envoyfilter-otel-access-logs.yaml"

# --- Passo 3: reload dos gateway pods pra absorver o EnvoyFilter ---
echo ""
echo "[3/3] Reload do gateway data plane (xDS push)"
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s
echo "  → dando 20s para Envoy carregar a nova config..."
sleep 20

echo ""
echo "======================================================================"
echo " ✓ Apply OK."
echo "======================================================================"
echo ""
echo "Next steps:"
echo "  • Validate with error traffic: bash $SCRIPT_DIR/validate.sh"
echo "  • Acompanhar o stream ao vivo:"
echo "      COL=\$(oc get pods -n observability -l app.kubernetes.io/name=otel-rhcl-collector -o jsonpath='{.items[0].metadata.name}')"
echo "      oc exec -n observability \"\$COL\" -- tail -F /var/log/rhcl-errors.json"
echo ""
