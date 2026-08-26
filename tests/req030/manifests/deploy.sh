#!/usr/bin/env bash
set -euo pipefail

# Deploy REQ 030 — request interception (ext_authz + RequestMirror).
#
# Standalone gateway, hello-world backend, and request-interceptor app.
# Two listeners / hostnames demonstrate the two strategies separately.
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   cd tests/req030/manifests && ./deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

GW_NS=req030-gateway
APPS_NS=req030-apps
GW_NAME=req030-interceptor-gateway
DEPLOY_NAME="${GW_NAME}-istio"

echo "==> Domain: $RHCL_ZONE_ROOT_DOMAIN"

echo ""
echo "==> [1/8] Creating namespaces..."
oc apply -f "$SCRIPT_DIR/00-namespace.yaml"

echo ""
echo "==> [2/8] Deploying hello-world backend..."
oc apply -f "$SCRIPT_DIR/15-hello-world-app.yaml"
oc -n "$APPS_NS" rollout status deployment/hello-world --timeout=120s

echo ""
echo "==> [3/8] Deploying request-interceptor (Service, Deployment)..."
oc apply -f "$SCRIPT_DIR/16-request-interceptor-app.yaml"
oc -n "$APPS_NS" rollout status deployment/request-interceptor --timeout=180s

echo ""
echo "==> [4/8] Deploying Gateway..."
envsubst < "$SCRIPT_DIR/10-gateway.yaml" | oc apply -f -

echo ""
echo "==> [5/8] Waiting for gateway deployment..."
oc -n "$GW_NS" rollout status "deployment/$DEPLOY_NAME" --timeout=120s 2>/dev/null || \
  oc -n "$GW_NS" wait --for=condition=Available "deployment/$DEPLOY_NAME" --timeout=120s

echo ""
echo "==> [6/8] Registering Istio extension provider + AuthorizationPolicy..."
echo "    (interactive — select the Istio CR that backs your gateway)"
"$SCRIPT_DIR/deploy-istio-extension-provider.sh"
envsubst < "$SCRIPT_DIR/36-authorizationpolicy.yaml" | oc apply -f -

echo ""
echo "==> [7/8] Deploying HTTPRoutes and ReferenceGrant..."
oc apply -f "$SCRIPT_DIR/25-referencegrant.yaml"
envsubst < "$SCRIPT_DIR/20-httproute-extauthz.yaml" | oc apply -f -
envsubst < "$SCRIPT_DIR/21-httproute-mirror.yaml" | oc apply -f -

echo ""
echo "==> [8/8] Applying OpenShift Routes..."
envsubst < "$SCRIPT_DIR/30-openshift-routes.yaml" | oc apply -f -

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo ""
echo "  Hostnames:"
echo "    https://req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}/   (ext_authz)"
echo "    https://req030-mirror.${RHCL_ZONE_ROOT_DOMAIN}/     (RequestMirror)"
echo ""
echo "  Validate:  ./test-req030.sh"
echo "============================================================"
