#!/usr/bin/env bash
# req066 — Limpeza: remove EnvoyFilters de access log
set -euo pipefail

echo "======================================================================"
echo " REQ 066 — Limpeza: auditoria e rastreabilidade"
echo "======================================================================"

echo ""
echo "Removendo EnvoyFilter access-log-json..."
oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found
echo "  ✓ Removido"

echo ""
echo "Removendo EnvoyFilter access-log-filter (se existir)..."
oc -n openshift-ingress delete envoyfilter access-log-filter --ignore-not-found
echo "  ✓ Removido"

echo ""
echo "======================================================================"
echo " LIMPEZA CONCLUÍDA"
echo "======================================================================"
echo ""
echo "Note: the tracing infrastructure (Tempo, Collector, etc.) is"
echo "      gerenciada pelo req038 e NÃO foi removida."
echo "      Para remover tudo: bash tests/opentelemetry-traces-metrics/scripts/cleanup.sh"
echo ""
