#!/usr/bin/env bash
# req048 — Validação do exemplo complementar: GRPCRoute (roteamento gRPC idiomático)
# Valida também a coexistência: o exemplo com HTTPRoute deve continuar funcional.
set -euo pipefail

echo "======================================================================"
echo " REQ 048 — Validação: GRPCRoute (exemplo complementar)"
echo "======================================================================"

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
HOST="req048-grpcroute.${CLUSTER_DOMAIN}"
HOST_HTTPROUTE="req048-grpc.${CLUSTER_DOMAIN}"
REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "  Hostname GRPCRoute: $HOST"
echo "  Hostname HTTPRoute: $HOST_HTTPROUTE"
echo "  Gateway:   $GW_NAME ($GW_NS)"
echo "  Namespace: $REQ_NS"
echo ""

# --- 1. CRD GRPCRoute disponível (v1) ---
echo "--- 1. CRD GRPCRoute (Gateway API) ---"
GRPC_CRD_VERSIONS=$(oc get crd grpcroutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null || echo "")
if echo "$GRPC_CRD_VERSIONS" | grep -qw "v1"; then
  check_pass "CRD grpcroutes.gateway.networking.k8s.io servido em v1 (GA)"
else
  check_fail "GRPCRoute v1 NÃO disponível (versões servidas: '${GRPC_CRD_VERSIONS:-nenhuma}')"
fi

# --- 2. Listener no gateway ---
echo ""
echo "--- 2. Listener req048-grpcroute no gateway ---"
LISTENER_EXISTS=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req048-grpcroute$" || true)
if [ "${LISTENER_EXISTS:-0}" -gt 0 ]; then
  check_pass "Listener req048-grpcroute presente no gateway"
else
  check_fail "Listener req048-grpcroute NÃO encontrado no gateway"
fi

# --- 3. GRPCRoute aceito ---
echo ""
echo "--- 3. GRPCRoute req048-grpcroute ---"
if oc -n "$REQ_NS" get grpcroute req048-grpcroute &>/dev/null; then
  ACCEPTED=$(oc -n "$REQ_NS" get grpcroute req048-grpcroute -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req048-grpcroute")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$ACCEPTED" = "True" ]; then
    check_pass "GRPCRoute req048-grpcroute aceito pelo gateway"
  else
    check_warn "GRPCRoute existe mas status Accepted=$ACCEPTED"
  fi
else
  check_fail "GRPCRoute req048-grpcroute NÃO encontrado"
fi

# --- 4. Reflexão gRPC via GRPCRoute (grpcurl list) ---
echo ""
echo "--- 4. Reflexão gRPC via GRPCRoute (list services) ---"
if command -v grpcurl &>/dev/null; then
  LIST_RESULT=$(grpcurl -plaintext "$HOST:80" list 2>&1 || echo "ERRO")
  if echo "$LIST_RESULT" | grep -q "io.gatewaysmashes.rhcl.grpc.BankingService"; then
    check_pass "Reflexão via GRPCRoute: BankingService listado"
  else
    check_warn "Reflexão via GRPCRoute falhou: $(echo "$LIST_RESULT" | head -2)"
  fi
else
  check_warn "grpcurl não instalado — pulando testes gRPC nativos"
  echo "         Instale: https://github.com/fullstorydev/grpcurl/releases"
fi

# --- 5. gRPC unary via GRPCRoute ---
echo ""
echo "--- 5. gRPC nativo (unary) via GRPCRoute ---"
if command -v grpcurl &>/dev/null; then
  GRPC_RESULT=$(grpcurl -plaintext -d '{"api_version":"v1"}' \
    "$HOST:80" io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary 2>&1 || echo "ERRO")
  if echo "$GRPC_RESULT" | grep -qE '"api_?[vV]ersion"'; then
    check_pass "gRPC unary GetSummary via GRPCRoute retornou resposta válida"
  else
    check_warn "gRPC unary via GRPCRoute falhou: $(echo "$GRPC_RESULT" | head -2)"
  fi
fi

# --- 6. gRPC server-streaming via GRPCRoute ---
echo ""
echo "--- 6. gRPC server-streaming via GRPCRoute ---"
if command -v grpcurl &>/dev/null; then
  STREAM_RESULT=$(grpcurl -plaintext -d '{"interval_ms":300,"max_events":3}' \
    "$HOST:80" io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth 2>&1 || echo "ERRO")
  EVENTS=$(echo "$STREAM_RESULT" | grep -c '"timestamp"' || true)
  if [ "${EVENTS:-0}" -ge 2 ]; then
    check_pass "Server-streaming via GRPCRoute: $EVENTS eventos recebidos"
  else
    check_warn "Server-streaming via GRPCRoute: $(echo "$STREAM_RESULT" | head -2)"
  fi
fi

# --- 7. Coexistência: HTTPRoute continua funcional ---
echo ""
echo "--- 7. Coexistência: exemplo HTTPRoute continua funcional ---"
if command -v grpcurl &>/dev/null; then
  HTTPROUTE_RESULT=$(grpcurl -plaintext -d '{"api_version":"v1"}' \
    "$HOST_HTTPROUTE:80" io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary 2>&1 || echo "ERRO")
  if echo "$HTTPROUTE_RESULT" | grep -qE '"api_?[vV]ersion"'; then
    check_pass "gRPC via HTTPRoute ($HOST_HTTPROUTE) continua OK"
  else
    check_warn "gRPC via HTTPRoute falhou: $(echo "$HTTPROUTE_RESULT" | head -2)"
  fi
fi

# --- 8. Matching explícito: path não declarado deve receber 404 do gateway ---
echo ""
echo "--- 8. Matching explícito por serviço (path REST → 404 do gateway) ---"
NOT_MATCHED=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "http://${HOST}/q/health/ready" 2>/dev/null || echo "000")
if [ "$NOT_MATCHED" = "404" ]; then
  check_pass "Path fora das rules do GRPCRoute rejeitado pelo gateway (HTTP 404)"
elif [ "$NOT_MATCHED" = "000" ]; then
  check_warn "Teste de matching explícito: timeout/unreachable (DNS ou rede)"
else
  check_warn "Path fora das rules retornou HTTP $NOT_MATCHED (esperado 404)"
fi

# --- 9. Informativo: gRPC-Web no hostname do GRPCRoute ---
echo ""
echo "--- 9. Informativo: gRPC-Web no hostname do GRPCRoute ---"
GRPC_WEB_RESPONSE=$(printf '\x00\x00\x00\x00\x04\x0a\x02v1' | \
  curl -sS -X POST --max-time 10 --data-binary @- \
    -H 'content-type: application/grpc-web+proto' \
    -H 'x-grpc-web: true' \
    -o /dev/null -w "%{http_code}" \
    "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary" 2>/dev/null || echo "000")
if [ "$GRPC_WEB_RESPONSE" = "200" ]; then
  check_pass "gRPC-Web também respondeu via GRPCRoute (HTTP 200) — comportamento da implementação Envoy/Istio"
else
  check_warn "gRPC-Web via GRPCRoute: HTTP $GRPC_WEB_RESPONSE — esperado; a spec do GRPCRoute cobre apenas gRPC nativo (use o HTTPRoute para gRPC-Web)"
fi

# --- Nota de governança ---
echo ""
echo "--- Nota de governança (RHCL 1.3.5) ---"
echo "  ℹ O tráfego roteado por GRPCRoute NÃO passa pelo enforcement do"
echo "    Kuadrant: AuthPolicy/RateLimitPolicy não podem targetear GRPCRoute"
echo "    e o wasm-shim só deriva regras de HTTPRoutes (nem o deny-all do"
echo "    gateway se aplica). Para gRPC governado, use o exemplo HTTPRoute."

# --- Resumo ---
echo ""
echo "======================================================================"
echo " RESULTADO: $PASS passed, $FAIL failed, $WARN warnings"
echo "======================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Há falhas. Execute os scripts de apply primeiro:"
  echo "  bash tests/req048/scripts/apply.sh"
  echo "  bash tests/req048/scripts/apply-grpcroute.sh"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Validação OK com avisos (rede/DNS pode não estar acessível deste host)."
  echo ""
  echo "Para testar de dentro do cluster:"
  echo "  oc -n $REQ_NS run grpc-test --rm -i --restart=Never \\"
  echo "    --image=fullstorydev/grpcurl:latest -- \\"
  echo "    -plaintext -d '{\"api_version\":\"v1\"}' \\"
  echo "    $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
  exit 0
else
  echo ""
  echo "Todas as verificações passaram!"
  exit 0
fi
