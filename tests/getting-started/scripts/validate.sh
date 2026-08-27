#!/usr/bin/env bash
# Getting started — validate end-to-end.
#
# 8 checks against the cluster + gateway. Each prints PASS/FAIL,
# non-zero exit on the first error.
#
# Usage:
#   HOSTNAME=banking-lite.pocrhcl.redhat.lab.example.com ./scripts/validate.sh
set -uo pipefail

: "${HOSTNAME:?HOSTNAME env var required — same one you passed to apply.sh}"

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
echo "1. HTTPRoute banking-lite Accepted by the gateway"
if oc -n rhcl-apps get httproutes.gateway.networking.k8s.io banking-lite \
   -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; then
  pass "HTTPRoute was accepted"
else
  fail "HTTPRoute was NOT accepted by the gateway — check parentRef and allowedRoutes"
fi

# 2. APIProduct Ready
echo ""
echo "2. APIProduct banking-lite exists"
if oc -n rhcl-apps get apiproduct banking-lite >/dev/null 2>&1; then
  pass "APIProduct exists"
else
  fail "APIProduct not found"
fi

# 3. Policies Enforced (Kuadrant's "green tick")
echo ""
echo "3. AuthPolicy + PlanPolicy + RateLimitPolicy Enforced"
for pol in "authpolicy/banking-lite-apikey" "planpolicy/banking-lite-plans" "ratelimitpolicy/banking-lite-global-ratelimit"; do
  STATUS=$(oc -n rhcl-apps get "$pol" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "")
  if [ "$STATUS" = "True" ]; then
    pass "$pol Enforced"
  else
    fail "$pol NOT Enforced (status=$STATUS)"
  fi
done

# 4. curl without key → 401
echo ""
echo "4. Request WITHOUT api-key → 401"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "401" ]; then
  pass "gateway responded 401 (AuthPolicy working)"
else
  fail "expected 401, got $CODE — the AuthPolicy may not be Enforced yet"
fi

# 5. curl with wrong key → 401
echo ""
echo "5. Request WITH an invalid api-key → 401"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
  -H "api-key: nonexistent-key" \
  "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "401" ]; then
  pass "invalid key rejected"
else
  fail "expected 401, got $CODE"
fi

# 6. curl with correct key → 200
echo ""
echo "6. Request WITH a valid api-key → 200"
RESP=$(curl -sk -H "api-key: ${KEY}" "https://${HOSTNAME}/api/v1/accounts/summary")
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -H "api-key: ${KEY}" "https://${HOSTNAME}/api/v1/accounts/summary")
if [ "$CODE" = "200" ] && echo "$RESP" | grep -q '\['; then
  pass "backend responded with JSON"
  info "$(echo "$RESP" | head -c 120)..."
else
  fail "expected 200 with JSON, got $CODE"
fi

# 7. Rate limit — fires 60 fast requests, should start rejecting
echo ""
echo "7. Rate limit — 65 requests in a row should produce at least one 429"
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
info "result: ${COUNT_2XX} × 2xx, ${COUNT_429} × 429, ${COUNT_OTHER} × other"
if [ "$COUNT_429" -gt 0 ]; then
  pass "rate limit fired (${COUNT_429} × 429)"
else
  fail "no 429 appeared — the PlanPolicy may not be counting correctly"
fi

# 8. Dev portal sees the APIProduct
echo ""
echo "8. Portal-backend sees the new APIProduct"
if oc -n rhcl-devportal get pod -l app=portal-backend >/dev/null 2>&1; then
  BACKEND_URL=$(oc -n rhcl-devportal get route portal-backend -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
  if [ -n "$BACKEND_URL" ]; then
    FOUND=$(curl -sk "${BACKEND_URL}/api/products" 2>/dev/null | grep -c '"name":"banking-lite"' || echo "0")
    if [ "$FOUND" -gt 0 ]; then
      pass "banking-lite listed in ${BACKEND_URL}/api/products"
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
echo " ✓ Getting started working end-to-end."
echo "   Next steps in the guide: point mobile-bank + onboard via the portal."
echo "══════════════════════════════════════════════════════════════"
