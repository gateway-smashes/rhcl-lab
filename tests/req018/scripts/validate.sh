#!/usr/bin/env bash
# req018/scripts/validate.sh — verifica cada pilar do stack de custo.
#
# 5 checks. Cada um imprime PASS/FAIL/WARN e um one-liner explicativo.
# Sai com 0 se todos passarem, 1 se algum FAIL.
#
# Uso:
#   ./tests/req018/scripts/validate.sh
#   ./tests/req018/scripts/validate.sh --verbose  # log dos comandos
set -uo pipefail

VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

FAIL_COUNT=0
pass() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn() { printf '  \033[33m!\033[0m  %s\n' "$1"; }
info() { printf '     \033[2m%s\033[0m\n' "$1"; }

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

echo "══════════════════════════════════════════════════════════════════"
echo " req018 — Validação de Monitoração de Custo"
echo "══════════════════════════════════════════════════════════════════"

# ─── 1. banking-api emite bank_ai_tokens_total ──────────────────────────
echo ""
echo "1. Backend emitindo counter bank_ai_tokens_total"
POD=$(oc -n rhcl-apps get pods -l app=banking-api-v1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$POD" ]; then
  fail "nenhum pod banking-api-v1 em rhcl-apps"
else
  # port-forward temporário
  oc -n rhcl-apps port-forward "$POD" 18080:8080 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  SERIES=$(curl -s --max-time 5 http://localhost:18080/q/metrics 2>/dev/null | grep -c '^bank_ai_tokens_total' || echo "0")
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true

  if [ "$SERIES" -gt 0 ]; then
    pass "counter presente ($SERIES séries em /q/metrics)"
  else
    fail "counter ausente — chamou algum endpoint /api/v1/chat/completions ou /embeddings?"
    info "Testar: curl -X POST https://<gateway>/api/v1/chat/completions -H 'content-type: application/json' -d '{\"model\":\"banking-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  fi
fi

# ─── 2. ServiceMonitor existe ───────────────────────────────────────────
echo ""
echo "2. ServiceMonitor pro UWM raspar banking-api"
if oc -n rhcl-apps get servicemonitor banking-api >/dev/null 2>&1; then
  pass "servicemonitor/banking-api aplicado"
else
  fail "servicemonitor/banking-api NÃO existe — aplicar manifests/02-servicemonitor-banking-api.yaml"
fi

# ─── 3. Telemetry CR aplicada ───────────────────────────────────────────
echo ""
echo "3. Telemetry CR com labels custom"
if oc -n openshift-ingress get telemetry rhcl-api-metrics >/dev/null 2>&1; then
  # Confirma que tem targetRefs (a gotcha)
  if oc -n openshift-ingress get telemetry rhcl-api-metrics -o jsonpath='{.spec.targetRefs}' | grep -q Gateway; then
    pass "telemetry/rhcl-api-metrics com spec.targetRefs → Gateway"
  else
    fail "telemetry/rhcl-api-metrics existe mas SEM spec.targetRefs — labels não vão popular"
    info "Sem targetRefs a CR só aplica em sidecars — gateways da Gateway API ficam de fora."
  fi
else
  fail "telemetry/rhcl-api-metrics NÃO existe — aplicar manifests/03-telemetry-consumer-labels.yaml"
fi

# ─── 4. Prometheus vê bank_ai_tokens_total ──────────────────────────────
echo ""
echo "4. Thanos/UWM tem a série bank_ai_tokens_total"
THANOS=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$THANOS" ]; then
  warn "route thanos-querier não encontrada — pulando check (cluster provavelmente sem monitoring exposto)"
else
  COUNT=$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
    "https://$THANOS/api/v1/query?query=bank_ai_tokens_total" 2>/dev/null \
    | grep -oE '"result":\[[^]]*\]' | grep -oc '"metric"' || echo "0")
  if [ "$COUNT" -gt 0 ]; then
    pass "Thanos retorna $COUNT séries de bank_ai_tokens_total"
  else
    fail "Thanos não tem a série — checar logs do UWM: oc -n openshift-user-workload-monitoring logs prometheus-user-workload-0 | grep banking-api"
  fi
fi

# ─── 5. istio_requests_total com consumer_id ────────────────────────────
echo ""
echo "5. istio_requests_total tem label request_headers_x_consumer_id populado"
if [ -n "$THANOS" ]; then
  Q='istio_requests_total{request_headers_x_consumer_id!="",request_headers_x_consumer_id!="<nil>"}'
  Q_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$Q" 2>/dev/null || echo "$Q")
  COUNT=$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
    "https://$THANOS/api/v1/query?query=$Q_ENC" 2>/dev/null \
    | grep -oE '"result":\[[^]]*\]' | grep -oc '"metric"' || echo "0")
  if [ "$COUNT" -gt 0 ]; then
    pass "$COUNT séries com consumer_id populado — Telemetry CR está pegando"
  else
    fail "nenhuma série com consumer_id — gerar tráfego com api-key: ./tests/simulate-api-traffic.sh --target=banking --duration=60"
  fi
else
  warn "sem Thanos exposto — pular"
fi

# ─── 6. ConfigMap de pricing configurada ────────────────────────────────
echo ""
echo "6. Plugin ConfigMap com costPricing + costCurrency"
if oc -n custom-rhcl-console get cm custom-rhcl-console-config >/dev/null 2>&1; then
  HAS_PRICING=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costPricing}' 2>/dev/null | wc -c | tr -d ' ')
  HAS_CURRENCY=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costCurrency}' 2>/dev/null | wc -c | tr -d ' ')
  if [ "$HAS_PRICING" -gt 10 ] && [ "$HAS_CURRENCY" -gt 0 ]; then
    CUR=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costCurrency}')
    pass "costPricing populado + costCurrency='$CUR'"
  else
    fail "ConfigMap existe mas costPricing/costCurrency vazio — aplicar manifests/04-plugin-config-pricing.yaml"
  fi
else
  fail "ConfigMap custom-rhcl-console-config não existe em custom-rhcl-console — instalar o plugin antes"
fi

# ─── Resumo ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo " Tudo verde. Abrir Console → Custom Connectivity Link → Cost."
  exit 0
else
  echo " $FAIL_COUNT check(s) falharam. Ver mensagens acima."
  exit 1
fi
