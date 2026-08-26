#!/usr/bin/env bash
set -euo pipefail

# Deploy REQ 050 — OCSP stapling + CRL revocation gateway.
#
# Mounts the CA, CRL, OCSP staple and server cert as volumes in the gateway pod,
# then configures the two EnvoyFilters to reference them by file path.
# Requires RHCL_ZONE_ROOT_DOMAIN to be set and ./certs/ generated.
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   cd tests/req050/manifests && ./generate-certs.sh && ./deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

if [[ ! -f "$CERTS_DIR/crl.pem" || ! -f "$CERTS_DIR/server-ocsp.der" ]]; then
  echo "ERROR: certs/ incomplete (crl.pem / server-ocsp.der missing)." >&2
  echo "       Run ./generate-certs.sh first." >&2
  exit 1
fi

echo "==> Domain: $RHCL_ZONE_ROOT_DOMAIN"
echo "==> Certs:  $CERTS_DIR"

NS=req050-gateway
DEPLOY_NAME=req050-revocation-gateway-openshift-default

echo ""
echo "==> [1/7] Creating namespace..."
oc apply -f "$SCRIPT_DIR/00-namespace.yaml"

echo ""
echo "==> [2/7] Creating secrets..."
# Server TLS secret. The OCSP staple rides here under `tls.ocsp-staple`: Istio's
# SDS forwards it inline on the served cert (no cert override / no SDS-vs-inline
# conflict). Built as a generic secret with type=kubernetes.io/tls so we can add
# the extra key (oc create secret tls only accepts cert+key).
oc -n $NS create secret generic req050-server-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt="$CERTS_DIR/server-fullchain.crt" \
  --from-file=tls.key="$CERTS_DIR/server.key" \
  --from-file=tls.ocsp-staple="$CERTS_DIR/server-ocsp.der" \
  --dry-run=client -o yaml | oc apply -f -

oc -n $NS create secret generic req050-intermediate-ca \
  --from-file=ca.crt="$CERTS_DIR/intermediate-ca.crt" \
  --dry-run=client -o yaml | oc apply -f -

oc -n $NS create secret generic req050-crl \
  --from-file=crl.pem="$CERTS_DIR/crl.pem" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "==> [3/7] Deploying Gateway..."
envsubst < "$SCRIPT_DIR/10-gateway.yaml" | oc apply -f -

echo ""
echo "==> [4/7] Waiting for gateway deployment..."
oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=60s 2>/dev/null || \
  oc -n $NS wait --for=condition=Available deployment/$DEPLOY_NAME --timeout=60s

echo ""
echo "==> [5/7] Mounting CA + CRL secrets as volumes in gateway pod..."
# Only the trust anchor (intermediate CA) and the CRL are file-mounted; the OCSP
# staple travels via the SDS secret, not a volume.
VOLUMES=$(oc -n $NS get deployment $DEPLOY_NAME -o jsonpath='{.spec.template.spec.volumes[*].name}')
if echo "$VOLUMES" | grep -q "req050-crl"; then
  # Redeploy: volumes already mounted, but the CA/CRL Secret content may have
  # changed. Envoy reads the file-based trusted_ca/crl once at chain build time
  # and does NOT watch the file, so restart the gateway to re-read them.
  echo "  Volumes already mounted; restarting gateway to re-read updated CA/CRL files..."
  oc -n $NS rollout restart deployment/$DEPLOY_NAME
  oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=90s
else
  oc -n $NS patch deployment $DEPLOY_NAME --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"intermediate-ca","secret":{"secretName":"req050-intermediate-ca"}}},
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"req050-crl","secret":{"secretName":"req050-crl"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"intermediate-ca","mountPath":"/etc/certs/intermediate-ca","readOnly":true}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"req050-crl","mountPath":"/etc/certs/crl","readOnly":true}}
  ]'
  echo "  Waiting for rollout..."
  oc -n $NS rollout status deployment/$DEPLOY_NAME --timeout=60s
fi

echo ""
echo "==> [6/7] Deploying EnvoyFilters (CRL + OCSP stapling)..."
"$SCRIPT_DIR/deploy-envoyfilter.sh"

echo ""
echo "==> [7/7] Deploying HTTPRoutes, ReferenceGrant, and passthrough Routes..."
envsubst < "$SCRIPT_DIR/20-httproute.yaml" | oc apply -f -
oc apply -f "$SCRIPT_DIR/25-referencegrant.yaml"
envsubst < "$SCRIPT_DIR/30-passthrough-routes.yaml" | oc apply -f -

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo ""
echo "  Hostnames (via passthrough Route):"
echo "    https://req050-crl.${RHCL_ZONE_ROOT_DOMAIN}/api/tls/info   (CRL revocation)"
echo "    https://req050-ocsp.${RHCL_ZONE_ROOT_DOMAIN}/api/tls/info  (OCSP stapling)"
echo ""
echo "  Mounted files (auto-update on Secret change):"
echo "    /etc/certs/intermediate-ca/ca.crt  ← req050-intermediate-ca"
echo "    /etc/certs/crl/crl.pem             ← req050-crl"
echo "  OCSP staple: delivered via SDS secret req050-server-tls (key tls.ocsp-staple)"
echo ""
echo "  Validate:  ./test-req050.sh A"
echo "============================================================"
