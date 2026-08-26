#!/usr/bin/env bash
# req048 — Limpeza do exemplo GRPCRoute (mantém o exemplo HTTPRoute intacto)
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
  echo " (namespace $REQ_NS não encontrado — GRPCRoute já removido?)"
echo " ✓ GRPCRoute removido"

echo ""
echo "Removendo listener req048-grpcroute do gateway..."
LISTENER_INDEX=$(oc -n "$GW_NS" get gateway "$GW_NAME" \
  -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -n "^req048-grpcroute$" | cut -d: -f1 || echo "")

if [ -n "$LISTENER_INDEX" ]; then
  IDX=$((LISTENER_INDEX - 1))
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' \
    -p="[{\"op\":\"remove\",\"path\":\"/spec/listeners/$IDX\"}]"
  echo " ✓ Listener req048-grpcroute removido (índice $IDX)"
else
  echo " (listener req048-grpcroute não encontrado — já removido?)"
fi

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
echo ""
echo "O exemplo com HTTPRoute do req048 permanece ativo (namespace,"
echo "Deployment, Service, HTTPRoute, AuthPolicy e listener req048-grpc)."
echo "Para remover tudo do req048: bash tests/req048/scripts/cleanup.sh"
echo ""
