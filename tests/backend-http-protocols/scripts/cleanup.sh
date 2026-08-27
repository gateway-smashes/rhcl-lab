#!/usr/bin/env bash
# req054 — Limpeza: remove Services, HTTPRoute, AuthPolicy e listener
set -euo pipefail

echo "======================================================================"
echo " REQ 054 — Limpeza: HTTP/1.1 e HTTP/2 upstream"
echo "======================================================================"

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"
APPS_NS="rhcl-apps"
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "rhcl-apps-gateway")

echo ""
echo "Removendo AuthPolicy req054-allow-public..."
oc -n "$APPS_NS" delete authpolicy req054-allow-public --ignore-not-found
echo " ✓ Removido"

echo ""
echo "Removendo HTTPRoute req054-http-versions..."
oc -n "$APPS_NS" delete httproute req054-http-versions --ignore-not-found
echo " ✓ Removido"

echo ""
echo "Removendo Service req054-backend-http11..."
oc -n "$APPS_NS" delete svc req054-backend-http11 --ignore-not-found
echo " ✓ Removido"

echo ""
echo "Removendo Service req054-backend-h2c..."
oc -n "$APPS_NS" delete svc req054-backend-h2c --ignore-not-found
echo " ✓ Removido"

echo ""
echo "Removendo listener req054-http do gateway..."
LISTENER_INDEX=$(oc -n "$GW_NS" get gateway "$GW_NAME" \
  -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -n "^req054-http$" | cut -d: -f1 || echo "")

if [ -n "$LISTENER_INDEX" ]; then
  IDX=$((LISTENER_INDEX - 1))
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' \
    -p="[{\"op\":\"remove\",\"path\":\"/spec/listeners/$IDX\"}]"
  echo " ✓ Listener req054-http removed (index $IDX)"
else
  echo " (listener req054-http not found — already removed?)"
fi

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
echo ""
echo "Nota: Os pods banking-api-v1 (usados como backend) NÃO foram removidos."
echo " They are managed by the apps-install automation."
echo ""
