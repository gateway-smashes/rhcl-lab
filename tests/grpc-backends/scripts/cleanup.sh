#!/usr/bin/env bash
# req048 — Limpeza: remove namespace, listener e RoleBinding
set -euo pipefail

echo "======================================================================"
echo " REQ 048 — Limpeza: gRPC backend"
echo "======================================================================"

REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
APPS_NS="rhcl-apps"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "Removendo listeners req048-grpc e req048-grpcroute do gateway..."
for LISTENER in req048-grpcroute req048-grpc; do
  LISTENER_INDEX=$(oc -n "$GW_NS" get gateway "$GW_NAME" \
    -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -n "^${LISTENER}$" | cut -d: -f1 || echo "")

  if [ -n "$LISTENER_INDEX" ]; then
    IDX=$((LISTENER_INDEX - 1))
    oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' \
      -p="[{\"op\":\"remove\",\"path\":\"/spec/listeners/$IDX\"}]"
    echo " ✓ Listener $LISTENER removed (index $IDX)"
  else
    echo " (listener $LISTENER not found — already removed?)"
  fi
done

echo ""
echo "Removendo EnvoyFilter req048-grpc-streaming-no-buffer..."
oc -n "$GW_NS" delete envoyfilter req048-grpc-streaming-no-buffer --ignore-not-found
echo " ✓ EnvoyFilter removido"

echo ""
echo "Removendo namespace $REQ_NS (inclui Deployment, Service, HTTPRoute, GRPCRoute, AuthPolicy)..."
oc delete namespace "$REQ_NS" --ignore-not-found --wait=false
echo " ✓ Namespace $REQ_NS marked for removal"

echo ""
echo "Removendo RoleBinding req048-image-puller em $APPS_NS..."
oc -n "$APPS_NS" delete rolebinding req048-image-puller --ignore-not-found
echo " ✓ RoleBinding removido"

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
echo ""
echo "Note: namespace removal can take a few seconds to finish."
echo "      Verifique com: oc get namespace $REQ_NS"
echo ""
