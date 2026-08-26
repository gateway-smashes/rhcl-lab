#!/usr/bin/env bash
# req054 — Consumir backends em HTTP/1.1, HTTP/2 e HTTP/3
# Aplica os Services com appProtocol diferente e o HTTPRoute no gateway RHCL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 054 — Consumir backends em HTTP/1.1 e HTTP/2"
echo "======================================================================"

# --- Detectar hostname ---
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")}"

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo " ✗ ERRO: Não foi possível detectar o domínio do cluster."
  echo "   Defina a variável CLUSTER_DOMAIN manualmente:"
  echo "   export CLUSTER_DOMAIN=apps.ocp.xxx.sandboxNNNN.opentlc.com"
  exit 1
fi

HOST="req054-backend.${CLUSTER_DOMAIN}"
echo ""
echo " Domínio do cluster: $CLUSTER_DOMAIN"
echo " Hostname req054:    $HOST"

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
GW_NAME=$(oc -n openshift-ingress get gateway -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | head -1 || echo "")
if [ -n "$GW_NAME" ]; then
  echo " ✓ Gateway: $GW_NAME"
else
  echo " ✗ Gateway não encontrado em openshift-ingress."
  exit 1
fi

GW_NS="openshift-ingress"
APPS_NS="rhcl-apps"

echo ""
echo "[pré-req] Verificando namespace $APPS_NS..."
if oc get namespace "$APPS_NS" &>/dev/null; then
  echo " ✓ Namespace $APPS_NS existe"
else
  echo " ✗ Namespace $APPS_NS não encontrado. Execute a automação apps-install primeiro."
  exit 1
fi

echo ""
echo "[pré-req] Verificando pods banking-api-v1..."
POD_COUNT=$(oc -n "$APPS_NS" get pods -l app=banking-api-v1 --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ "$POD_COUNT" -gt 0 ]; then
  echo " ✓ banking-api-v1: $POD_COUNT pod(s) Running"
else
  echo " ⚠ banking-api-v1 não encontrado com pods Running."
  echo "   Os Services req054 apontarão para pods banking-api-v1."
fi

# --- Passo 1: Aplicar Services ---
echo ""
echo "=== Passo 1/4: Services com appProtocol diferente ==="

sed "s/{{ apps_namespace }}/$APPS_NS/g" "$MANIFESTS/service-http11.yaml" | oc apply -f -
echo " ✓ Service req054-backend-http11 (sem appProtocol → HTTP/1.1 upstream)"

sed "s/{{ apps_namespace }}/$APPS_NS/g" "$MANIFESTS/service-http2.yaml" | oc apply -f -
echo " ✓ Service req054-backend-h2c (appProtocol: kubernetes.io/h2c → HTTP/2 upstream)"

# --- Passo 2: Adicionar listener ao gateway ---
echo ""
echo "=== Passo 2/4: Listener no gateway ==="

EXISTING_LISTENER=$(oc -n "$GW_NS" get gateway "$GW_NAME" -o jsonpath='{.spec.listeners[*].name}' 2>/dev/null | tr ' ' '\n' | grep -c "^req054-http$" || echo "0")

if [ "$EXISTING_LISTENER" -gt 0 ]; then
  echo " ✓ Listener req054-http já existe no gateway"
else
  oc patch gateway "$GW_NAME" -n "$GW_NS" --type='json' -p='[
    {"op":"add","path":"/spec/listeners/-","value":{
      "name":"req054-http",
      "hostname":"'"$HOST"'",
      "port":80,
      "protocol":"HTTP",
      "allowedRoutes":{"namespaces":{"from":"All"}}
    }}
  ]'
  echo " ✓ Listener req054-http adicionado (hostname: $HOST)"
fi

# --- Passo 3: Aplicar AuthPolicy (allow) ---
echo ""
echo "=== Passo 3/4: AuthPolicy (allow público) ==="

cat <<EOF | oc apply -f -
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: req054-allow-public
  namespace: ${APPS_NS}
  labels:
    app.kubernetes.io/part-of: req054-http-versions
    rhcl.poc/item: "54"
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: req054-http-versions
  defaults:
    strategy: atomic
    rules:
      authorization:
        allow-all:
          opa:
            rego: |
              allow = true
EOF
echo " ✓ AuthPolicy req054-allow-public aplicado"

# --- Passo 4: Aplicar HTTPRoute ---
echo ""
echo "=== Passo 4/4: HTTPRoute ==="

sed -e "s/{{ apps_namespace }}/$APPS_NS/g" \
    -e "s/{{ gateway_name }}/$GW_NAME/g" \
    -e "s/{{ gateway_namespace }}/$GW_NS/g" \
    -e "s/{{ hostname }}/$HOST/g" \
    "$MANIFESTS/httproute.yaml" | oc apply -f -
echo " ✓ HTTPRoute req054-http-versions aplicado"

# --- Aguardar aceitação ---
echo ""
echo " Aguardando HTTPRoute ser aceito..."
sleep 5

ACCEPTED=$(oc -n "$APPS_NS" get httproute req054-http-versions -o jsonpath='{.status.parents[?(@.parentRef.sectionName=="req054-http")].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
if [ "$ACCEPTED" = "True" ]; then
  echo " ✓ HTTPRoute aceito pelo gateway"
else
  echo " ⚠ HTTPRoute pode não estar aceito ainda. Verifique:"
  echo "   oc -n $APPS_NS get httproute req054-http-versions -o yaml"
fi

echo ""
echo "======================================================================"
echo " APLICAÇÃO CONCLUÍDA"
echo "======================================================================"
echo ""
echo "O que foi criado:"
echo "  Services:"
echo "    - req054-backend-http11 (namespace: $APPS_NS) — sem appProtocol"
echo "    - req054-backend-h2c    (namespace: $APPS_NS) — appProtocol: kubernetes.io/h2c"
echo "  Listener: req054-http (gateway: $GW_NAME)"
echo "  HTTPRoute: req054-http-versions (namespace: $APPS_NS)"
echo "  AuthPolicy: req054-allow-public (namespace: $APPS_NS)"
echo ""
echo "Hostname: $HOST"
echo ""
echo "Próximos passos:"
echo "  1. Validar: bash $SCRIPT_DIR/validate.sh"
echo "  2. Testar HTTP/1.1:"
echo "     curl -sv http://$HOST/http11/api/v1/accounts/summary 2>&1 | head -20"
echo "  3. Testar HTTP/2 (h2c upstream):"
echo "     curl -sv http://$HOST/h2/api/v1/accounts/summary 2>&1 | head -20"
echo ""
