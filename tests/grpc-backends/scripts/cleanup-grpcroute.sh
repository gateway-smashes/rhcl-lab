#!/usr/bin/env bash
# Cleanup of the GRPCRoute example (keeps the HTTPRoute example intact)
set -euo pipefail

echo "======================================================================"
echo " REQ 048 — Limpeza: exemplo GRPCRoute"
echo "======================================================================"

REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "Removendo GRPCRoute req048-grpcroute..."
oc -n "$REQ_NS" delete grpcroute req048-grpcroute --ignore-not-found 2>/dev/null || \
  echo " (namespace $REQ_NS not found — GRPCRoute already removed?)"
echo " ✓ GRPCRoute removido"

echo ""
echo "Removendo listener req048-grpcroute do gateway..."
LISTENER_INDEX=$(oc -n "$GW_NS" get gateway "$GW_NAME" \
  -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -n "^req048-grpcroute$" | cut -d: -f1 || echo "")

if [ -n "$LISTENER_INDEX" ]; then
  IDX=$((LISTENER_INDEX - 1))
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' \
    -p="[{\"op\":\"remove\",\"path\":\"/spec/listeners/$IDX\"}]"
  echo " ✓ Listener req048-grpcroute removed (index $IDX)"
else
  echo " (listener req048-grpcroute not found — already removed?)"
fi

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
echo ""
echo "O exemplo com HTTPRoute do req048 permanece ativo (namespace,"
echo "Deployment, Service, HTTPRoute, AuthPolicy e listener req048-grpc)."
echo "Para remover tudo do req048: bash tests/grpc-backends/scripts/cleanup.sh"
echo ""
