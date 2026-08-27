#!/usr/bin/env bash
# api-cost-monitoring/scripts/apply.sh — applies the whole cost-monitoring stack
# (Telemetry + ServiceMonitor + ConfigMap de pricing + Grafana dashboard).
#
# Idempotente. Executar quantas vezes quiser — `oc apply` merge.
#
# Uso:
#   ./tests/api-cost-monitoring/scripts/apply.sh
#   ./tests/api-cost-monitoring/scripts/apply.sh --skip-dashboard  # pula GrafanaDashboard
#
# Prerequisites checked up front (exits with an error if missing):
#   - `oc` logado
#   - UWM habilitado
#   - namespace rhcl-apps existe
set -euo pipefail

SKIP_DASHBOARD=false
[ "${1:-}" = "--skip-dashboard" ] && SKIP_DASHBOARD=true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$HERE/../manifests"

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

echo "── Pre-flight ────────────────────────────────────────────────────"
if ! oc -n openshift-monitoring get cm cluster-monitoring-config -o yaml 2>/dev/null \
     | grep -q 'enableUserWorkload: true'; then
  echo "WARN: UWM does not seem enabled. bank_ai_tokens_total will not be scraped." >&2
  echo "      Editar cm/cluster-monitoring-config em openshift-monitoring e setar:" >&2
  echo "        enableUserWorkload: true" >&2
fi
oc get ns rhcl-apps >/dev/null 2>&1 || {
  echo "ERROR: namespace rhcl-apps does not exist. Deploy banking-api first." >&2
  exit 1
}

echo "── 1. Telemetry CR (labels custom em istio_requests_total) ──────"
oc apply -f "$MANIFESTS/03-telemetry-consumer-labels.yaml"

echo "── 2. ServiceMonitor (UWM → banking-api /q/metrics) ─────────────"
oc apply -f "$MANIFESTS/02-servicemonitor-banking-api.yaml"

echo "── 3. Pricing table (ConfigMap com costCurrency + costPricing) ──"
# server-side apply pra mergear com os outros campos que a role
# custom_console pode ter escrito nessa ConfigMap.
oc apply --server-side --force-conflicts -f "$MANIFESTS/04-plugin-config-pricing.yaml"

if $SKIP_DASHBOARD; then
  echo "── 4. Grafana dashboard: SKIPPED (--skip-dashboard) ─────────────"
else
  echo "── 4. Grafana dashboard ────────────────────────────────────────"
  if oc get ns rhcl-grafana >/dev/null 2>&1; then
    oc -n rhcl-grafana create configmap rhcl-api-costs-json \
      --from-file=dashboard.json="$MANIFESTS/dashboard-api-costs.json" \
      --dry-run=client -o yaml | oc apply -f -
    oc apply -f "$MANIFESTS/01-dashboard-api-costs.yaml"
  else
    echo "  namespace rhcl-grafana does not exist — skipping dashboard." >&2
    echo "  Se o Grafana estiver em outro ns, editar 01-dashboard-api-costs.yaml e reaplicar." >&2
  fi
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " Done. Next steps:"
echo "   1. Generate traffic:  ./tests/simulate-api-traffic.sh --target=banking --forever"
echo "   2. Validar:        ./tests/api-cost-monitoring/scripts/validate.sh"
echo "   3. Abrir plugin:   Console → Custom Connectivity Link → Cost"
echo "   4. Abrir dashboard: Grafana → 'RHCL API Costs'"
echo "══════════════════════════════════════════════════════════════════"
