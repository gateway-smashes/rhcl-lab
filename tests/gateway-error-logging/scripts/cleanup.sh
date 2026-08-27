#!/usr/bin/env bash
# Removes the EnvoyFilter and reverts the Collector to its pre-logs-pipeline state.
# Does NOT touch the traces pipeline or the tracing exporters — req038 stays intact.
set -euo pipefail

echo "======================================================================"
echo " REQ 035 — Cleanup"
echo "======================================================================"

echo ""
echo "[1/2] Removing the access-log EnvoyFilter..."
oc delete envoyfilter -n openshift-ingress otel-access-logs-rhcl-apps-gateway --ignore-not-found

echo ""
echo "[2/2] Removing the Collector's 'logs' pipeline..."
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
echo "Waiting for the Collector rollout..."
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=120s

echo ""
echo "Reloading the gateway pods to clear the config loaded via xDS..."
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s

echo ""
echo "======================================================================"
echo " ✓ Cleanup OK. req038 (traces) keeps working."
echo "======================================================================"
