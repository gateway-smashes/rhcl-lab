#!/usr/bin/env bash
# req038 — Remove todos os recursos criados para o teste de OpenTelemetry
# NOTA: o Istio CR (openshift-gateway) é infraestrutura pré-existente
# e NÃO é modificado nem excluído por este script.
set -euo pipefail

echo "======================================================================"
echo " REQ 038 — Limpeza dos recursos OpenTelemetry"
echo "======================================================================"

echo ""
echo "--- Kuadrant observability (restaurando sem tracing) ---"
oc -n kuadrant-system patch kuadrant kuadrant --type=json -p='[
  {"op": "remove", "path": "/spec/observability"}
]' 2>/dev/null && echo "  ✓ Removido spec.observability do Kuadrant" || echo "  - Nada a remover"

echo ""
echo "--- EnvoyFilter (tracing no gateway) ---"
oc -n openshift-ingress delete envoyfilter otel-tracing --ignore-not-found
echo "  ✓ EnvoyFilter removido"

echo ""
echo "--- OpenTelemetry Collector ---"
oc -n observability delete opentelemetrycollector otel-rhcl --ignore-not-found
echo "  ✓ Collector removido"

echo ""
echo "--- RBAC ---"
oc delete clusterrolebinding tempostack-traces-write --ignore-not-found
oc delete clusterrole tempostack-traces-write --ignore-not-found
oc delete clusterrolebinding otel-collector-k8s --ignore-not-found
oc delete clusterrole otel-collector-k8s --ignore-not-found
oc -n observability delete sa otel-collector --ignore-not-found
echo "  ✓ RBAC removido"

echo ""
echo "--- TempoStack ---"
oc -n tempo delete tempostack tempo-rhcl --ignore-not-found
echo "  ✓ TempoStack removido"

echo ""
echo "--- MinIO ---"
oc -n minio delete job minio-create-bucket --ignore-not-found
oc -n minio delete route minio-console --ignore-not-found
oc -n minio delete svc minio --ignore-not-found
oc -n minio delete deployment minio --ignore-not-found
oc -n minio delete pvc minio-data --ignore-not-found
oc -n minio delete secret minio-root --ignore-not-found
echo "  ✓ MinIO removido"

echo ""
echo "--- Namespaces ---"
echo "  Os namespaces minio, tempo e observability NÃO são removidos"
echo "  automaticamente. Para removê-los manualmente:"
echo "    oc delete namespace minio tempo observability"

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
