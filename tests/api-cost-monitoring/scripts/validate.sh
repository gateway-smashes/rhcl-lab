#!/usr/bin/env bash
# api-cost-monitoring/scripts/validate.sh — checks each pillar of the cost stack.
#
# 5 checks. Each one prints PASS/FAIL/WARN and an explanatory one-liner.
# Exits with 0 if all pass, 1 if any FAIL.
#
# Usage:
#   ./tests/api-cost-monitoring/scripts/validate.sh
#   ./tests/api-cost-monitoring/scripts/validate.sh --verbose  # logs the commands
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
echo " Cost-monitoring validation"
echo "══════════════════════════════════════════════════════════════════"

# ─── 1. banking-api emite bank_ai_tokens_total ──────────────────────────
echo ""
echo "1. Backend emitting the bank_ai_tokens_total counter"
POD=$(oc -n rhcl-apps get pods -l app=banking-api-v1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$POD" ]; then
  fail "no banking-api-v1 pod in rhcl-apps"
else
  # temporary port-forward
  oc -n rhcl-apps port-forward "$POD" 18080:8080 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  SERIES=$(curl -s --max-time 5 http://localhost:18080/q/metrics 2>/dev/null | grep -c '^bank_ai_tokens_total' || echo "0")
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true

  if [ "$SERIES" -gt 0 ]; then
    pass "counter present ($SERIES series in /q/metrics)"
  else
    fail "counter missing — did you call any /api/v1/chat/completions or /embeddings endpoint?"
    info "Try: curl -X POST https://<gateway>/api/v1/chat/completions -H 'content-type: application/json' -d '{\"model\":\"banking-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  fi
fi

# ─── 2. ServiceMonitor existe ───────────────────────────────────────────
echo ""
echo "2. ServiceMonitor for UWM to scrape banking-api"
if oc -n rhcl-apps get servicemonitor banking-api >/dev/null 2>&1; then
  pass "servicemonitor/banking-api applied"
else
  fail "servicemonitor/banking-api does NOT exist — apply manifests/02-servicemonitor-banking-api.yaml"
fi

# ─── 3. Telemetry CR applied ────────────────────────────────────────────
echo ""
echo "3. Telemetry CR with custom labels"
if oc -n openshift-ingress get telemetry rhcl-api-metrics >/dev/null 2>&1; then
  # Confirm it has targetRefs (the gotcha)
  if oc -n openshift-ingress get telemetry rhcl-api-metrics -o jsonpath='{.spec.targetRefs}' | grep -q Gateway; then
    pass "telemetry/rhcl-api-metrics with spec.targetRefs → Gateway"
  else
    fail "telemetry/rhcl-api-metrics exists but has NO spec.targetRefs — labels will not populate"
    info "Without targetRefs the CR only applies to sidecars — Gateway API gateways are left out."
  fi
else
  fail "telemetry/rhcl-api-metrics does NOT exist — apply manifests/03-telemetry-consumer-labels.yaml"
fi

# ─── 4. Prometheus sees bank_ai_tokens_total ──────────────────────────────
echo ""
echo "4. Thanos/UWM has the bank_ai_tokens_total series"
THANOS=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$THANOS" ]; then
  warn "thanos-querier route not found — skipping check (cluster probably has no exposed monitoring)"
else
  COUNT=$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
    "https://$THANOS/api/v1/query?query=bank_ai_tokens_total" 2>/dev/null \
    | grep -oE '"result":\[[^]]*\]' | grep -oc '"metric"' || echo "0")
  if [ "$COUNT" -gt 0 ]; then
    pass "Thanos returns $COUNT bank_ai_tokens_total series"
  else
    fail "Thanos has no series — check UWM logs: oc -n openshift-user-workload-monitoring logs prometheus-user-workload-0 | grep banking-api"
  fi
fi

# ─── 5. istio_requests_total with consumer_id ───────────────────────────
echo ""
echo "5. istio_requests_total tem label request_headers_x_consumer_id populado"
if [ -n "$THANOS" ]; then
  Q='istio_requests_total{request_headers_x_consumer_id!="",request_headers_x_consumer_id!="<nil>"}'
  Q_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$Q" 2>/dev/null || echo "$Q")
  COUNT=$(curl -sk --max-time 10 -H "Authorization: Bearer $(oc whoami -t)" \
    "https://$THANOS/api/v1/query?query=$Q_ENC" 2>/dev/null \
    | grep -oE '"result":\[[^]]*\]' | grep -oc '"metric"' || echo "0")
  if [ "$COUNT" -gt 0 ]; then
    pass "$COUNT series with consumer_id populated — Telemetry CR is working"
  else
    fail "no series with consumer_id — generate traffic with an api-key: ./tests/simulate-api-traffic.sh --target=banking --duration=60"
  fi
else
  warn "no Thanos exposed — skipping"
fi

# ─── 6. pricing ConfigMap configured ────────────────────────────────────
echo ""
echo "6. Plugin ConfigMap with costPricing + costCurrency"
if oc -n custom-rhcl-console get cm custom-rhcl-console-config >/dev/null 2>&1; then
  HAS_PRICING=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costPricing}' 2>/dev/null | wc -c | tr -d ' ')
  HAS_CURRENCY=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costCurrency}' 2>/dev/null | wc -c | tr -d ' ')
  if [ "$HAS_PRICING" -gt 10 ] && [ "$HAS_CURRENCY" -gt 0 ]; then
    CUR=$(oc -n custom-rhcl-console get cm custom-rhcl-console-config -o jsonpath='{.data.costCurrency}')
    pass "costPricing populated + costCurrency='$CUR'"
  else
    fail "ConfigMap exists but costPricing/costCurrency empty — apply manifests/04-plugin-config-pricing.yaml"
  fi
else
  fail "ConfigMap custom-rhcl-console-config does not exist in custom-rhcl-console — install the plugin first"
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo " All green. Open Console → Custom Connectivity Link → Cost."
  exit 0
else
  echo " $FAIL_COUNT check(s) failed. See messages above."
  exit 1
fi
