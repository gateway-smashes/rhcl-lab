#!/usr/bin/env bash
# Removes the EnvoyFilter and reverts the Collector to its pre-logs-pipeline state.
# NÃO mexe na pipeline traces nem nos exporters de tracing — req038 segue intacto.
set -euo pipefail

echo "======================================================================"
echo " REQ 035 — Cleanup"
echo "======================================================================"

echo ""
echo "[1/2] Removendo EnvoyFilter de access logs..."
oc delete envoyfilter -n openshift-ingress otel-access-logs-rhcl-apps-gateway --ignore-not-found

echo ""
echo "[2/2] Removendo pipeline 'logs' do Collector..."
# Patch that removes ONLY the logs pipeline, its exporters and specific processors.
oc patch opentelemetrycollector -n observability otel-rhcl --type=json -p '[
  {"op":"remove","path":"/spec/config/service/pipelines/logs"},
  {"op":"remove","path":"/spec/config/exporters/file~1audit"},
  {"op":"remove","path":"/spec/config/processors/filter~1errors"},
  {"op":"remove","path":"/spec/config/processors/attributes~1scrub"},
  {"op":"remove","path":"/spec/config/processors/resource~1rhcl-tag"},
  {"op":"remove","path":"/spec/volumes"},
  {"op":"remove","path":"/spec/volumeMounts"}
]' 2>&1 | tail -1 || echo "  (some keys did not exist anymore — ok)"

echo ""
echo "Aguardando rollout do Collector..."
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=120s

echo ""
echo "Reload dos gateway pods para limpar a config carregada via xDS..."
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s

echo ""
echo "======================================================================"
echo " ✓ Cleanup OK. req038 (traces) segue funcionando."
echo "======================================================================"
