#!/usr/bin/env bash
set -euo pipefail

# Interactive validator for REQ 030 — request interception.
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   ./test-req030.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

HOST_EXT="req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}"
HOST_MIRROR="req030-mirror.${RHCL_ZONE_ROOT_DOMAIN}"
INTERCEPTOR_NS=req030-apps
INTERCEPTOR_DEPLOY=request-interceptor

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

echo "==> REQ 030 validation"
echo "    ext_authz host:  https://$HOST_EXT"
echo "    mirror host:     https://$HOST_MIRROR"
echo ""

echo "==> [1/4] Checking workloads..."
oc -n req030-apps get deployment hello-world -o jsonpath='{.status.availableReplicas}' | grep -q '^1$' \
  && pass "hello-world is available" || fail "hello-world not ready"

oc -n "$INTERCEPTOR_NS" get deployment "$INTERCEPTOR_DEPLOY" -o jsonpath='{.status.availableReplicas}' | grep -q '^1$' \
  && pass "request-interceptor is available" || fail "request-interceptor not ready"

echo ""
echo "==> [2/4] ext_authz — request should reach hello-world after interceptor check..."
RESP=$(curl -sk -o /tmp/req030-extauthz-body.txt -w '%{http_code}' \
  -H 'X-Request-ID: req030-extauthz-test' \
  -H 'Content-Type: application/json' \
  -d '{"probe":"extauthz"}' \
  "https://${HOST_EXT}/" || true)
[[ "$RESP" == "200" ]] && pass "GET https://$HOST_EXT/ returned 200" \
  || fail "GET https://$HOST_EXT/ returned $RESP (expected 200)"

echo ""
echo "==> [3/4] RequestMirror — request should reach hello-world (mirror is async)..."
RESP=$(curl -sk -o /tmp/req030-mirror-body.txt -w '%{http_code}' \
  -H 'X-Request-ID: req030-mirror-test' \
  -H 'Content-Type: application/json' \
  -d '{"probe":"mirror"}' \
  "https://${HOST_MIRROR}/" || true)
[[ "$RESP" == "200" ]] && pass "GET https://$HOST_MIRROR/ returned 200" \
  || fail "GET https://$HOST_MIRROR/ returned $RESP (expected 200)"

echo ""
echo "==> [4/4] Checking request-interceptor logs for intercepted traffic..."
sleep 3
LOGS=$(oc -n "$INTERCEPTOR_NS" logs "deployment/$INTERCEPTOR_DEPLOY" --tail=200 2>/dev/null || true)
echo "$LOGS" | grep -q 'req030-extauthz-test\|/check' \
  && pass "interceptor saw ext_authz traffic" \
  || echo "  WARN: ext_authz log line not found (check interceptor logs manually)"

echo "$LOGS" | grep -q 'req030-mirror-test\|mirror' \
  && pass "interceptor saw mirrored traffic" \
  || echo "  WARN: mirror log line not found (RequestMirror is fire-and-forget; grep logs manually)"

echo ""
echo "============================================================"
echo "  Validation complete."
echo ""
echo "  Inspect interceptor logs:"
echo "    oc -n $INTERCEPTOR_NS logs deployment/$INTERCEPTOR_DEPLOY --tail=50"
echo "============================================================"
