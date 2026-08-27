#!/usr/bin/env bash
# Validation: generates controlled traffic (mix 200/401/404) and checks
# that the audit file only received the 4xx.
set -euo pipefail

OK=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then echo "  ✓ $label"; OK=$((OK+1))
  else echo "  ✗ $label"; FAIL=$((FAIL+1)); fi
}

echo "======================================================================"
echo " Gateway error-logging validation"
echo "======================================================================"

# --- Recursos presentes ---
echo ""
echo "[recursos]"
check "EnvoyFilter otel-access-logs-rhcl-apps-gateway presente" \
  oc get envoyfilter -n openshift-ingress otel-access-logs-rhcl-apps-gateway
check "Pipeline 'logs' configurada no Collector" \
  bash -c "oc get opentelemetrycollector -n observability otel-rhcl -o jsonpath='{.spec.config.service.pipelines.logs}' | grep -q exporters"
check "Exporter 'file/audit' configurado" \
  bash -c "oc get opentelemetrycollector -n observability otel-rhcl -o jsonpath='{.spec.config.exporters}' | grep -q file/audit"

# --- Controlled traffic ---
echo ""
echo "[traffic] Generating a mix of 5×200, 5×401, 3×404 against banking-api..."
URL=$(oc get httproute -n rhcl-apps banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}')
URL="https://$URL"
ALICE=$(oc get secret -n rhcl-apps banking-api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)

# 5 × 200 (should not appear in the audit file)
for _ in 1 2 3 4 5; do
  curl -sk --max-time 5 -o /dev/null -H "api-key: $ALICE" "$URL/api/v1/accounts/summary" || true
done
# 5 × 401 (sem api-key) — devem aparecer
for _ in 1 2 3 4 5; do
  curl -sk --max-time 5 -o /dev/null "$URL/api/v1/accounts/summary" || true
done
# 3 × 404 (nonexistent path, valid alice) — should appear
for _ in 1 2 3; do
  curl -sk --max-time 5 -o /dev/null -H "api-key: $ALICE" "$URL/api/v9/no-route-here" || true
done
echo "  → traffic enviado; aguardando OTel batch flush (8s)..."
sleep 8

# --- Audit-file check ---
echo ""
echo "[audit file]"
COL=$(oc get pods -n observability -l app.kubernetes.io/name=otel-rhcl-collector -o jsonpath='{.items[0].metadata.name}')
check "Audit file existe no pod do Collector" \
  oc exec -n observability "$COL" -- test -f /var/log/rhcl-errors.json

# Conta entries por status code
COUNT_401=$(oc exec -n observability "$COL" -- sh -c 'grep -o "\"response_code\".*\"401\"" /var/log/rhcl-errors.json | wc -l' 2>/dev/null || echo "0")
COUNT_404=$(oc exec -n observability "$COL" -- sh -c 'grep -o "\"response_code\".*\"404\"" /var/log/rhcl-errors.json | wc -l' 2>/dev/null || echo "0")
COUNT_200=$(oc exec -n observability "$COL" -- sh -c 'grep -o "\"response_code\".*\"200\"" /var/log/rhcl-errors.json | wc -l' 2>/dev/null || echo "0")

echo "  • 401s no audit: $COUNT_401 (esperado ≥5)"
echo "  • 404s no audit: $COUNT_404 (esperado ≥3)"
echo "  • 200s no audit: $COUNT_200 (esperado 0 — filtro Envoy)"

[ "$COUNT_401" -ge 5 ] && OK=$((OK+1)) && echo "  ✓ 401s capturados" || { FAIL=$((FAIL+1)); echo "  ✗ 401s capturados"; }
[ "$COUNT_404" -ge 3 ] && OK=$((OK+1)) && echo "  ✓ 404s capturados" || { FAIL=$((FAIL+1)); echo "  ✗ 404s capturados"; }
[ "$COUNT_200" -eq 0 ] && OK=$((OK+1)) && echo "  ✓ 200s NÃO capturados (filtro Envoy efetivo)" || { FAIL=$((FAIL+1)); echo "  ✗ 200s vazaram para o audit"; }

# --- Mostrar 1 entry de exemplo ---
echo ""
echo "[exemplo]"
oc exec -n observability "$COL" -- sh -c 'tail -1 /var/log/rhcl-errors.json' 2>/dev/null \
  | python3 -c "
import sys,json
try:
    d = json.loads(sys.stdin.read())
    rl = d['resourceLogs'][0]
    lr = rl['scopeLogs'][0]['logRecords'][0]
    attrs = {a['key']: list(a['value'].values())[0] for a in lr['attributes']}
    print('  body  =', lr['body']['stringValue'])
    print('  trace_id =', lr.get('traceId','(none)'))
    for k in ['http.method','http.path','response_code','response.flags','auth.reason','consumer.id','request.id']:
        if k in attrs: print(f'  {k:14s} = {attrs[k]}')
except Exception as e:
    print(f'  (parse error: {e})')
" 2>/dev/null || echo "  (audit file vazio ou parse falhou)"

echo ""
echo "======================================================================"
echo " Resultado: $OK ok, $FAIL fail"
echo "======================================================================"
[ "$FAIL" -eq 0 ]
