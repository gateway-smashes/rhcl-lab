#!/usr/bin/env bash
set -euo pipefail

# Deploy REQ 051 + 056 mTLS gateway manifests.
#
# Mounts CA secrets as volumes in the gateway pod and configures EnvoyFilter
# to reference them by file path. Requires RHCL_ZONE_ROOT_DOMAIN to be set.
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   cd tests/req051/manifests && ./deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

if [[ ! -d "$CERTS_DIR" ]]; then
  echo "ERROR: certs/ directory not found. Run ./generate-certs.sh first." >&2
  exit 1
fi

echo "==> Domain: $RHCL_ZONE_ROOT_DOMAIN"
echo "==> Certs:  $CERTS_DIR"

NS=req051-gateway
DEPLOY_NAME=req051-mtls-gateway-openshift-default

echo ""
echo "==> [1/7] Creating namespace..."
oc apply -f "$SCRIPT_DIR/00-namespace.yaml"

echo ""
echo "==> [2/7] Creating secrets..."
oc -n $NS create secret tls req051-server-tls \
  --cert="$CERTS_DIR/server-fullchain.crt" \
  --key="$CERTS_DIR/server.key" \
  --dry-run=client -o yaml | oc apply -f -

oc -n $NS create secret generic req051-intermediate-ca-sdscert \
  --from-file=ca.crt="$CERTS_DIR/intermediate-ca.crt" \
  --dry-run=client -o yaml | oc apply -f -

oc -n $NS create secret generic req051-root-ca-sdscert \
  --from-file=ca.crt="$CERTS_DIR/root-ca.crt" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "==> [3/7] Deploying Gateway..."
envsubst < "$SCRIPT_DIR/10-gateway.yaml" | oc apply -f -

echo ""
echo "==> [4/7] Waiting for gateway deployment..."
oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=60s 2>/dev/null || \
  oc -n $NS wait --for=condition=Available deployment/$DEPLOY_NAME --timeout=60s

echo ""
echo "==> [5/7] Mounting CA secrets as volumes in gateway pod..."
VOLUMES=$(oc -n $NS get deployment $DEPLOY_NAME -o jsonpath='{.spec.template.spec.volumes[*].name}')
if echo "$VOLUMES" | grep -q "intermediate-ca"; then
  # Redeploy: volumes already mounted, but the CA Secret content may have changed
  # (e.g. certs regenerated). Envoy reads the file-based trusted_ca once at chain
  # build time and does NOT watch the file, so a stale cached CA rejects the new
  # client certs. Restart the gateway so Envoy re-reads the updated CA files.
  echo "  Volumes already mounted; restarting gateway to re-read updated CA files..."
  oc -n $NS rollout restart deployment/$DEPLOY_NAME
  oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=90s
else
  oc -n $NS patch deployment $DEPLOY_NAME --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"intermediate-ca","secret":{"secretName":"req051-intermediate-ca-sdscert"}}},
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"root-ca","secret":{"secretName":"req051-root-ca-sdscert"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"intermediate-ca","mountPath":"/etc/certs/intermediate-ca","readOnly":true}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"root-ca","mountPath":"/etc/certs/root-ca","readOnly":true}}
  ]'
  echo "  Waiting for rollout..."
  oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=90s
fi

echo ""
echo "==> [6/7] Deploying EnvoyFilter (mTLS enforcement from mounted CA files)..."
"$SCRIPT_DIR/deploy-envoyfilter.sh"

echo ""
echo "==> [7/7] Deploying echo backend, HTTPRoutes, ReferenceGrant, and passthrough Routes..."
# Echo backend (same namespace as the routes) so the HTTPRoutes can show the full
# request — including the x-forwarded-client-cert (XFCC) header — back to the client.
oc apply -f "$SCRIPT_DIR/40-echo-backend.yaml"
oc -n $NS rollout status deployment/echo-server --timeout=90s
envsubst < "$SCRIPT_DIR/20-httproute.yaml" | oc apply -f -
oc apply -f "$SCRIPT_DIR/25-referencegrant.yaml"
envsubst < "$SCRIPT_DIR/30-passthrough-routes.yaml" | oc apply -f -

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo ""
echo "  Hostnames (via passthrough Route):"
echo "    https://req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}/api/tls/info"
echo "    https://req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}/api/tls/info"
echo "    https://req051-untrusted.${RHCL_ZONE_ROOT_DOMAIN}/api/tls/info"
echo ""
echo "  CA certs are mounted from Secrets (auto-updates on Secret change):"
echo "    /etc/certs/intermediate-ca/ca.crt  ← req051-intermediate-ca-sdscert"
echo "    /etc/certs/root-ca/ca.crt          ← req051-root-ca-sdscert"
echo "============================================================"
