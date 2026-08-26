#!/usr/bin/env bash
# check-gateway-health.sh — quick verdict on whether the RHCL Istio gateway
# data plane is actually serving traffic, and whether the RHCL 1.4 wasm-shim ↔
# Envoy incompatibility is present (see docs/known-issues/rhcl-14-gateway-wasm-incompat.md).
#
# Read-only. Run it right after a fresh RHCL install to confirm if the
# gateway bug reproduces.
#
# Usage:
#   ./tests/check-gateway-health.sh
#   ./tests/check-gateway-health.sh --ns=openshift-ingress --route-ns=rhcl-apps
set -uo pipefail

GW_NS=openshift-ingress
ROUTE_NS=rhcl-apps
for a in "$@"; do case "$a" in
  --ns=*) GW_NS="${a#*=}" ;;
  --route-ns=*) ROUTE_NS="${a#*=}" ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
yel()   { printf '\033[33m%s\033[0m\n' "$*"; }
hdr()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

oc whoami >/dev/null 2>&1 || { red "oc not logged in"; exit 1; }

hdr "Operator versions"
oc get csv -n kuadrant-system 2>/dev/null \
  | grep -iE 'rhcl-operator|authorino|limitador|dns-operator|servicemesh' \
  | awk '{print "  "$1"  ("$NF")"}'
ISTIO_VER=$(oc get istio -A -o jsonpath='{.items[0].status.version}' 2>/dev/null)
echo "  Istio (Sail CR): ${ISTIO_VER:-unknown}"

hdr "Gateway pod"
GW_NAME=$(oc get gateway -n "$ROUTE_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$GW_NAME" ] && GW_NAME=$(oc get gateway -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "  Gateway: ${GW_NAME:-<none>}"
POD=$(oc -n "$GW_NS" get pods -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then red "  no gateway data-plane pod found in $GW_NS"; exit 2; fi
READY=$(oc -n "$GW_NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
echo "  Pod: $POD  ready=$READY"

hdr "Envoy / wasm log scan (last 200 lines)"
LOGS=$(oc -n "$GW_NS" logs "$POD" --tail=200 2>/dev/null)
WASM_BUG=0
if grep -q "allow_on_headers_stop_iteration" <<<"$LOGS"; then
  red   "  ✗ wasm field rejected: 'allow_on_headers_stop_iteration' (1.4 wasm ↔ Envoy incompat)"; WASM_BUG=1
fi
if grep -qi "Wasm remote code fetch is unstable" <<<"$LOGS"; then
  red   "  ✗ unstable remote wasm fetch (blocks listener warming)"; WASM_BUG=1
fi
if grep -qiE "sendDownstreamDelta took [0-9]{2,}" <<<"$LOGS"; then
  yel   "  ⚠ very slow xDS push (tens of seconds)"
fi
[ "$WASM_BUG" -eq 0 ] && grn "  ✓ no wasm incompatibility signatures in logs"

hdr "Live traffic test (public /api/echo via the gateway ELB)"
HOST=$(oc -n "$ROUTE_NS" get httproute -o jsonpath='{.items[0].spec.hostnames[0]}' 2>/dev/null)
ELB=$(oc -n "$GW_NS" get svc -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null | grep -m1 .)
echo "  host=$HOST  elb=$ELB"
CODE=000
if [ -n "$HOST" ] && [ -n "$ELB" ]; then
  CODE=$(oc -n "$ROUTE_NS" run gw-health-$RANDOM --rm -i --restart=Never \
    --image=registry.access.redhat.com/ubi9/ubi-minimal --command -- /bin/sh -c "
      IP=\$(getent hosts $ELB | awk '{print \$1; exit}')
      curl -sk -o /dev/null -w '%{http_code}' --max-time 12 --resolve $HOST:443:\$IP https://$HOST/api/echo
    " 2>/dev/null | grep -oE '[0-9]{3}' | head -1)
fi
echo "  GET https://$HOST/api/echo -> HTTP ${CODE:-000}"

hdr "Verdict"
if [ "$READY" = "true" ] && [ "$WASM_BUG" -eq 0 ] && [ "${CODE:-000}" != "000" ]; then
  grn "  PASS — gateway is serving traffic. The 1.4 wasm issue is NOT present."
  exit 0
else
  red "  FAIL — gateway not serving (ready=$READY, wasm_bug=$WASM_BUG, echo=$CODE)."
  echo "  See docs/known-issues/rhcl-14-gateway-wasm-incompat.md"
  exit 3
fi
