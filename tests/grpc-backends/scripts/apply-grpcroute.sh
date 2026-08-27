#!/usr/bin/env bash
# req048 — Exemplo complementar: roteamento gRPC via GRPCRoute (Gateway API v1)
# Requires the req048 base already applied (apply.sh): namespace, Deployment and Service.
# Adiciona listener dedicado req048-grpcroute ao gateway e aplica o GRPCRoute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " Complementary example: GRPCRoute (idiomatic gRPC routing)"
echo "======================================================================"

# --- Detectar hostname ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo " ✗ ERROR: Could not detect the cluster domain."
  echo "   Set the CLUSTER_DOMAIN variable manually:"
  echo "   export CLUSTER_DOMAIN=apps.ocp.xxx.example.com"
  exit 1
fi

HOST="req048-grpcroute.${CLUSTER_DOMAIN}"
REQ_NS="req048-grpc"
GW_NS="openshift-ingress"

echo ""
echo " Cluster domain: $CLUSTER_DOMAIN"
echo " Hostname GRPCRoute: $HOST"
echo " Namespace:          $REQ_NS"

# --- Prerequisites ---
echo ""
echo "[prereq] Checking GRPCRoute availability (Gateway API)..."
GRPC_CRD_VERSIONS=$(oc get crd grpcroutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null || echo "")
if echo "$GRPC_CRD_VERSIONS" | grep -qw "v1"; then
  echo " ✓ CRD grpcroutes.gateway.networking.k8s.io servido em v1 (GA)"
else
  echo " ✗ GRPCRoute v1 is NOT available on this cluster (served versions: '${GRPC_CRD_VERSIONS:-none}')."
  echo "   Use o exemplo com HTTPRoute (apply.sh), que atende o requisito 48."
  exit 1
fi

echo ""
echo "[prereq] Checking RHCL / Kuadrant..."
if oc get kuadrant -n kuadrant-system &>/dev/null; then
  echo " ✓ Kuadrant instalado"
else
  echo " ✗ Kuadrant NÃO encontrado em kuadrant-system."
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
echo "[prereq] Checking the req048 base (gRPC backend)..."
if ! oc get namespace "$REQ_NS" &>/dev/null || ! oc -n "$REQ_NS" get svc req048-grpc-backend &>/dev/null; then
  echo " ✗ req048 base not found (namespace/Service missing)."
  echo "   Execute primeiro: bash tests/grpc-backends/scripts/apply.sh"
  exit 1
fi
READY=$(oc -n "$REQ_NS" get deployment req048-banking-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${READY:-0}" -gt 0 ]; then
  echo " ✓ req048 base applied (backend with $READY Ready replica(s))"
else
  echo " ✗ Deployment req048-banking-api has no Ready replicas."
  echo "   Execute/aguarde: bash tests/grpc-backends/scripts/apply.sh"
  exit 1
fi

# --- Passo 1: Listener dedicado no gateway ---
echo ""
echo "=== Passo 1/3: Listener req048-grpcroute no gateway ==="

EXISTING_LISTENER=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req048-grpcroute$" || true)

if [ "${EXISTING_LISTENER:-0}" -gt 0 ]; then
  echo " ✓ Listener req048-grpcroute already exists on the gateway"
else
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' -p='[
    {"op":"add","path":"/spec/listeners/-","value":{
      "name":"req048-grpcroute",
      "hostname":"'"$HOST"'",
      "port":80,
      "protocol":"HTTP",
      "allowedRoutes":{"namespaces":{"from":"All"}}
    }}
  ]'
  echo " ✓ Listener req048-grpcroute adicionado (hostname: $HOST)"
fi

# --- Passo 2: GRPCRoute ---
echo ""
echo "=== Passo 2/3: GRPCRoute req048-grpcroute ==="
echo " Note: no AuthPolicy — in RHCL 1.3.5 Kuadrant policies cannot"
echo " targetear GRPCRoute e o enforcement (wasm-shim) deriva de HTTPRoutes."

sed -e "s/{{ namespace }}/$REQ_NS/g" \
    -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ gateway_namespace }}/$GW_NS/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    "$MANIFESTS/05-grpcroute.yaml" | oc apply -f -
echo " ✓ GRPCRoute req048-grpcroute aplicado"

# --- Passo 3: EnvoyFilter para streaming gRPC (idempotente com apply.sh) ---
# O req026 instala um filtro de buffer de request em todo o gateway, o que
# breaks gRPC reflection and streaming RPCs. Re-applies the EnvoyFilter that
# disables the buffer on the req048 vhosts (also covers this hostname).
echo ""
echo "=== Passo 3/3: EnvoyFilter req048-grpc-streaming-no-buffer ==="
sed -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ hostname }}/req048-grpc.${CLUSTER_DOMAIN}/g" \
    -e "s/{{ hostname_grpcroute }}/$HOST/g" \
    "$MANIFESTS/06-envoyfilter-grpc-streaming.yaml" | oc apply -f -
echo " ✓ EnvoyFilter aplicado (buffer desabilitado nos vhosts do req048)"

# --- Wait for acceptance ---
echo ""
echo " Aguardando GRPCRoute ser aceito..."
sleep 5

ACCEPTED=$(oc -n "$REQ_NS" get grpcroute req048-grpcroute -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req048-grpcroute")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
if [ "$ACCEPTED" = "True" ]; then
  echo " ✓ GRPCRoute aceito pelo gateway"
else
  echo " ⚠ GRPCRoute may not be accepted yet. Check:"
  echo "   oc -n $REQ_NS get grpcroute req048-grpcroute -o yaml"
fi

echo ""
echo "======================================================================"
echo " APLICAÇÃO CONCLUÍDA"
echo "======================================================================"
echo ""
echo "What was created (beyond the req048 base):"
echo "  Listener:  req048-grpcroute (gateway: $GW_NAME)"
echo "  GRPCRoute: req048-grpcroute (matching by gRPC service)"
echo ""
echo "Hostname GRPCRoute: $HOST"
echo "Hostname HTTPRoute: req048-grpc.${CLUSTER_DOMAIN} (continua ativo)"
echo ""
echo "Next steps:"
echo "  1. Validar: bash $SCRIPT_DIR/validate-grpcroute.sh"
echo "  2. Testar gRPC nativo (unary) via GRPCRoute:"
echo "     grpcurl -plaintext -d '{\"api_version\":\"v1\"}' \\"
echo "       $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
echo "  3. Testar server-streaming via GRPCRoute:"
echo "     grpcurl -plaintext -d '{\"interval_ms\":500,\"max_events\":3}' \\"
echo "       $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth"
echo ""
