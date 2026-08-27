---
title: OpenTelemetry traces and metrics
summary: "Runbook: OpenTelemetry traces and metrics from the gateway and backends."
category: Observability & audit
status: done
---

# OpenTelemetry traces and metrics

Full walkthrough for exposing **traces and metrics in the OpenTelemetry
standards** from the gateway and the RHCL-managed policies.

| Signal | Native standard | How it's demonstrated |
|--------|-----------------|-----------------------|
| **Traces** | OTLP (gRPC/HTTP) | Directly — the gateway, Authorino, Limitador and wasm-shim export OTLP spans to an OpenTelemetry Collector. |
| **Metrics** | Prometheus/OpenMetrics | Native scrape via OpenShift Monitoring + `ServiceMonitor`/`PodMonitor` (the Collector can also re-export them as OTLP). |

## Architecture

```text
Client  curl -H "x-request-id: poc-rhcl-otel-001"
  ▼
Gateway / Envoy (istio-proxy)   ← EnvoyFilter injects the OpenTelemetry tracer
  ▼
RHCL policies (AuthPolicy / RateLimitPolicy)
  ▼  Authorino / Limitador / wasm-shim   ← Kuadrant observability.tracing
OpenTelemetryCollector (otel-rhcl, ns observability)   ← OTLP gRPC :4317, k8sattributes
  ▼
TempoStack (tempo-rhcl, ns tempo)   ← stores traces in MinIO (S3)
  ▼
OpenShift Console — Observe → Traces (via COO UIPlugin)   [Jaeger UI is deprecated]
  +
Prometheus / OpenShift Monitoring   ← metrics via ServiceMonitor/PodMonitor
```

> **Why an EnvoyFilter, not the Istio CR:** OSSM 3.3 recommends configuring
> `extensionProviders` on the Istio CR, but here the `openshift-gateway` Istio CR
> is managed by the GatewayClass controller, which reverts any patch. So the
> gateway tracer (`envoy.tracers.opentelemetry`) is injected directly into the
> Envoy listeners via `EnvoyFilter`.

## Prerequisites

| Component | Check |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant installed | `oc get kuadrant -n kuadrant-system` |
| Sail Operator (Service Mesh 3) | already installed for RHCL |
| Tempo Operator | `oc get namespace openshift-tempo-operator` |
| Red Hat build of OpenTelemetry Operator | `oc get namespace openshift-opentelemetry-operator` |
| Cluster Observability Operator (COO) | `oc get namespace openshift-cluster-observability-operator` |
| cluster-admin access | `oc whoami` |

Install any missing operators via OperatorHub (`oc get csv -A | egrep -i 'tempo|opentelemetry|sail'`).

## Files

Apply in numeric order (all in [`manifests/`](manifests/)):

| # | Manifest | Creates | Namespace |
| --- | --- | --- | --- |
| 1 | `01-minio.yaml` | MinIO (S3 for the lab), a bucket-create Job, Secret `tempo-storage` | `minio`, `tempo` |
| 2 | `02-tempostack.yaml` | `TempoStack` `tempo-rhcl` with gateway + Jaeger Query | `tempo` |
| 3 | `03-rbac.yaml` | SA, ClusterRoles/Bindings for the Collector | `observability` |
| 4 | `04-opentelemetry.yaml` | `OpenTelemetryCollector` with an OTLP → Tempo pipeline | `observability` |
| 5 | `05-envoyfilter-otel-tracing.yaml` | `EnvoyFilter` injecting the OTel tracer into the gateway Envoy | `openshift-ingress` |
| 6 | `07-kuadrant-observability.yaml` | Patches the `Kuadrant` CR — metrics, tracing, correlation | `kuadrant-system` |
| 7 | `08-uiplugin-distributed-tracing.yaml` | `UIPlugin` — **Observe → Traces** in the console (via COO) | cluster-scoped |

## Run it

```bash
bash tests/opentelemetry-traces-metrics/scripts/apply.sh    # applies 1→7 in order, with waits
bash tests/opentelemetry-traces-metrics/scripts/validate.sh
```

Manual highlights:

- **MinIO** (S3 for the lab; use ODF/managed S3 in production) — console
  credentials `tempo` / `supersecret`.
- **TempoStack** — wait for Ready:
  `oc -n tempo get tempostack tempo-rhcl -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`.
- **Collector** — receives OTLP gRPC :4317 / HTTP :4318, enriches with
  `k8sattributes` + `resourcedetection`, exports to the Tempo gateway with a
  bearer token.
- **EnvoyFilter** — configures `envoy.tracers.opentelemetry` on the gateway
  listeners, 100% sampling (reduce to 1–10% in production).
- **Kuadrant observability** — patch the CR with `--type=merge` so only
  `spec.observability` is added:
  ```bash
  oc -n kuadrant-system patch kuadrant kuadrant --type=merge -p '{"spec":{"observability":{
    "enable": true,
    "dataPlane": {"defaultLevels": [{"debug": "true"}], "httpHeaderIdentifier": "x-request-id"},
    "tracing": {"defaultEndpoint": "rpc://otel-rhcl-collector.observability.svc.cluster.local:4317", "insecure": true}}}}'
  ```
  This creates `ServiceMonitor`/`PodMonitor` for scraping, exports Authorino/
  Limitador/wasm-shim spans, and correlates by `x-request-id`.
- **UIPlugin** — enables **Observe → Traces** (Jaeger UI is deprecated).

## What to look for

### Generate traffic

```bash
curl -vk -H "x-request-id: poc-rhcl-otel-001" https://banking-api.example.com/api/echo
# -k is needed if the cluster cert covers *.apps.example.com but not the custom CNAME.
for i in $(seq 1 10); do curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "x-request-id: poc-rhcl-otel-$(printf '%03d' $i)" https://banking-api.example.com/api/echo; done
```

### View traces

Console → **Observe → Traces** → instance **tempo-rhcl** (ns `tempo`), tenant
**dev** → set a time range → **Run Query** → click a trace to see its spans.

### Useful PromQL

```promql
rate(istio_requests_total[1m])                                              # requests/sec
histogram_quantile(0.99, rate(istio_request_duration_milliseconds_bucket[5m]))  # p99 latency
sum(rate(istio_requests_total{response_code=~"5.."}[1m])) / sum(rate(istio_requests_total[1m]))  # error rate
```

| Evidence | How to show it |
|---|---|
| Gateway metrics | `ServiceMonitor`/`PodMonitor` created; `rate(istio_requests_total[1m])` |
| OTel traces | Observe → Traces, tenant `dev`, search by service or `x-request-id` |
| Correlation | one `x-request-id` across metric + trace + log |
| Policy observability | create a `RateLimitPolicy`, generate `429`, show the Limitador metric + span |
| Trace propagation | the `rhcl-gateway → banking-api → ledger-api` chain under one Trace ID (below) |

## Backend→backend trace propagation (W3C tracecontext)

Beyond **capturing** gateway/policy spans, the lab demonstrates **propagating**
the trace context between microservices: `banking-api` calls a second
microservice, **`ledger-api`**, and the spans chain under a **single Trace ID**:

```text
Gateway / Envoy   ← starts the trace, injects the W3C `traceparent`
  ▼
banking-api  (/api/test/propagate)
  ├─ direct  → ledger-api.rhcl-apps.svc.cluster.local:8080/ledger/record
  └─ gateway → <ledger-api host>/ledger/record  (HTTPRoute + allow-all AuthPolicy)
  ▼
ledger-api  (/ledger/record)

Trace (1 Trace ID): rhcl-gateway → banking-api (server) → banking-api (client) → ledger-api (server)
```

### Propagation is configuration, not code

The key point: **no OpenTelemetry instrumentation code** is written in the apps.
Propagation is entirely config:

| Mechanism | Where | What it does |
|---|---|---|
| `Instrumentation` CR (`rhcl-apps-java`) | `apps` role | `propagators: [tracecontext, baggage]` — the Java agent propagates the W3C `traceparent` |
| `instrumentation.opentelemetry.io/inject-java: "true"` annotation | `banking-api` and `ledger-api` Deployments | the OTel Operator injects the Java agent (init container) — instruments inbound **and** outbound HTTP |
| the tracing `EnvoyFilter` | gateway | Envoy starts the trace and injects `traceparent` into the request to `banking-api` |

The `banking-api` agent **extracts** the received `traceparent` and **re-injects**
it on the outbound call to `ledger-api`; the `ledger-api` agent **continues** the
same trace. `ledger-api` declares no OpenTelemetry dependency. The only app code is
the outbound call itself (`java.net.http.HttpClient`, also agent-instrumented) —
no manual span creation or header propagation.

### Demonstrate

**PoC Console:** `mobile-bank` → **PoC console** → **Trace Propagation** tab → set
`Requests` and `Downstream calls` (1..20) → **Run load** (always via the gateway).
The **API key** field is pre-filled with `alice-gold-secret` (clear it to
reproduce the 401). The panel shows the **Trace ID** and an **Open in trace UI**
button auto-filled with the current cluster's Tempo.

**curl** (the call enters through the API-key-protected `banking-api-connectivity`
route; `target` controls only the internal hop):

```bash
curl -sk -H "api-key: alice-gold-secret" \
  "https://banking-api.<domain>/api/test/propagate?target=gateway&calls=2" | jq   # via RHCL gateway
curl -sk -H "api-key: alice-gold-secret" \
  "https://banking-api.<domain>/api/test/propagate?target=direct&calls=2" | jq    # via Service DNS
```

The response includes `traceId` and, per downstream call, `entryId`,
`downstreamTraceId`, `downstreamInstance`. In **Observe → Traces** (tenant `dev`),
confirm `rhcl-gateway`, `banking-api` and `ledger-api` share one Trace ID (with
`target=gateway`, an extra Envoy/Authorino/Limitador span appears on the internal
hop).

## Troubleshooting

- **TempoStack not Ready** — `oc -n tempo get tempostack tempo-rhcl -o yaml | grep -A5 conditions`; common causes: bucket not created, wrong `tempo-storage` credentials, PVC not provisioned.
- **Collector receives no traces** — `oc -n observability logs -l app.kubernetes.io/name=otel-rhcl-collector`; confirm the exporter endpoint points at the Tempo gateway.
- **Kuadrant doesn't create ServiceMonitors** — `oc -n kuadrant-system get kuadrant kuadrant -o yaml | grep -A10 observability` and the operator logs.

## Cleanup

```bash
bash tests/opentelemetry-traces-metrics/scripts/cleanup.sh
# or in reverse order: UIPlugin → Kuadrant observability patch → EnvoyFilter →
# Collector → RBAC → TempoStack → namespaces (minio, tempo, observability)
```

## References

- [RHCL 1.3 — Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability)
- [Kuadrant — Tracing](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/observability/tracing/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
