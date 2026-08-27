#!/usr/bin/env bash
# Item 31 — create a complete API product via oc (declarative path).
# Applies manifests + waits for APIProduct/AuthPolicy to reconcile + runs a smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-rhcl-apps}"

# Discover the banking-api host to reuse as parent (path-based product).
HOST="${HOST:-}"
if [[ -z "$HOST" ]]; then
  HOST=$(oc -n "$NS" get httproute banking-api-connectivity \
    -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)
fi
if [[ -z "$HOST" ]]; then
  echo "ERROR: could not discover HOST. Set HOST=banking-api-connectivity.<your-zone> or have the HTTPRoute banking-api-connectivity in ns $NS." >&2
  exit 1
fi
export HOST
echo "==> Product: pix-api  |  host=$HOST  |  ns=$NS"

echo "==> Applying manifests (envsubst on the HTTPRoute for ${HOST})..."
envsubst < "$ROOT/manifests/00-httproute.yaml" | oc apply -f -
oc apply -f "$ROOT/manifests/01-apiproduct.yaml"
oc apply -f "$ROOT/manifests/02-planpolicy.yaml"
oc apply -f "$ROOT/manifests/03-authpolicy.yaml"
oc apply -f "$ROOT/manifests/04-apikey-secret.yaml"
oc apply -f "$ROOT/manifests/05-apikey-cr.yaml"

echo
echo "==> Waiting for the AuthPolicy to become Enforced (up to 60s)..."
for i in $(seq 1 12); do
  S=$(oc -n "$NS" get authpolicy pix-api-apikey \
    -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || true)
  printf "  t+%02ds  Enforced=%s\n" "$((i*5))" "${S:-?}"
  [[ "$S" == "True" ]] && break
  sleep 5
done

echo
echo "==> APIProduct status:"
oc -n "$NS" get apiproduct pix-api -o jsonpath='{.metadata.name}{"\t"}{.spec.publishStatus}{"\n"}'
echo "==> PlanPolicy:"
oc -n "$NS" get planpolicy pix-api-plans -o jsonpath='{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Enforced")].status}{"\n"}'
echo

KEY=$(oc -n "$NS" get secret pix-api-key-tester -o jsonpath='{.data.api_key}' | base64 -d)

echo "==> Smoke test:"
echo "    no key    (expected 401):"
curl -sk -o /dev/null -w "      %{http_code}\n" "https://$HOST/pix/v1"
echo "    with key  (expected 200):"
curl -sk -o /dev/null -w "      %{http_code}\n" -H "api-key: $KEY" "https://$HOST/pix/v1"
echo "    burst 7x  (expected 5x200 + 2x429 — bronze=5/min):"
for i in 1 2 3 4 5 6 7; do
  printf "      req%d -> " "$i"
  curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" "https://$HOST/pix/v1"
done

echo
echo "==> OK. Product 'pix-api' created via oc. To clean up: scripts/cleanup.sh"
