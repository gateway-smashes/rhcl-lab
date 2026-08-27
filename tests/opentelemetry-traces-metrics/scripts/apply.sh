#!/usr/bin/env bash
# Expose traces and metrics in the OpenTelemetry standards
# Aplica todos os manifests na ordem correta com waits entre passos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="$SCRIPT_DIR/../manifests"

echo "======================================================================"
echo " OpenTelemetry: traces and metrics for RHCL"
echo "======================================================================"

# --- Prerequisites ---
echo ""
echo "[prereq] Checking installed operators..."
for op in openshift-tempo-operator openshift-opentelemetry-operator; do
  if oc get namespace "$op" &>/dev/null; then
    echo "  ✓ Namespace $op existe"
  else
    echo "  ✗ Namespace $op NÃO encontrado. Instale o operator correspondente."
    exit 1
  fi
done

echo ""
echo "[prereq] Checking the Sail Operator (Service Mesh 3)..."
if oc get crd istios.sailoperator.io &>/dev/null; then
  echo "  ✓ CRD istios.sailoperator.io available"
else
  echo "  ✗ CRD istios.sailoperator.io NÃO encontrado."
  echo "    Instale o OpenShift Service Mesh 3 (Sail Operator)."
  exit 1
fi

echo ""
echo "[prereq] Detecting the RHCL gateway..."
GW_NS=$(oc get gateways.gateway.networking.k8s.io -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | head -1 || echo "openshift-ingress")
echo "  ✓ Gateway namespace: $GW_NS"

# --- Passo 1: MinIO ---
echo ""
echo "=== Passo 1/6: MinIO (object storage para Tempo) ==="
oc apply -f "$MANIFESTS/01-minio.yaml"
echo "Aguardando MinIO ficar pronto..."
oc -n minio rollout status deployment/minio --timeout=120s
echo "Waiting for the bucket-creation job (up to 90s)..."
oc -n minio wait job/minio-create-bucket --for=condition=complete --timeout=90s || \
  echo "  ⚠ Job has not completed yet. Check: oc -n minio logs job/minio-create-bucket"

# --- Passo 2: TempoStack ---
echo ""
echo "=== Passo 2/6: TempoStack ==="
oc apply -f "$MANIFESTS/02-tempostack.yaml"
echo "Waiting for the TempoStack to reconcile (up to 180s)..."
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
echo "Next steps:"
echo "  1. Validar:  bash $SCRIPT_DIR/validate.sh"
echo "  2. Generate traffic to the API published by the Gateway/HTTPRoute"
echo "  3. Verificar traces no Tempo/Jaeger UI"
echo "  4. Check metrics in Prometheus/Grafana"
echo ""
