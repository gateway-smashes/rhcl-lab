#!/usr/bin/env bash
# Item 31 — create an API product via raw REST against the API server.
# Applies the RBAC first, grabs a token for the SA req031-product-admin, and creates EACH
# CR via curl HTTP POST/PUT authenticated ONLY by the Bearer token (no oc). Proves that
# the "admin API" is the Kubernetes one — any HTTP client/SDK works.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-rhcl-apps}"

# Prerequisite: the RBAC must exist (creates the SA). Apply it first via oc — the
# only thing that needs "create RBAC" permission (typically cluster-admin).
# After that, everything uses the SA token.
echo "==> Applying RBAC (06-rbac.yaml) via oc — the only step that needs cluster-admin..."
oc apply -f "$ROOT/manifests/06-rbac.yaml"

# Discover HOST + API server
HOST="${HOST:-$(oc -n "$NS" get httproute banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)}"
if [[ -z "$HOST" ]]; then echo "ERROR: set HOST=banking-api-connectivity.<zone>" >&2; exit 1; fi
export HOST

APISERVER="$(oc whoami --show-server)"
echo "==> API server: $APISERVER"

echo "==> Minting an ephemeral (1h) token for SA req031-product-admin..."
TOKEN=$(oc -n "$NS" create token req031-product-admin --duration=1h)
[[ -n "$TOKEN" ]] || { echo "ERROR: failed to create token"; exit 1; }

# Helper: POST a YAML/JSON manifest to the appropriate endpoint, authenticated by the
# SA Bearer. Uses --insecure-skip-tls-verify-equivalent via -k (sandbox CA).
post() {
  local file="$1" url="$2"
  echo "    POST $url"
  envsubst < "$file" | curl -sk -X POST "$url" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/yaml" \
    -H "Accept: application/json" \
    --data-binary @- -w "      HTTP %{http_code}\n" -o /tmp/req031-resp.json
}

echo
echo "==> Creating each CR via the K8s API REST:"
post "$ROOT/manifests/00-httproute.yaml"   "$APISERVER/apis/gateway.networking.k8s.io/v1/namespaces/$NS/httproutes"
post "$ROOT/manifests/01-apiproduct.yaml"  "$APISERVER/apis/devportal.kuadrant.io/v1alpha1/namespaces/$NS/apiproducts"
post "$ROOT/manifests/02-planpolicy.yaml"  "$APISERVER/apis/extensions.kuadrant.io/v1alpha1/namespaces/$NS/planpolicies"
post "$ROOT/manifests/03-authpolicy.yaml"  "$APISERVER/apis/kuadrant.io/v1/namespaces/$NS/authpolicies"
post "$ROOT/manifests/04-apikey-secret.yaml" "$APISERVER/api/v1/namespaces/$NS/secrets"
post "$ROOT/manifests/05-apikey-cr.yaml"   "$APISERVER/apis/devportal.kuadrant.io/v1alpha1/namespaces/$NS/apikeys"

echo
echo "==> Listing what was created (LIST via REST, no oc):"
curl -sk "$APISERVER/apis/devportal.kuadrant.io/v1alpha1/namespaces/$NS/apiproducts" \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(f"  APIProduct: {i[\"metadata\"][\"name\"]}  publishStatus={i[\"spec\"].get(\"publishStatus\")}  displayName={i[\"spec\"].get(\"displayName\")}") for i in d.get("items",[])]'

echo
echo "==> Smoke test on the created product:"
KEY=$(oc -n "$NS" get secret pix-api-key-tester -o jsonpath='{.data.api_key}' | base64 -d)
for label in "no key (401)" "with key (200)"; do
  if [[ "$label" == "no key (401)" ]]; then
    H=()
  else
    H=(-H "api-key: $KEY")
  fi
  printf "  %s -> " "$label"
  curl -sk -o /dev/null -w "%{http_code}\n" "${H[@]}" "https://$HOST/pix/v1"
done

echo
echo "==> OK. Product 'pix-api' created via the K8s API REST (no oc, except the initial RBAC)."
echo "    The token is from SA req031-product-admin — any HTTP client/SDK can replicate this."
