#!/usr/bin/env bash
# Validation of the OpenTelemetry observability stack
set -euo pipefail

OK=0
WARN=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo "  ✓ $label"
    OK=$((OK + 1))
  else
    echo "  ✗ $label"
    FAIL=$((FAIL + 1))
  fi
}

warn_check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo "  ✓ $label"
    OK=$((OK + 1))
  else
    echo "  ⚠ $label"
    WARN=$((WARN + 1))
  fi
}

echo "======================================================================"
echo " OpenTelemetry stack validation"
echo "======================================================================"

# --- MinIO ---
echo ""
echo "--- MinIO ---"
check "Namespace minio existe" oc get namespace minio
check "Deployment minio available" oc -n minio get deployment minio
check "Service minio reachable" oc -n minio get svc minio
warn_check "Job minio-create-bucket completou" \
  oc -n minio get job minio-create-bucket -o jsonpath='{.status.succeeded}'

# --- Tempo ---
echo ""
echo "--- TempoStack ---"
check "Namespace tempo existe" oc get namespace tempo
check "TempoStack tempo-rhcl existe" oc -n tempo get tempostack tempo-rhcl
TEMPO_READY=$(oc -n tempo get tempostack tempo-rhcl -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "$TEMPO_READY" = "True" ]; then
  echo "  ✓ TempoStack Ready=True"
  OK=$((OK + 1))
else
  echo "  ✗ TempoStack Ready=$TEMPO_READY (esperado: True)"
  FAIL=$((FAIL + 1))
fi
warn_check "Pods do Tempo rodando" \
  oc -n tempo get pods --field-selector=status.phase=Running --no-headers

# --- RBAC ---
echo ""
echo "--- RBAC ---"
check "Namespace observability existe" oc get namespace observability
check "ServiceAccount otel-collector existe" oc -n observability get sa otel-collector
check "ClusterRole otel-collector-k8s existe" oc get clusterrole otel-collector-k8s
check "ClusterRoleBinding otel-collector-k8s existe" oc get clusterrolebinding otel-collector-k8s
check "ClusterRole tempostack-traces-write existe" oc get clusterrole tempostack-traces-write
check "ClusterRoleBinding tempostack-traces-write existe" oc get clusterrolebinding tempostack-traces-write

# --- OpenTelemetry Collector ---
echo ""
echo "--- OpenTelemetry Collector ---"
check "OpenTelemetryCollector otel-rhcl existe" oc -n observability get opentelemetrycollector otel-rhcl
warn_check "Collector pods rodando" \
  oc -n observability get pods --field-selector=status.phase=Running --no-headers

# --- EnvoyFilter (tracing no gateway) ---
echo ""
echo "--- EnvoyFilter (tracing no gateway) ---"
check "EnvoyFilter otel-tracing existe" oc -n openshift-ingress get envoyfilter otel-tracing

TRACER=$(oc -n openshift-ingress exec deploy/rhcl-apps-gateway-openshift-default -c istio-proxy -- \
  pilot-agent request GET config_dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for cfg in d.get('configs',[]):
    if 'listeners' in cfg.get('@type','').lower():
        for l in cfg.get('dynamic_listeners',[]):
            active=l.get('active_state',{}).get('listener',{})
            for fc in active.get('filter_chains',[])[:1]:
                for f in fc.get('filters',[]):
                    tc=f.get('typed_config',{})
                    prov=tc.get('tracing',{}).get('provider',{}).get('name','')
                    if prov:
                        print(prov)
                        sys.exit(0)
" 2>/dev/null || echo "")

if [ "$TRACER" = "envoy.tracers.opentelemetry" ]; then
  echo "  ✓ Envoy tracer: envoy.tracers.opentelemetry"
  OK=$((OK + 1))
else
  echo "  ✗ Envoy tracer: $TRACER (esperado: envoy.tracers.opentelemetry)"
  FAIL=$((FAIL + 1))
fi

# --- Kuadrant ---
echo ""
echo "--- Kuadrant observability ---"
check "Kuadrant CR existe" oc -n kuadrant-system get kuadrant kuadrant

OBS_ENABLED=$(oc -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.spec.observability.enable}' 2>/dev/null || echo "")
if [ "$OBS_ENABLED" = "true" ]; then
  echo "  ✓ observability.enable=true"
  OK=$((OK + 1))
else
  echo "  ✗ observability.enable=$OBS_ENABLED (esperado: true)"
  FAIL=$((FAIL + 1))
fi

TRACING_EP=$(oc -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.spec.observability.tracing.defaultEndpoint}' 2>/dev/null || echo "")
if [ -n "$TRACING_EP" ]; then
  echo "  ✓ tracing.defaultEndpoint=$TRACING_EP"
  OK=$((OK + 1))
else
  echo "  ✗ tracing.defaultEndpoint not configured"
  FAIL=$((FAIL + 1))
fi

warn_check "ServiceMonitors do Kuadrant existem" \
  oc get servicemonitor -A -l kuadrant.io/observability=true --no-headers

# --- Resumo ---
echo ""
echo "======================================================================"
echo " RESULTADO: $OK ok / $WARN avisos / $FAIL falhas"
echo "======================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo " There are failures to fix before demonstrating the lab."
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo " There are warnings. Check whether they are acceptable for the demo."
  exit 0
else
  echo " Everything is ready to demo!"
  exit 0
fi
