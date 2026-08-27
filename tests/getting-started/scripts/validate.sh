#!/usr/bin/env bash
# Getting started — validate end-to-end.
#
# 8 checks contra o cluster + gateway. Cada um imprime PASS/FAIL,
# non-zero exit on the first error.
#
# Uso:
#   HOSTNAME=banking-lite.pocrhcl.redhat.lab.example.com ./scripts/validate.sh
set -uo pipefail

: "${HOSTNAME:?HOSTNAME env var required — mesma que passou pro apply.sh}"

pass() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$1"; exit 1; }
info() { printf '     \033[2m%s\033[0m\n' "$1"; }

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

KEY=$(oc -n rhcl-apps get secret banking-lite-onboarding-key -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d)
if [ -z "$KEY" ]; then
  fail "Secret banking-lite-onboarding-key does not exist — apply 06-apikey-secret.yaml first"
fi

echo "══════════════════════════════════════════════════════════════"
echo " Getting Started — validation"
echo "══════════════════════════════════════════════════════════════"
echo ""

# 1. HTTPRoute Accepted
echo "1. HTTPRoute banking-lite Accepted pelo gateway"
if oc -n rhcl-apps get httproutes.gateway.networking.k8s.io banking-lite \
   -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; then
  pass "HTTPRoute foi aceita"
else
  fail "HTTPRoute NÃO foi aceita pelo gateway — checar parentRef e allowedRoutes"
fi

# 2. APIProduct Ready
echo ""
echo "2. APIProduct banking-lite existe"
if oc -n rhcl-apps get apiproduct banking-lite >/dev/null 2>&1; then
  pass "APIProduct existe"
else
  fail "APIProduct not found"
fi

# 3. Policies Enforced (o "green tick" do Kuadrant)
echo ""
echo "3. AuthPolicy + PlanPolicy + RateLimitPolicy Enforced"
for pol in "authpolicy/banking-lite-apikey" "planpolicy/banking-lite-plans" "ratelimitpolicy/banking-lite-global-ratelimit"; do
  STATUS=$(oc -n rhcl-apps get "$pol" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
  if [ "$STATUS" = "True" ]; then
    pass "$pol Enforced"
  else
    fail "$pol NÃO Enforced (status=$STATUS)"
  fi
done

# 4. curl sem key → 401
echo ""
echo "4. Request SEM api-key → 401"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "401" ]; then
  pass "gateway respondeu 401 (AuthPolicy funcionando)"
else
  fail "expected 401, got $CODE — the AuthPolicy may not be Enforced yet"
fi

# 5. curl com key errada → 401
echo ""
echo "5. Request WITH an invalid api-key → 401"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  -H "api-key: chave-inexistente" \
  "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "401" ]; then
  pass "invalid key rejected"
else
  fail "esperado 401, veio $CODE"
fi

# 6. curl com key correta → 200
echo ""
echo "6. Request WITH a valid api-key → 200"
RESP=$(curl -sk -H "api-key: ${KEY}" "https://${HOSTNAME}/api/v1/accounts/summary")
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -H "api-key: ${KEY}" "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "200" ] && echo "$RESP" | grep -q '\['; then
  pass "backend respondeu com JSON"
  info "$(echo "$RESP" | head -c 120)..."
else
  fail "esperado 200 com JSON, veio $CODE"
fi

# 7. Rate limit — fires 60 fast requests, should start rejecting
echo ""
echo "7. Rate limit — 65 requests seguidas devem gerar pelo menos um 429"
COUNT_2XX=0; COUNT_429=0; COUNT_OTHER=0
for i in $(seq 1 65); do
  RC=$(curl -sk -o /dev/null -w '%{http_code}' -H "api-key: ${KEY}" \
    "https://${HOSTNAME}/api/v1/accounts/summary")
  case "$RC" in
    2*) COUNT_2XX=$((COUNT_2XX+1)) ;;
    429) COUNT_429=$((COUNT_429+1)) ;;
    *) COUNT_OTHER=$((COUNT_OTHER+1)) ;;
  esac
done
info "resultado: ${COUNT_2XX} × 2xx, ${COUNT_429} × 429, ${COUNT_OTHER} × outros"
if [ "$COUNT_429" -gt 0 ]; then
  pass "rate limit disparou (${COUNT_429} × 429)"
else
  fail "no 429 appeared — the PlanPolicy may not be counting correctly"
fi

# 8. Dev portal enxerga o APIProduct
echo ""
echo "8. Portal-backend enxerga o novo APIProduct"
if oc -n rhcl-devportal get pod -l app=portal-backend >/dev/null 2>&1; then
  BACKEND_URL=$(oc -n rhcl-devportal get route portal-backend -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [ -n "$BACKEND_URL" ]; then
    FOUND=$(curl -sk "${BACKEND_URL}/api/products" 2>/dev/null | grep -c '"name":"banking-lite"' || echo "0")
    if [ "$FOUND" -gt 0 ]; then
      pass "banking-lite listado em ${BACKEND_URL}/api/products"
    else
      info "portal-backend has not returned banking-lite yet — may take ~30s to sync"
    fi
  else
    info "portal-backend route not found — the dev portal may not be installed"
  fi
else
  info "portal-backend deployment not found — dev portal is optional for getting-started"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " ✓ Getting started funcionando end-to-end."
echo "   Next steps in the guide: point mobile-bank + onboard via the portal."
echo "══════════════════════════════════════════════════════════════"
