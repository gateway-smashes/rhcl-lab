#!/usr/bin/env bash
# req066 — Validação: auditoria e rastreabilidade de chamadas
set -euo pipefail

echo "======================================================================"
echo " REQ 066 — Validação: auditoria e rastreabilidade"
echo "======================================================================"

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; ((PASS++)); }
check_fail() { echo "  ✗ $1"; ((FAIL++)); }
check_warn() { echo "  ⚠ $1"; ((WARN++)); }

GW_DEPLOY=$(oc -n openshift-ingress get deploy -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || echo "rhcl-apps-gateway-openshift-default")

# --- 1. EnvoyFilter ---
echo ""
echo "--- 1. EnvoyFilter access-log-json ---"
if oc -n openshift-ingress get envoyfilter access-log-json &>/dev/null; then
  check_pass "EnvoyFilter access-log-json existe"
else
  check_fail "EnvoyFilter access-log-json NÃO encontrado"
fi

# --- 2. Verificar que Envoy não rejeitou a config ---
echo ""
echo "--- 2. Erros de rejeição no Envoy ---"
REJECT_COUNT=$(oc -n openshift-ingress logs "deploy/$GW_DEPLOY" \
  -c istio-proxy --tail=30 2>/dev/null | \
  grep -c "Not supported field\|rejected.*access_log" 2>/dev/null || echo "0")

if [ "$REJECT_COUNT" -eq 0 ]; then
  check_pass "Nenhum erro de rejeição de access log no Envoy"
else
  check_fail "Envoy rejeitou a configuração de access log ($REJECT_COUNT erros)"
  echo "         Verifique: oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=10"
fi

# --- 3. Gerar request de teste e verificar access log ---
echo ""
echo "--- 3. Teste end-to-end: request → access log JSON ---"
FLOW_ID="validate-req066-$(date +%s)"
echo "  Enviando request com x-flow-trace-id: $FLOW_ID"

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "x-flow-trace-id: $FLOW_ID" \
  "https://banking-api.poc.rhcl.com.br/api/echo" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" != "000" ]; then
  check_pass "Request enviado (HTTP $HTTP_CODE)"
else
  check_warn "Request falhou (endpoint pode não estar acessível deste host)"
fi

sleep 2

echo ""
echo "--- 4. Access log JSON no gateway ---"
LOG_ENTRY=$(oc -n openshift-ingress logs "deploy/$GW_DEPLOY" \
  -c istio-proxy --tail=200 2>/dev/null | \
  grep "$FLOW_ID" 2>/dev/null | \
  python3 -c "
import sys,json
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        print(json.dumps(d))
        break
    except: pass
" 2>/dev/null || echo "")

if [ -n "$LOG_ENTRY" ]; then
  check_pass "Access log JSON encontrado para flow_trace_id=$FLOW_ID"

  # Verificar campos de auditoria essenciais
  echo ""
  echo "--- 5. Campos de auditoria ---"
  for FIELD in request_id method path response_code client_ip timestamp authority traceparent route_name downstream_tls_version downstream_tls_cipher consumer_id auth_reason flow_trace_id; do
    HAS_FIELD=$(echo "$LOG_ENTRY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print('yes' if '$FIELD' in d else 'no')" 2>/dev/null || echo "no")
    if [ "$HAS_FIELD" = "yes" ]; then
      VALUE=$(echo "$LOG_ENTRY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); v=d.get('$FIELD'); print(v if v else '(null/vazio)')" 2>/dev/null || echo "?")
      check_pass "Campo '$FIELD' presente ($VALUE)"
    else
      check_fail "Campo '$FIELD' AUSENTE no access log"
    fi
  done

  # Mostrar o access log completo formatado
  echo ""
  echo "--- Access log completo (formatado) ---"
  echo "$LOG_ENTRY" | python3 -m json.tool 2>/dev/null || echo "$LOG_ENTRY"
else
  # Tentar encontrar no formato texto (EnvoyFilter pode não ter sido aplicado)
  TEXT_LOG=$(oc -n openshift-ingress logs "deploy/$GW_DEPLOY" \
    -c istio-proxy --tail=200 2>/dev/null | \
    grep "$FLOW_ID" 2>/dev/null | head -1 || echo "")

  if [ -n "$TEXT_LOG" ]; then
    check_fail "Access log encontrado mas NÃO está em formato JSON (EnvoyFilter pode não ter sido aceito)"
    echo "         Log encontrado (texto): ${TEXT_LOG:0:120}..."
  else
    check_warn "Nenhum access log encontrado para $FLOW_ID (endpoint pode não estar acessível)"
  fi
fi

# --- 6. Stack de tracing (req038) ---
echo ""
echo "--- 6. Stack de tracing (req038 — recomendado) ---"
if oc -n observability get opentelemetrycollector otel-rhcl &>/dev/null; then
  check_pass "OpenTelemetryCollector otel-rhcl ativo"
else
  check_warn "Stack de tracing (req038) não encontrado — correlação trace limitada"
fi

if oc -n tempo get tempostack tempo-rhcl &>/dev/null; then
  TEMPO_STATUS=$(oc -n tempo get tempostack tempo-rhcl -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$TEMPO_STATUS" = "True" ]; then
    check_pass "TempoStack tempo-rhcl Ready"
  else
    check_warn "TempoStack tempo-rhcl não está Ready (status: $TEMPO_STATUS)"
  fi
else
  check_warn "TempoStack não encontrado — Observe → Traces indisponível"
fi

# --- 7. Kuadrant observability ---
echo ""
echo "--- 7. Kuadrant observability (correlação cross-component) ---"
HTTP_HEADER_ID=$(oc -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.spec.observability.dataPlane.httpHeaderIdentifier}' 2>/dev/null || echo "")
if [ "$HTTP_HEADER_ID" = "x-request-id" ]; then
  check_pass "httpHeaderIdentifier: $HTTP_HEADER_ID (correlação via x-request-id)"
else
  check_warn "httpHeaderIdentifier não configurado (correlação cross-component limitada)"
fi

# --- Resumo ---
echo ""
echo "======================================================================"
echo " RESULTADO: $PASS passed, $FAIL failed, $WARN warnings"
echo "======================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Há falhas que precisam ser corrigidas."
  echo ""
  echo "Dica: Se o Envoy rejeitou o EnvoyFilter, verifique os campos"
  echo "      no json_format. O campo DOWNSTREAM_TLS_CIPHER_SUITE não é"
  echo "      suportado neste cluster — use DOWNSTREAM_TLS_CIPHER."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Validação OK com avisos. Verifique os itens marcados com ⚠."
  echo ""
  echo "LEMBRETE: A evidência do req066 está nos logs do gateway (oc logs),"
  echo "          NÃO na UI de Traces (Observe → Traces = req038)."
  exit 0
else
  echo ""
  echo "Todas as verificações passaram!"
  echo ""
  echo "LEMBRETE: A evidência do req066 está nos logs do gateway (oc logs),"
  echo "          NÃO na UI de Traces (Observe → Traces = req038)."
  exit 0
fi
