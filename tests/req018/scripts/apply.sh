#!/usr/bin/env bash
# req018/scripts/apply.sh — aplica todo o stack de monitoração de custo
# (Telemetry + ServiceMonitor + ConfigMap de pricing + Grafana dashboard).
#
# Idempotente. Executar quantas vezes quiser — `oc apply` merge.
#
# Uso:
#   ./tests/req018/scripts/apply.sh
#   ./tests/req018/scripts/apply.sh --skip-dashboard  # pula GrafanaDashboard
#
# Pré-requisitos verificados no início (sai com erro se faltar):
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
  echo "WARN: UWM não parece habilitado. bank_ai_tokens_total não vai ser scrapeado." >&2
  echo "      Editar cm/cluster-monitoring-config em openshift-monitoring e setar:" >&2
  echo "        enableUserWorkload: true" >&2
fi
oc get ns rhcl-apps >/dev/null 2>&1 || {
  echo "ERROR: namespace rhcl-apps não existe. Deploy o banking-api antes." >&2
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
    echo "  namespace rhcl-grafana não existe — pulando dashboard." >&2
    echo "  Se o Grafana estiver em outro ns, editar 01-dashboard-api-costs.yaml e reaplicar." >&2
  fi
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " Pronto. Próximos passos:"
echo "   1. Gerar tráfego:  ./tests/simulate-api-traffic.sh --target=banking --forever"
echo "   2. Validar:        ./tests/req018/scripts/validate.sh"
echo "   3. Abrir plugin:   Console → Custom Connectivity Link → Cost"
echo "   4. Abrir dashboard: Grafana → 'RHCL API Costs'"
echo "══════════════════════════════════════════════════════════════════"
