#!/usr/bin/env bash
# Send ONE request front-to-back and show it in the audit trail:
#   1) fire a single request through the RHCL gateway with a correlation id
#   2) pull the gateway's JSON audit access-log line for that request
#      (consumer identity, request id, traceparent, response code)
#   3) print the distributed-trace id + the Tempo link to open it
#
# Prereqs (installed by the observability role, or tests/req038 + tests/req066):
#   - gateway JSON access log     (EnvoyFilter access-log-json, req066)
#   - distributed tracing → Tempo (req038) + trace-response-headers EnvoyFilter
#
# Everything is parameterised via env vars so it runs in a customer cluster.
#
#   AUDIT_HOST=banking-api.apps.my-cluster.example.com ./trace-one-request.sh
#
set -euo pipefail

# ---- config (override via env) ------------------------------------------------
HOST="${AUDIT_HOST:-}"                                     # REQUIRED: gateway host for banking-api
API_KEY="${AUDIT_API_KEY:-alice-gold-secret}"             # a valid consumer key
REQ_PATH="${AUDIT_PATH:-/api/test/propagate?target=gateway&calls=2}"  # protected + returns traceId
GW_NS="${AUDIT_GATEWAY_NS:-openshift-ingress}"
GW_DEPLOY="${AUDIT_GATEWAY_DEPLOY:-rhcl-apps-gateway-istio}"
GW_CONTAINER="${AUDIT_ISTIO_CONTAINER:-istio-proxy}"
TEMPO_TENANT="${AUDIT_TEMPO_TENANT:-dev}"
TEMPO_ROUTE="${AUDIT_TEMPO_ROUTE:-}"                       # auto-derived if empty

b(){ printf '\033[1m%s\033[0m\n' "$*"; }
dim(){ printf '\033[2m%s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v oc >/dev/null || die "oc not found."
oc whoami >/dev/null 2>&1 || die "oc is not logged in."
[ -n "$HOST" ] || die "Set AUDIT_HOST to the gateway host serving banking-api (e.g. banking-api.apps.<cluster>)."

FLOW_ID="audit-e2e-$(date +%s)-$RANDOM"
URL="https://${HOST}${REQ_PATH}"

# ---- 1. one request -----------------------------------------------------------
b "== 1. sending one request =="
dim "  $URL"
dim "  x-flow-trace-id: $FLOW_ID"
BODY="$(curl -sk -D /tmp/.audit-hdrs \
  -H "x-flow-trace-id: ${FLOW_ID}" \
  -H "x-consumer-id-hint: ${API_KEY%%-*}" \
  -H "api-key: ${API_KEY}" \
  --max-time 20 "$URL" || true)"
CODE="$(awk 'NR==1{print $2}' /tmp/.audit-hdrs 2>/dev/null || echo '?')"
printf '  http=%s\n' "$CODE"

# trace id: prefer the propagate response body, fall back to the response header
# the trace-response-headers EnvoyFilter re-emits.
TRACE_ID="$(printf '%s' "$BODY" | sed -n 's/.*"traceId"[^"]*"\([0-9a-f]\{16,32\}\)".*/\1/p' | head -1)"
[ -n "$TRACE_ID" ] || TRACE_ID="$(grep -i '^x-trace-id:' /tmp/.audit-hdrs 2>/dev/null | tr -d '\r' | awk '{print $2}' | head -1)"

# ---- 2. the audit access-log line --------------------------------------------
b "== 2. gateway audit access-log line =="
dim "  waiting for the log to flush…"
LINE=""
for _ in 1 2 3 4 5 6; do
  LINE="$(oc -n "$GW_NS" logs "deploy/${GW_DEPLOY}" -c "$GW_CONTAINER" --tail=400 2>/dev/null | grep -F "$FLOW_ID" | tail -1 || true)"
  [ -n "$LINE" ] && break
  sleep 2
done
if [ -z "$LINE" ]; then
  printf '  (no line found for %s — check AUDIT_GATEWAY_DEPLOY / that the access-log EnvoyFilter is installed)\n' "$FLOW_ID"
else
  echo "$LINE" | python3 -m json.tool 2>/dev/null || echo "$LINE"
  echo
  b "   who / what / where:"
  echo "$LINE" | python3 - "$FLOW_ID" <<'PY' 2>/dev/null || true
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
def g(*k):
    for x in k:
        v = d.get(x)
        if v not in (None, "", "-"): return v
    return "—"
print(f"     consumer_id : {g('consumer_id')}")
print(f"     response    : {g('response_code')}")
print(f"     route       : {g('route_name')}")
print(f"     request_id  : {g('request_id')}")
print(f"     traceparent : {g('traceparent')}")
PY
fi

# ---- 3. the distributed trace -------------------------------------------------
b "== 3. distributed trace =="
if [ -z "$TRACE_ID" ]; then
  printf '  (no trace id captured — the request may not have hit a traced route)\n'
else
  printf '  trace id: %s\n' "$TRACE_ID"
  if [ -z "$TEMPO_ROUTE" ]; then
    TEMPO_ROUTE="$(oc -n tempo get route -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -i gateway | head -1)"
  fi
  if [ -n "$TEMPO_ROUTE" ]; then
    printf '  open: https://%s/api/traces/v1/%s/trace/%s\n' "$TEMPO_ROUTE" "$TEMPO_TENANT" "$TRACE_ID"
  fi
  dim "  or: OpenShift console → Observe → Traces → instance tempo-rhcl → tenant ${TEMPO_TENANT}, search this trace id"
  dim "  spans should include: rhcl-gateway → banking-api (→ ledger-api), one trace id"
fi

echo
b "Correlate: the access-log line's request_id / traceparent ↔ the trace above — same request, front to back."
