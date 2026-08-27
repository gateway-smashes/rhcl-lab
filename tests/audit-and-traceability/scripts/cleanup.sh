#!/usr/bin/env bash
# req066 — Cleanup: remove access-log EnvoyFilters
set -euo pipefail

echo "======================================================================"
echo " REQ 066 — Cleanup: audit and traceability"
echo "======================================================================"

echo ""
echo "Removing EnvoyFilter access-log-json..."
oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found
echo "  ✓ Removed"

echo ""
echo "Removing EnvoyFilter access-log-filter (if it exists)..."
oc -n openshift-ingress delete envoyfilter access-log-filter --ignore-not-found
echo "  ✓ Removed"

echo ""
echo "======================================================================"
echo " CLEANUP COMPLETE"
echo "======================================================================"
echo ""
echo "Note: the tracing infrastructure (Tempo, Collector, etc.) is"
echo "      managed by req038 and was NOT removed."
echo "      To remove everything: bash tests/opentelemetry-traces-metrics/scripts/cleanup.sh"
echo ""
