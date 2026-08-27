#!/usr/bin/env bash
# req048 — Communicate with the API backends over gRPC
# Creates a dedicated namespace, deploys the banking-api with gRPC, an h2c Service and an HTTPRoute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 048 — Communicate with the API backends over gRPC"
echo "======================================================================"

# --- Detect hostname ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo " ✗ ERROR: Could not detect the cluster domain."
  echo "   Set the CLUSTER_DOMAIN variable manually:"
  echo "   export CLUSTER_DOMAIN=apps.ocp.xxx.example.com"
  exit 1
fi

HOST="req048-grpc.${CLUSTER_DOMAIN}"
HOST_GRPCROUTE="req048-grpcroute.${CLUSTER_DOMAIN}"
REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
APPS_NS="rhcl-apps"

echo ""
echo " Cluster domain: $CLUSTER_DOMAIN"
echo " Hostname req048:    $HOST"
echo " Namespace:          $REQ_NS"

# --- Prerequisites ---
echo ""
echo "[prereq] Checking RHCL / Kuadrant..."
if oc get kuadrant -n kuadrant-system &>/dev/null; then
  echo " ✓ Kuadrant installed"
else
  echo " ✗ Kuadrant NOT found in kuadrant-system."
  exit 1
fi

echo ""
echo "[prereq] Detecting the RHCL gateway..."
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "")
if [ -n "$GW_NAME" ]; then
  echo " ✓ Gateway: $GW_NAME"
else
  echo " ✗ Gateway not found in $GW_NS."
  exit 1
fi

echo ""
echo "[prereq] Checking ImageStream banking-api in $APPS_NS..."
if oc -n "$APPS_NS" get imagestream banking-api &>/dev/null; then
  echo " ✓ ImageStream banking-api exists in $APPS_NS"
else
  echo " ⚠ ImageStream banking-api not found in $APPS_NS."
  echo "   The Deployment will use the direct reference to the internal registry."
fi

# --- Step 1: Create Namespace ---
echo ""
echo "=== Step 1/6: Namespace $REQ_NS ==="
oc apply -f "$MANIFESTS/00-namespace.yaml"
echo " ✓ Namespace $REQ_NS created/verified"

# --- Step 2: RoleBinding image-puller ---
echo ""
echo "=== Step 2/6: RoleBinding image-puller ==="
oc apply -f "$MANIFESTS/01-rolebinding-image-pull.yaml"
echo " ✓ RoleBinding req048-image-puller in $APPS_NS"

# --- Step 3: Deployment ---
echo ""
echo "=== Step 3/6: Deployment banking-api (gRPC) ==="
sed "s/{{ namespace }}/$REQ_NS/g" "$MANIFESTS/02-deployment.yaml" | oc apply -f -
echo " ✓ Deployment req048-banking-api applied"

echo " Waiting for the pod to become Ready..."
oc -n "$REQ_NS" rollout status deployment/req048-banking-api --timeout=120s || {
  echo " ⚠ Timeout waiting for the Deployment. Check the events:"
  echo "   oc -n $REQ_NS get events --sort-by=.lastTimestamp"
}

# --- Step 4: Service with appProtocol h2c ---
echo ""
echo "=== Step 4/6: Service with appProtocol: kubernetes.io/h2c ==="
sed "s/{{ namespace }}/$REQ_NS/g" "$MANIFESTS/03-service-grpc.yaml" | oc apply -f -
echo " ✓ Service req048-grpc-backend (appProtocol: kubernetes.io/h2c)"

# --- Step 5: Listener on the gateway ---
echo ""
echo "=== Step 5/6: Listener on the gateway ==="

EXISTING_LISTENER=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req048-grpc$" || echo "0")

if [ "$EXISTING_LISTENER" -gt 0 ]; then
  echo " ✓ Listener req048-grpc already exists on the gateway"
else
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' -p='[
    {"op":"add","path":"/spec/listeners/-","value":{
      "name":"req048-grpc",
      "hostname":"'"$HOST"'",
      "port":80,
      "protocol":"HTTP",
      "allowedRoutes":{"namespaces":{"from":"All"}}
    }}
  ]'
  echo " ✓ Listener req048-grpc added (hostname: $HOST)"
fi

# --- Step 6: AuthPolicy + HTTPRoute ---
echo ""
echo "=== Step 6/6: AuthPolicy + HTTPRoute ==="

cat <<EOF | oc apply -f -
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: req048-allow-public
  namespace: ${REQ_NS}
  labels:
    app.kubernetes.io/part-of: req048-grpc-backend
    rhcl.poc/item: "48"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: req048-grpc-route
  defaults:
    strategy: atomic
    rules:
      authorization:
        allow-all:
          opa:
            rego: |
              allow = true
EOF
echo " ✓ AuthPolicy req048-allow-public applied"

sed -e "s/{{ namespace }}/$REQ_NS/g" \
    -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ gateway_namespace }}/$GW_NS/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    "$MANIFESTS/04-httproute.yaml" | oc apply -f -
echo " ✓ HTTPRoute req048-grpc-route applied"

# --- Extra step: EnvoyFilter for gRPC streaming ---
# req026 installs a request-buffer filter across the whole gateway, which
# breaks gRPC reflection and streaming RPCs (the body never "completes").
# This EnvoyFilter disables the buffer only on the req048 vhosts.
echo ""
echo "=== Extra step: EnvoyFilter req048-grpc-streaming-no-buffer ==="
sed -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    -e "s/{{ hostname_grpcroute }}/$HOST_GRPCROUTE/g" \
    "$MANIFESTS/06-envoyfilter-grpc-streaming.yaml" | oc apply -f -
echo " ✓ EnvoyFilter applied (req026 request buffer disabled"
echo "   on the req048 vhosts — required for gRPC reflection/streaming)"

# --- Wait for acceptance ---
echo ""
echo " Waiting for the HTTPRoute to be accepted..."
sleep 5

ACCEPTED=$(oc -n "$REQ_NS" get httproute req048-grpc-route -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req048-grpc")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
if [ "$ACCEPTED" = "True" ]; then
  echo " ✓ HTTPRoute accepted by the gateway"
else
  echo " ⚠ HTTPRoute may not be accepted yet. Check:"
  echo "   oc -n $REQ_NS get httproute req048-grpc-route -o yaml"
fi

echo ""
echo "======================================================================"
echo " DEPLOYMENT COMPLETE"
echo "======================================================================"
echo ""
echo "What was created:"
echo "  Namespace: $REQ_NS"
echo "  Deployment: req048-banking-api (1 replica with gRPC enabled)"
echo "  Service: req048-grpc-backend (appProtocol: kubernetes.io/h2c)"
echo "  Listener: req048-grpc (gateway: $GW_NAME)"
echo "  HTTPRoute: req048-grpc-route"
echo "  AuthPolicy: req048-allow-public"
echo "  EnvoyFilter: req048-grpc-streaming-no-buffer (in $GW_NS)"
echo ""
echo "Hostname: $HOST"
echo ""
echo "Next steps:"
echo "  1. Validate: bash $SCRIPT_DIR/validate.sh"
echo "  2. Test native gRPC (unary):"
echo "     grpcurl -plaintext -d '{\"api_version\":\"v1\"}' \\"
echo "       $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
echo "  3. Test gRPC-Web:"
echo "     printf '\\x00\\x00\\x00\\x00\\x04\\x0a\\x02v1' | \\"
echo "       curl -sS -X POST --data-binary @- \\"
echo "         -H 'content-type: application/grpc-web+proto' \\"
echo "         -H 'x-grpc-web: true' \\"
echo "         \"http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary\" -i | head"
echo ""
