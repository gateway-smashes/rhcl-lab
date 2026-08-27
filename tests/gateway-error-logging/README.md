---
title: Gateway error logging
summary: "Runbook: log every request that errors at the gateway."
category: Observability & audit
status: done
---

# Gateway error logging

Full walkthrough for logging **every** request that errors at the gateway.

> *"Log / ship a log for any and every event / request where the error occurs at
> the gateway."*

## What it delivers

| Capability | Where it lives |
|---|---|
| Captures **100%** of requests with status ≥ 400 (4xx **and** 5xx) | Envoy access log on the `rhcl-apps-gateway` data plane |
| Filters out 2xx/3xx **in Envoy** (zero overhead on the happy path) | `status_code_filter` in the EnvoyFilter |
| One canonical path covers **auth denial (401/403)**, **rate limit (429)**, **backend error (5xx)** and **timeout/network (Envoy response flags)** | Authorino and Limitador return via Envoy |
| **Log ↔ trace** correlation | The OTLP record carries `traceId`/`spanId` matching Tempo |
| **Consumer** identity and detailed Authorino **denial reason** | `consumer.id` and `auth.reason` attributes (via an Authorino-injected header) |
| **PII** masking (Authorization, api-key, cookies) | `attributes/scrub` processor in the OTel Collector |
| **cluster/gateway** tag for multi-cluster aggregators | `resource/rhcl-tag` processor |
| Output as append-only **JSON Lines** (lab) or pluggable to Loki/Splunk | `file/audit` exporter (default) or `otlphttp/loki\|splunk` (configurable) |

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  rhcl-apps-gateway (Envoy/Istio data plane)                          │
│  Each HTTP request → 1 access log record. EnvoyFilter:               │
│    • status_code_filter ≥ 400  (errors only)                         │
│    • OpenTelemetryAccessLogConfig (OTLP/gRPC)                        │
│    • attributes: method, path, status, flags, durations, trace_id,   │
│      x-request-id, x-consumer-id, x-ext-auth-reason                   │
└──────────────────────────┬───────────────────────────────────────────┘
                           │ OTLP gRPC :4317
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  OTel Collector (observability/otel-rhcl) — pipeline.logs            │
│    processors: memory_limiter, filter/errors (code ≥ 400),           │
│      attributes/scrub, resource/rhcl-tag, k8sattributes, batch       │
│    exporters:  file/audit → /var/log/rhcl-errors.json  (lab)         │
│                otlphttp/loki   (uncomment for LokiStack)             │
│                otlphttp/splunk (uncomment for a SIEM)                │
└──────────────────────────────────────────────────────────────────────┘
```

### Why EnvoyFilter and not a Telemetry CR?

The "K8s-native" way would be a `Telemetry` CR pointing at an
`extensionProvider` registered in Istio's `meshConfig.extensionProviders`. On
RHCL 1.3 (Sail Operator) that path was tested and Sail **silently drops** any
patch to `meshConfig.extensionProviders` on the `Istio` CR — the reconciler
reverts the key before the next read.

`EnvoyFilter` is the same mechanism `kuadrant-tracing-rhcl-apps-gateway` (shipped
by the observability / opentelemetry item) uses, so we adopt the same pattern.
Trade-off: low-level, but works with 100% certainty on this stack.

## Prerequisites

| Component | Check |
|---|---|
| OTel Collector installed | `oc get opentelemetrycollector -n observability otel-rhcl` |
| Gateway `rhcl-apps-gateway` up | `oc get gateway -A \| grep rhcl-apps-gateway` |
| Sail Operator (Service Mesh 3) with Istio CR `openshift-gateway` | `oc get istio openshift-gateway` |
| cluster-admin access | `oc whoami` |

## Run it

### Quick (script)

```bash
bash tests/gateway-error-logging/scripts/apply.sh
bash tests/gateway-error-logging/scripts/validate.sh
bash tests/gateway-error-logging/scripts/cleanup.sh
```

### Manual — step by step

**1. Patch the OTel Collector (add the `logs` pipeline).**

```bash
oc apply -f tests/gateway-error-logging/manifests/02-otel-collector-logs-pipeline.yaml
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=180s
```

Adds a `logs` pipeline to the same Collector serving the `traces` pipeline — no
new pod, no new port. Mounts an `emptyDir` at `/var/log` for the `file/audit`
exporter to write `rhcl-errors.json`.

**2. Apply the EnvoyFilter on the gateway.**

```bash
oc apply -f tests/gateway-error-logging/manifests/01-envoyfilter-otel-access-logs.yaml
```

Injects an `envoy.access_loggers.open_telemetry` access log into the HTTP
connection manager of the `rhcl-apps-gateway` listeners. The `status_code_filter`
with `GE 400` ensures **only error requests** leave the data plane.

**3. Reload the data plane.**

```bash
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status   deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s
```

The EnvoyFilter is distributed over xDS; the restart forces pods to re-pull the
new config (in production a rolling update does this without downtime).

## What to look for

Generate a mix of traffic (200 + 401 + 404) and watch it live:

```bash
# Terminal 1 — tail the audit
COL=$(oc get pods -n observability -l app.kubernetes.io/name=otel-rhcl-collector \
        -o jsonpath='{.items[0].metadata.name}')
oc exec -n observability "$COL" -- tail -F /var/log/rhcl-errors.json

# Terminal 2 — traffic
URL=https://$(oc get httproute -n rhcl-apps banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}')
ALICE=$(oc get secret -n rhcl-apps banking-api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)

for _ in {1..5}; do curl -sk -o /dev/null -H "api-key: $ALICE" "$URL/api/v1/accounts/summary"; done  # 200 → NOT logged
for _ in {1..5}; do curl -sk -o /dev/null "$URL/api/v1/accounts/summary"; done                       # 401 → auth.reason="credential not found"
for _ in {1..3}; do curl -sk -o /dev/null -H "api-key: $ALICE" "$URL/api/v9/no-route"; done          # 404 → response.flags="NR"
```

One audit entry (parsed):

```json
{
  "body": "GET /api/v1/accounts/summary 401 flags=- duration_ms=2 upstream=-",
  "trace_id": "ad09689010fd7026f20a9588a44f3bc0",
  "http.method": "GET",
  "http.path": "/api/v1/accounts/summary",
  "response_code": "401",
  "auth.reason": "{\"api-key-header\":\"credential not found\"}",
  "consumer.id": "-",
  "request.id": "0d47efab-1de0-9608-abbf-4aa92eae0daf"
}
```

### Captured attributes (reference)

`http.method`, `http.path`, `http.host`, `response_code`, `response.flags`
(NR=no route, UF=upstream failure, UT=upstream timeout, …), `duration.ms`,
`upstream.host`/`upstream.cluster`, `bytes.received`/`bytes.sent`, `request.id`
(correlates with Tempo + Prometheus), `consumer.id` (who — alice/bob/carol, or
`-` if anonymous), `auth.reason` (Authorino denial reason), `traceId`/`spanId`
(native Tempo join), plus `k8sattributes` (pod/node) and `resource/rhcl-tag`
(cluster.name, gateway.name) for multi-cluster aggregation.

## Switching to LokiStack or a SIEM (production)

The `file/audit` exporter is for the lab. For production, point an OTLP exporter
at your log store — both can coexist with `file/audit` (multi-destination is
native to the Collector):

```yaml
# LokiStack (install the Logging Operator)
otlphttp/loki:
  endpoint: https://lokistack-gateway-http.openshift-logging.svc:8080/api/logs/v1/application/otlp
  tls:
    ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

# Splunk HEC (or Datadog / Elastic / any OTLP-compatible SIEM)
otlphttp/splunk:
  endpoint: https://splunk-hec.example.com:8088/services/collector
  headers:
    Authorization: "Splunk ${env:SPLUNK_HEC_TOKEN}"
```

## Playbook toggle

The `observability` role honors `OBSERVABILITY_ACCESS_LOGS_ENABLED=true|false`
(default `true`). Setting `false` disables the EnvoyFilter and the `logs`
pipeline without affecting traces or metrics.

## Hardening checklist

- [ ] **PII**: confirm the final scrub list with your security team. Default
  covers `Authorization`, `Cookie`, `Set-Cookie`, `api-key`, `x-api-key`.
- [ ] **Retention**: configure the log destination with a retention policy
  matching your regulatory requirement (e.g. GDPR, PCI-DSS).
- [ ] **Immutability**: a WORM destination (LokiStack S3 backend, or a dedicated
  SIEM tier).
- [ ] **Availability**: `OpenTelemetryCollector` with `replicas: 2+` and
  `mode: deployment` for HA; the data plane buffers and retries if the Collector
  is down; `memory_limiter` avoids OOM.
- [ ] **Time sync**: NTP on the nodes for log/trace/metric correlation.
- [ ] **Audit the audit**: changes to the `EnvoyFilter` and the
  `OpenTelemetryCollector` should go through GitOps (Argo CD) as auditable PRs.

## Cleanup

```bash
bash tests/gateway-error-logging/scripts/cleanup.sh
```

Removes the EnvoyFilter, the Collector's `logs` pipeline and the `emptyDir`. The
`traces` pipeline keeps working intact.
