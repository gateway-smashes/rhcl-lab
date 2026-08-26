#!/usr/bin/env bash
# req048 — Comunicar com o backend das APIs via gRPC
# Cria namespace dedicado, deploy do banking-api com gRPC, Service h2c e HTTPRoute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 048 — Comunicar com o backend das APIs via gRPC"
echo "======================================================================"

# --- Detectar hostname ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo " ✗ ERRO: Não foi possível detectar o domínio do cluster."
  echo "   Defina a variável CLUSTER_DOMAIN manualmente:"
  echo "   export CLUSTER_DOMAIN=apps.ocp.xxx.sandboxNNNN.opentlc.com"
  exit 1
fi

HOST="req048-grpc.${CLUSTER_DOMAIN}"
HOST_GRPCROUTE="req048-grpcroute.${CLUSTER_DOMAIN}"
REQ_NS="req048-grpc"
GW_NS="openshift-ingress"
APPS_NS="rhcl-apps"

echo ""
echo " Domínio do cluster: $CLUSTER_DOMAIN"
echo " Hostname req048:    $HOST"
echo " Namespace:          $REQ_NS"

# --- Pré-requisitos ---
echo ""
echo "[pré-req] Verificando RHCL / Kuadrant..."
if oc get kuadrant -n kuadrant-system &>/dev/null; then
  echo " ✓ Kuadrant instalado"
else
  echo " ✗ Kuadrant NÃO encontrado em kuadrant-system."
  exit 1
fi

echo ""
echo "[pré-req] Detectando gateway do RHCL..."
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "")
if [ -n "$GW_NAME" ]; then
  echo " ✓ Gateway: $GW_NAME"
else
  echo " ✗ Gateway não encontrado em $GW_NS."
  exit 1
fi

echo ""
echo "[pré-req] Verificando ImageStream banking-api em $APPS_NS..."
if oc -n "$APPS_NS" get imagestream banking-api &>/dev/null; then
  echo " ✓ ImageStream banking-api existe em $APPS_NS"
else
  echo " ⚠ ImageStream banking-api não encontrado em $APPS_NS."
  echo "   O Deployment usará a referência direta ao registry interno."
fi

# --- Passo 1: Criar Namespace ---
echo ""
echo "=== Passo 1/6: Namespace $REQ_NS ==="
oc apply -f "$MANIFESTS/00-namespace.yaml"
echo " ✓ Namespace $REQ_NS criado/verificado"

# --- Passo 2: RoleBinding image-puller ---
echo ""
echo "=== Passo 2/6: RoleBinding image-puller ==="
oc apply -f "$MANIFESTS/01-rolebinding-image-pull.yaml"
echo " ✓ RoleBinding req048-image-puller em $APPS_NS"

# --- Passo 3: Deployment ---
echo ""
echo "=== Passo 3/6: Deployment banking-api (gRPC) ==="
sed "s/{{ namespace }}/$REQ_NS/g" "$MANIFESTS/02-deployment.yaml" | oc apply -f -
echo " ✓ Deployment req048-banking-api aplicado"

echo " Aguardando pod ficar Ready..."
oc -n "$REQ_NS" rollout status deployment/req048-banking-api --timeout=120s || {
  echo " ⚠ Timeout aguardando Deployment. Verifique os eventos:"
  echo "   oc -n $REQ_NS get events --sort-by=.lastTimestamp"
}

# --- Passo 4: Service com appProtocol h2c ---
echo ""
echo "=== Passo 4/6: Service com appProtocol: kubernetes.io/h2c ==="
sed "s/{{ namespace }}/$REQ_NS/g" "$MANIFESTS/03-service-grpc.yaml" | oc apply -f -
echo " ✓ Service req048-grpc-backend (appProtocol: kubernetes.io/h2c)"

# --- Passo 5: Listener no gateway ---
echo ""
echo "=== Passo 5/6: Listener no gateway ==="

EXISTING_LISTENER=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req048-grpc$" || echo "0")

if [ "$EXISTING_LISTENER" -gt 0 ]; then
  echo " ✓ Listener req048-grpc já existe no gateway"
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
  echo " ✓ Listener req048-grpc adicionado (hostname: $HOST)"
fi

# --- Passo 6: AuthPolicy + HTTPRoute ---
echo ""
echo "=== Passo 6/6: AuthPolicy + HTTPRoute ==="

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
echo " ✓ AuthPolicy req048-allow-public aplicado"

sed -e "s/{{ namespace }}/$REQ_NS/g" \
    -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ gateway_namespace }}/$GW_NS/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    "$MANIFESTS/04-httproute.yaml" | oc apply -f -
echo " ✓ HTTPRoute req048-grpc-route aplicado"

# --- Passo extra: EnvoyFilter para streaming gRPC ---
# O req026 instala um filtro de buffer de request em todo o gateway, o que
# quebra reflexão gRPC e RPCs de streaming (o corpo nunca "completa").
# Este EnvoyFilter desabilita o buffer apenas nos vhosts do req048.
echo ""
echo "=== Passo extra: EnvoyFilter req048-grpc-streaming-no-buffer ==="
sed -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    -e "s/{{ hostname_grpcroute }}/$HOST_GRPCROUTE/g" \
    "$MANIFESTS/06-envoyfilter-grpc-streaming.yaml" | oc apply -f -
echo " ✓ EnvoyFilter aplicado (buffer de request do req026 desabilitado"
echo "   nos vhosts do req048 — necessário para reflexão/streaming gRPC)"

# --- Aguardar aceitação ---
echo ""
echo " Aguardando HTTPRoute ser aceito..."
sleep 5

ACCEPTED=$(oc -n "$REQ_NS" get httproute req048-grpc-route -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req048-grpc")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
if [ "$ACCEPTED" = "True" ]; then
  echo " ✓ HTTPRoute aceito pelo gateway"
else
  echo " ⚠ HTTPRoute pode não estar aceito ainda. Verifique:"
  echo "   oc -n $REQ_NS get httproute req048-grpc-route -o yaml"
fi

echo ""
echo "======================================================================"
echo " APLICAÇÃO CONCLUÍDA"
echo "======================================================================"
echo ""
echo "O que foi criado:"
echo "  Namespace: $REQ_NS"
echo "  Deployment: req048-banking-api (1 réplica com gRPC habilitado)"
echo "  Service: req048-grpc-backend (appProtocol: kubernetes.io/h2c)"
echo "  Listener: req048-grpc (gateway: $GW_NAME)"
echo "  HTTPRoute: req048-grpc-route"
echo "  AuthPolicy: req048-allow-public"
echo "  EnvoyFilter: req048-grpc-streaming-no-buffer (em $GW_NS)"
echo ""
echo "Hostname: $HOST"
echo ""
echo "Próximos passos:"
echo "  1. Validar: bash $SCRIPT_DIR/validate.sh"
echo "  2. Testar gRPC nativo (unary):"
echo "     grpcurl -plaintext -d '{\"api_version\":\"v1\"}' \\"
echo "       $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
echo "  3. Testar gRPC-Web:"
echo "     printf '\\x00\\x00\\x00\\x00\\x04\\x0a\\x02v1' | \\"
echo "       curl -sS -X POST --data-binary @- \\"
echo "         -H 'content-type: application/grpc-web+proto' \\"
echo "         -H 'x-grpc-web: true' \\"
echo "         \"http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary\" -i | head"
echo ""
