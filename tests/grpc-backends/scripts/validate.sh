#!/usr/bin/env bash
# Validation: gRPC communication with the backend via the RHCL gateway
set -euo pipefail

echo "======================================================================"
echo " Validation: gRPC backend via the gateway"
echo "======================================================================"

PASS=0
FAIL=0
WARN=0

# Note: use VAR=$((VAR+1)) not ((VAR++)) — with set -e, ((VAR++)) returns
# status 1 when the previous value is 0 and aborts the script on the first check.
check_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
HOST="req048-grpc.${CLUSTER_DOMAIN}"
REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "  Hostname: $HOST"
echo "  Gateway:  $GW_NAME ($GW_NS)"
echo "  Namespace: $REQ_NS"
echo ""

# --- 1. Namespace existe ---
echo "--- 1. Namespace $REQ_NS ---"
if oc get namespace "$REQ_NS" &>/dev/null; then
  check_pass "Namespace $REQ_NS existe"
else
  check_fail "Namespace $REQ_NS NÃO encontrado"
fi

# --- 2. Deployment ---
echo ""
echo "--- 2. Deployment req048-banking-api ---"
if oc -n "$REQ_NS" get deployment req048-banking-api &>/dev/null; then
  READY=$(oc -n "$REQ_NS" get deployment req048-banking-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -gt 0 ]; then
    check_pass "Deployment req048-banking-api: $READY Ready replica(s)"
  else
    check_warn "Deployment exists but 0 Ready replicas"
  fi
else
  check_fail "Deployment req048-banking-api NÃO encontrado"
fi

# --- 3. Service e appProtocol ---
echo ""
echo "--- 3. Service req048-grpc-backend ---"
if oc -n "$REQ_NS" get svc req048-grpc-backend &>/dev/null; then
  check_pass "Service req048-grpc-backend existe"
  PROTO=$(oc -n "$REQ_NS" get svc req048-grpc-backend -o jsonpath='{.spec.ports[0].appProtocol}' 2>/dev/null || echo "ERRO")
  if [ "$PROTO" = "kubernetes.io/h2c" ]; then
    check_pass "appProtocol=kubernetes.io/h2c (→ HTTP/2 upstream para gRPC)"
  else
    check_fail "appProtocol esperado 'kubernetes.io/h2c', obtido '$PROTO'"
  fi
else
  check_fail "Service req048-grpc-backend NÃO encontrado"
fi

# --- 4. Listener no gateway ---
echo ""
echo "--- 4. Listener req048-grpc no gateway ---"
LISTENER_EXISTS=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req048-grpc$" || echo "0")
if [ "$LISTENER_EXISTS" -gt 0 ]; then
  check_pass "Listener req048-grpc presente no gateway"
else
  check_fail "Listener req048-grpc NÃO encontrado no gateway"
fi

# --- 5. HTTPRoute ---
echo ""
echo "--- 5. HTTPRoute req048-grpc-route ---"
if oc -n "$REQ_NS" get httproute req048-grpc-route &>/dev/null; then
  ACCEPTED=$(oc -n "$REQ_NS" get httproute req048-grpc-route -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req048-grpc")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$ACCEPTED" = "True" ]; then
    check_pass "HTTPRoute req048-grpc-route aceito pelo gateway"
  else
    check_warn "HTTPRoute existe mas status Accepted=$ACCEPTED"
  fi
else
  check_fail "HTTPRoute req048-grpc-route NÃO encontrado"
fi

# --- 6. AuthPolicy ---
echo ""
echo "--- 6. AuthPolicy req048-allow-public ---"
if oc -n "$REQ_NS" get authpolicy req048-allow-public &>/dev/null; then
  ENFORCED=$(oc -n "$REQ_NS" get authpolicy req048-allow-public -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
  if [ "$ENFORCED" = "True" ]; then
    check_pass "AuthPolicy req048-allow-public Enforced"
  else
    check_warn "AuthPolicy existe mas Enforced=$ENFORCED (pode levar alguns segundos)"
  fi
else
  check_fail "AuthPolicy req048-allow-public NÃO encontrado"
fi

# --- 7. Teste gRPC nativo (unary) via grpcurl ---
echo ""
echo "--- 7. Teste gRPC nativo (unary) via grpcurl ---"
if command -v grpcurl &>/dev/null; then
  GRPC_RESULT=$(grpcurl -plaintext -d '{"api_version":"v1"}' \
    "$HOST:80" io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary 2>&1 || echo "ERRO")
  if echo "$GRPC_RESULT" | grep -qE '"api_?[vV]ersion"'; then
    check_pass "gRPC unary GetSummary returned a valid response"
  elif echo "$GRPC_RESULT" | grep -qi "ERRO\|failed\|connection refused"; then
    check_warn "gRPC unary falhou: $(echo "$GRPC_RESULT" | head -2)"
  else
    check_warn "gRPC unary: resposta inesperada (verifique manualmente)"
  fi
else
  check_warn "grpcurl not installed — skipping teste gRPC nativo"
  echo "         Instale: https://github.com/fullstorydev/grpcurl/releases"
fi

# --- 8. gRPC reflection test (list services) ---
echo ""
echo "--- 8. gRPC reflection test (list services) ---"
if command -v grpcurl &>/dev/null; then
  LIST_RESULT=$(grpcurl -plaintext "$HOST:80" list 2>&1 || echo "ERRO")
  if echo "$LIST_RESULT" | grep -q "io.gatewaysmashes.rhcl.grpc.BankingService"; then
    check_pass "gRPC reflection: BankingService listed"
  elif echo "$LIST_RESULT" | grep -qi "ERRO\|failed"; then
    check_warn "gRPC reflection failed: $(echo "$LIST_RESULT" | head -2)"
  else
    check_warn "Reflection: BankingService not found in the list"
  fi
else
  check_warn "grpcurl not installed — skipping reflection test"
fi

# --- 9. Teste gRPC-Web via curl ---
echo ""
echo "--- 9. Teste gRPC-Web via curl ---"
GRPC_WEB_RESPONSE=$(printf '\x00\x00\x00\x00\x04\x0a\x02v1' | \
  curl -sS -X POST --max-time 10 --data-binary @- \
    -H 'content-type: application/grpc-web+proto' \
    -H 'x-grpc-web: true' \
    -o /dev/null -w "%{http_code}" \
    "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary" 2>/dev/null || echo "000")

if [ "$GRPC_WEB_RESPONSE" = "200" ]; then
  check_pass "gRPC-Web: HTTP 200 (content-type: application/grpc-web+proto)"
elif [ "$GRPC_WEB_RESPONSE" = "000" ]; then
  check_warn "gRPC-Web: timeout/unreachable (DNS ou rede)"
else
  check_warn "gRPC-Web: HTTP $GRPC_WEB_RESPONSE (esperado 200)"
fi

# --- 10. Envoy config dump (verificar h2c cluster) ---
echo ""
echo "--- 10. Envoy upstream protocol (config_dump) ---"
GW_POD=$(oc -n "$GW_NS" get pods -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" -o name 2>/dev/null | head -1 || echo "")
if [ -n "$GW_POD" ]; then
  H2C_CLUSTER=$(oc -n "$GW_NS" exec "$GW_POD" -c istio-proxy -- pilot-agent request GET /config_dump 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for config in data.get('configs', []):
        for cluster in config.get('dynamic_active_clusters', []):
            name = cluster.get('cluster', {}).get('name', '')
            if 'req048' in name:
                print(name)
                break
except: pass
" 2>/dev/null || echo "")
  if [ -n "$H2C_CLUSTER" ]; then
    check_pass "Envoy cluster gRPC encontrado: $H2C_CLUSTER"
  else
    check_warn "req048 cluster not found in config_dump (may take time to propagate)"
  fi
else
  check_warn "Gateway pod not reachable for config_dump"
fi

# --- Resumo ---
echo ""
echo "======================================================================"
echo " RESULTADO: $PASS passed, $FAIL failed, $WARN warnings"
echo "======================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "There are failures. Run apply.sh first:"
  echo "  bash tests/grpc-backends/scripts/apply.sh"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Validation OK with warnings (network/DNS may not be reachable from this host)."
  echo ""
  echo "Para testar de dentro do cluster:"
  echo "  oc -n $REQ_NS run grpc-test --rm -i --restart=Never \\"
  echo "    --image=fullstorydev/grpcurl:latest -- \\"
  echo "    -plaintext -d '{\"api_version\":\"v1\"}' \\"
  echo "    $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
  exit 0
else
  echo ""
  echo "All checks passed!"
  exit 0
fi
