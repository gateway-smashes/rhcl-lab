#!/usr/bin/env bash
# req066 — Auditoria e rastreabilidade de chamadas
# Aplica o EnvoyFilter de access log JSON no gateway RHCL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 066 — Auditoria e rastreabilidade de chamadas"
echo "======================================================================"

# --- Pré-requisitos ---
echo ""
echo "[pré-req] Verificando RHCL / Kuadrant..."
if oc get kuadrant -n kuadrant-system &>/dev/null; then
  echo "  ✓ Kuadrant instalado"
else
  echo "  ✗ Kuadrant NÃO encontrado em kuadrant-system."
  exit 1
fi

echo ""
echo "[pré-req] Detectando gateway do RHCL..."
GW_DEPLOY=$(oc -n openshift-ingress get deploy -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || echo "")
if [ -n "$GW_DEPLOY" ]; then
  echo "  ✓ Gateway deployment: $GW_DEPLOY"
else
  echo "  ⚠ Gateway deployment não encontrado automaticamente."
  GW_DEPLOY="rhcl-apps-gateway-openshift-default"
  echo "    Usando default: $GW_DEPLOY"
fi

echo ""
echo "[pré-req] Verificando stack de tracing (req038)..."
if oc -n observability get opentelemetrycollector otel-rhcl &>/dev/null; then
  echo "  ✓ OpenTelemetryCollector otel-rhcl encontrado (correlação trace completa)"
else
  echo "  ⚠ Stack de tracing (req038) NÃO encontrado."
  echo "    Access logs funcionam sem ele, mas correlação com traces será limitada."
  echo "    Para stack completo: bash tests/req038/scripts/apply.sh"
fi

# --- Passo 1: Remover EnvoyFilter antigo (se existir com annotation desatualizada) ---
echo ""
echo "=== Passo 1/2: Limpeza de EnvoyFilter anterior ==="
if oc -n openshift-ingress get envoyfilter access-log-json &>/dev/null; then
  echo "  Removendo EnvoyFilter anterior para re-apply limpo..."
  oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found
  sleep 2
  echo "  ✓ EnvoyFilter anterior removido"
else
  echo "  (nenhum EnvoyFilter anterior encontrado)"
fi

# --- Passo 2: Aplicar EnvoyFilter access log JSON ---
echo ""
echo "=== Passo 2/2: EnvoyFilter — access log JSON para auditoria ==="
oc apply -f "$MANIFESTS/01-envoyfilter-access-log-json.yaml"
echo "  ✓ EnvoyFilter access-log-json aplicado"

echo ""
echo "  Aguardando Envoy recarregar via xDS (5s)..."
sleep 5

# Verificar se o Envoy aceitou a configuração (sem erros de rejeição)
REJECT_COUNT=$(oc -n openshift-ingress logs "deploy/$GW_DEPLOY" \
  -c istio-proxy --tail=10 --since=10s 2>/dev/null | \
  grep -c "rejected\|Not supported field" 2>/dev/null || echo "0")

if [ "$REJECT_COUNT" -gt 0 ]; then
  echo "  ✗ ERRO: Envoy rejeitou a configuração!"
  echo "    Verifique: oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=10"
  exit 1
else
  echo "  ✓ Nenhum erro de rejeição detectado"
fi

echo ""
echo "======================================================================"
echo " APLICAÇÃO CONCLUÍDA"
echo "======================================================================"
echo ""
echo "O que foi criado:"
echo "  EnvoyFilter:  access-log-json (namespace: openshift-ingress)"
echo "  Função:       Access log JSON com campos de auditoria no stdout do gateway"
echo "  Campos novos: consumer_id, auth_reason, flow_trace_id, traceparent, TLS info"
echo ""
echo "ONDE VER A EVIDÊNCIA:"
echo "  oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=10"
echo "  (NÃO é no Observe → Traces — isso é funcionalidade do req038)"
echo ""
echo "Próximos passos:"
echo "  1. Validar:  bash $SCRIPT_DIR/validate.sh"
echo "  2. Gerar request autenticado:"
echo "     curl -sk -H 'x-flow-trace-id: audit-001' -H 'api-key: alice-gold-secret' \\"
echo "       https://banking-api.poc.rhcl.com.br/api/v1/echo"
echo "  3. Ver access log JSON:"
echo "     oc -n openshift-ingress logs deploy/$GW_DEPLOY -c istio-proxy --tail=20 | grep audit-001"
echo ""
