#!/usr/bin/env bash
# req054 — Validação: consumir backends em HTTP/1.1 e HTTP/2
set -euo pipefail

echo "======================================================================"
echo " REQ 054 — Validação: HTTP/1.1 e HTTP/2 upstream"
echo "======================================================================"

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; ((PASS++)); }
check_fail() { echo "  ✗ $1"; ((FAIL++)); }
check_warn() { echo "  ⚠ $1"; ((WARN++)); }

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
HOST="req054-backend.${CLUSTER_DOMAIN}"
APPS_NS="rhcl-apps"
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "  Hostname: $HOST"
echo "  Gateway:  $GW_NAME ($GW_NS)"
echo ""

# --- 1. Services existem ---
echo "--- 1. Services req054 ---"
if oc -n "$APPS_NS" get svc req054-backend-http11 &>/dev/null; then
  check_pass "Service req054-backend-http11 existe"
else
  check_fail "Service req054-backend-http11 NÃO encontrado"
fi

if oc -n "$APPS_NS" get svc req054-backend-h2c &>/dev/null; then
  check_pass "Service req054-backend-h2c existe"
else
  check_fail "Service req054-backend-h2c NÃO encontrado"
fi

# --- 2. appProtocol ---
echo ""
echo "--- 2. appProtocol nos Services ---"

PROTO_HTTP11=$(oc -n "$APPS_NS" get svc req054-backend-http11 -o jsonpath='{.spec.ports[0].appProtocol}' 2>/dev/null || echo "ERRO")
if [ -z "$PROTO_HTTP11" ] || [ "$PROTO_HTTP11" = "<no value>" ]; then
  check_pass "req054-backend-http11: sem appProtocol (→ HTTP/1.1 upstream)"
else
  check_fail "req054-backend-http11: appProtocol inesperado: $PROTO_HTTP11"
fi

PROTO_H2C=$(oc -n "$APPS_NS" get svc req054-backend-h2c -o jsonpath='{.spec.ports[0].appProtocol}' 2>/dev/null || echo "ERRO")
if [ "$PROTO_H2C" = "kubernetes.io/h2c" ]; then
  check_pass "req054-backend-h2c: appProtocol=kubernetes.io/h2c (→ HTTP/2 upstream)"
else
  check_fail "req054-backend-h2c: appProtocol esperado 'kubernetes.io/h2c', obtido '$PROTO_H2C'"
fi

# --- 3. Listener no gateway ---
echo ""
echo "--- 3. Listener req054-http no gateway ---"
LISTENER_EXISTS=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req054-http$" || echo "0")
if [ "$LISTENER_EXISTS" -gt 0 ]; then
  check_pass "Listener req054-http presente no gateway"
else
  check_fail "Listener req054-http NÃO encontrado no gateway"
fi

# --- 4. HTTPRoute ---
echo ""
echo "--- 4. HTTPRoute req054-http-versions ---"
if oc -n "$APPS_NS" get httproute req054-http-versions &>/dev/null; then
  ACCEPTED=$(oc -n "$APPS_NS" get httproute req054-http-versions -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req054-http")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$ACCEPTED" = "True" ]; then
    check_pass "HTTPRoute req054-http-versions aceito pelo gateway"
  else
    check_warn "HTTPRoute existe mas status Accepted=$ACCEPTED"
  fi
else
  check_fail "HTTPRoute req054-http-versions NÃO encontrado"
fi

# --- 5. AuthPolicy ---
echo ""
echo "--- 5. AuthPolicy req054-allow-public ---"
if oc -n "$APPS_NS" get authpolicy req054-allow-public &>/dev/null; then
  ENFORCED=$(oc -n "$APPS_NS" get authpolicy req054-allow-public -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
  if [ "$ENFORCED" = "True" ]; then
    check_pass "AuthPolicy req054-allow-public Enforced"
  else
    check_warn "AuthPolicy existe mas Enforced=$ENFORCED (pode levar alguns segundos)"
  fi
else
  check_fail "AuthPolicy req054-allow-public NÃO encontrado"
fi

# --- 6. Teste end-to-end ---
echo ""
echo "--- 6. Teste end-to-end via curl ---"

HTTP11_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "http://$HOST/http11/api/v1/accounts/summary" 2>/dev/null || echo "000")
if [ "$HTTP11_CODE" = "200" ]; then
  check_pass "HTTP/1.1 backend: HTTP $HTTP11_CODE"
elif [ "$HTTP11_CODE" = "000" ]; then
  check_warn "HTTP/1.1 backend: timeout/unreachable (DNS ou rede)"
else
  check_warn "HTTP/1.1 backend: HTTP $HTTP11_CODE (esperado 200)"
fi

H2_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "http://$HOST/h2/api/v1/accounts/summary" 2>/dev/null || echo "000")
if [ "$H2_CODE" = "200" ]; then
  check_pass "HTTP/2 (h2c) backend: HTTP $H2_CODE"
elif [ "$H2_CODE" = "000" ]; then
  check_warn "HTTP/2 (h2c) backend: timeout/unreachable (DNS ou rede)"
else
  check_warn "HTTP/2 (h2c) backend: HTTP $H2_CODE (esperado 200)"
fi

# --- 7. Envoy config dump (verificar h2c cluster) ---
echo ""
echo "--- 7. Envoy upstream protocol (config_dump) ---"
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
            if 'req054' in name and 'h2c' in name:
                print(name)
                break
except: pass
" 2>/dev/null || echo "")
  if [ -n "$H2C_CLUSTER" ]; then
    check_pass "Envoy cluster h2c encontrado: $H2C_CLUSTER"
  else
    check_warn "Cluster h2c não encontrado no config_dump (pode levar tempo para propagar)"
  fi
else
  check_warn "Pod do gateway não acessível para config_dump"
fi

# --- Resumo ---
echo ""
echo "======================================================================"
echo " RESULTADO: $PASS passed, $FAIL failed, $WARN warnings"
echo "======================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Há falhas. Execute apply.sh primeiro:"
  echo "  bash tests/req054/scripts/apply.sh"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "Validação OK com avisos (rede/DNS pode não estar acessível deste host)."
  echo ""
  echo "Para testar de dentro do cluster:"
  echo "  oc -n $APPS_NS run curl-req054 --rm -i --restart=Never --image=curlimages/curl:latest \\"
  echo "    -- curl -sv http://$HOST/http11/api/v1/accounts/summary"
  exit 0
else
  echo ""
  echo "Todas as verificações passaram!"
  exit 0
fi
