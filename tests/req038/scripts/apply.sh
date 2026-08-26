#!/usr/bin/env bash
# req038 — Expor trace e métricas nos padrões OpenTelemetry
# Aplica todos os manifests na ordem correta com waits entre passos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " REQ 038 — OpenTelemetry: traces e métricas para RHCL"
echo "======================================================================"

# --- Pré-requisitos ---
echo ""
echo "[pré-req] Verificando operators instalados..."
for op in openshift-tempo-operator openshift-opentelemetry-operator; do
  if oc get namespace "$op" &>/dev/null; then
    echo "  ✓ Namespace $op existe"
  else
    echo "  ✗ Namespace $op NÃO encontrado. Instale o operator correspondente."
    exit 1
  fi
done

echo ""
echo "[pré-req] Verificando Sail Operator (Service Mesh 3)..."
if oc get crd istios.sailoperator.io &>/dev/null; then
  echo "  ✓ CRD istios.sailoperator.io disponível"
else
  echo "  ✗ CRD istios.sailoperator.io NÃO encontrado."
  echo "    Instale o OpenShift Service Mesh 3 (Sail Operator)."
  exit 1
fi

echo ""
echo "[pré-req] Detectando gateway do RHCL..."
GW_NS=$(oc get gateways.gateway.networking.k8s.io -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1 || echo "openshift-ingress")
echo "  ✓ Gateway namespace: $GW_NS"

# --- Passo 1: MinIO ---
echo ""
echo "=== Passo 1/6: MinIO (object storage para Tempo) ==="
oc apply -f "$MANIFESTS/01-minio.yaml"
echo "Aguardando MinIO ficar pronto..."
oc -n minio rollout status deployment/minio --timeout=120s
echo "Aguardando job de criação do bucket (até 90s)..."
oc -n minio wait job/minio-create-bucket --for=condition=complete --timeout=90s || \
  echo "  ⚠ Job ainda não completou. Verifique: oc -n minio logs job/minio-create-bucket"

# --- Passo 2: TempoStack ---
echo ""
echo "=== Passo 2/6: TempoStack ==="
oc apply -f "$MANIFESTS/02-tempostack.yaml"
echo "Aguardando TempoStack reconciliar (até 180s)..."
for i in $(seq 1 36); do
  STATUS=$(oc -n tempo get tempostack tempo-rhcl -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$STATUS" = "True" ]; then
    echo "  ✓ TempoStack pronto"
    break
  fi
  echo "  Aguardando... ($((i*5))s)"
  sleep 5
done

# --- Passo 3: RBAC ---
echo ""
echo "=== Passo 3/6: RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding) ==="
oc apply -f "$MANIFESTS/03-rbac.yaml"
echo "  ✓ RBAC aplicado"

# --- Passo 4: OpenTelemetry Collector ---
echo ""
echo "=== Passo 4/6: OpenTelemetryCollector ==="
oc apply -f "$MANIFESTS/04-opentelemetry.yaml"
echo "Aguardando Collector ficar pronto..."
sleep 5
oc -n observability rollout status deployment/otel-rhcl-collector --timeout=120s 2>/dev/null || \
  echo "  ⚠ Collector pode demorar. Verifique: oc -n observability get pods"

# --- Passo 5: EnvoyFilter — tracing OpenTelemetry no gateway ---
echo ""
echo "=== Passo 5/6: EnvoyFilter — tracing OpenTelemetry no gateway ==="
oc apply -f "$MANIFESTS/05-envoyfilter-otel-tracing.yaml"
echo "  ✓ EnvoyFilter aplicado em $GW_NS"

# --- Passo 6: Kuadrant observability ---
echo ""
echo "=== Passo 6/6: Kuadrant — observability e tracing ==="
echo "  Aplicando patch no CR Kuadrant (preserva campos existentes)..."
oc -n kuadrant-system patch kuadrant kuadrant --type=merge -p '{
  "spec": {
    "observability": {
      "enable": true,
      "dataPlane": {
        "defaultLevels": [{"debug": "true"}],
        "httpHeaderIdentifier": "x-request-id"
      },
      "tracing": {
        "defaultEndpoint": "rpc://otel-rhcl-collector.observability.svc.cluster.local:4317",
        "insecure": true
      }
    }
  }
}'
echo "  ✓ Kuadrant observability configurada"

echo ""
echo "======================================================================"
echo " APLICAÇÃO CONCLUÍDA"
echo "======================================================================"
echo ""
echo "Resumo:"
echo "  Gateway:     $GW_NS (tracing via EnvoyFilter)"
echo "  Collector:   otel-rhcl-collector.observability.svc.cluster.local:4317"
echo "  Tempo:       tempo-rhcl (namespace: tempo)"
echo "  Kuadrant:    observability habilitada"
echo ""
echo "Próximos passos:"
echo "  1. Validar:  bash $SCRIPT_DIR/validate.sh"
echo "  2. Gerar tráfego para a API publicada pelo Gateway/HTTPRoute"
echo "  3. Verificar traces no Tempo/Jaeger UI"
echo "  4. Verificar métricas no Prometheus/Grafana"
echo ""
