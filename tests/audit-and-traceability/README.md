---
title: Audit and traceability
summary: "Runbook: audit and trace every API call end to end."
category: Observability & audit
status: done
---

# Audit and traceability

RHCL records **every call** through the gateway in a **structured (JSON) access
log** on the Envoy pod's stdout, with audit fields that answer:

| Audit question | Access-log field |
|---|---|
| **When?** | `timestamp` |
| **Who called?** (IP) | `client_ip`, `x_forwarded_for` |
| **Which consumer?** | `consumer_id` (injected by Authorino via `x-consumer-id`) |
| **What was called?** | `method`, `path`, `authority` |
| **What was the result?** | `response_code`, `response_flags` |
| **How long did it take?** | `duration_ms` |
| **Which route/policy matched?** | `route_name` |
| **Denied? Why?** | `auth_reason` (Authorino's reason) |
| **How to correlate with the trace?** | `request_id` (Envoy-generated), `traceparent` |
| **Channel security?** | `downstream_tls_version`, `downstream_tls_cipher` |
| **Client-side correlation?** | `flow_trace_id` (the `x-flow-trace-id` header the client sends) |

### Where to see the evidence

> **The evidence is in the gateway pod's logs (`oc logs`), NOT in the Traces UI**
> (Observe → Traces) — that is the distributed-tracing item
> (`opentelemetry-traces-metrics`).

```bash
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default -c istio-proxy --tail=10
```

Each request produces two lines: the default Envoy/Istio text line, and the JSON
audit line added by this item:

```json
{"timestamp":"2026-06-11T13:45:16.371Z","method":"GET","path":"/api/v1/accounts/summary","response_code":200,"client_ip":"100.64.0.17","consumer_id":"alice","request_id":"c414857e-3edc-9743-a5c7-0024455afc55","traceparent":"00-5a9427f8...-01","downstream_tls_version":"TLSv1.3","downstream_tls_cipher":"TLS_AES_256_GCM_SHA384","route_name":"rhcl-apps.banking-api-connectivity.0"}
```

### How it relates to the other observability items

Three complementary items:

| Aspect | opentelemetry-traces-metrics | gateway-error-logging | **this item** |
|---|---|---|---|
| **Captures** | OTLP spans (per-component timing) | error requests only (≥400) | **all requests (100%)** |
| **Destination** | Tempo (via OTel Collector) | JSON file / SIEM | **gateway pod stdout** |
| **Where** | Observe → Traces | the Collector | **`oc logs` gateway** |
| **Consumer ID / auth reason / TLS info** | no / no / no | yes / yes / no | **yes / yes / yes** |

## Prerequisites

| Component | Check |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant installed | `oc get kuadrant -n kuadrant-system` |
| RHCL gateway active | `oc -n openshift-ingress get deploy -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway` |
| OTel Collector (recommended, for log↔trace correlation) | `oc -n observability get opentelemetrycollector otel-rhcl` |
| cluster-admin access | `oc whoami` |

## Architecture

```text
Client  curl -H "x-flow-trace-id: audit-001" -H "api-key: alice-gold-secret"
  ▼     (Envoy generates x-request-id automatically)
Gateway / Envoy (istio-proxy)
  ├─ ACCESS LOG (this item) → JSON on stdout {request_id, flow_trace_id, consumer_id,
  │                            method, path, response_code, traceparent, auth_reason, tls_*}
  ├─ TRACE SPAN → OTLP to Tempo (gateway → wasm-shim → auth → ratelimit)
  └─ ERROR LOG → OTLP to Collector (4xx/5xx, PII-scrubbed)
  ▼
Authorino / Limitador — logs carry the same Envoy request_id
  ▼
Correlation: flow_trace_id (client) → access log → request_id (Envoy) → traces / Authorino / Limitador
```

## Run it

```bash
bash tests/audit-and-traceability/scripts/apply.sh      # applies the access-log EnvoyFilter
bash tests/audit-and-traceability/scripts/validate.sh
```

Manual: apply `manifests/01-envoyfilter-access-log-json.yaml` (JSON access log). If
log volume is too high, use `manifests/02-envoyfilter-access-log-filter.yaml`
instead (drops health checks).

### Demo scenarios

Send a request with a client-side `x-flow-trace-id`, then grep the gateway log for
it:

```bash
FLOW_ID="audit-$(date +%s)"
curl -sk -o /dev/null -w "HTTP %{http_code}\n" -H "x-flow-trace-id: $FLOW_ID" \
  -H "api-key: alice-gold-secret" https://banking-api.example.com/api/v1/echo
sleep 1
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default -c istio-proxy --tail=50 \
  | grep "$FLOW_ID" | python3 -m json.tool
```

- **Public call** (`/api/echo`, no key) → JSON with `consumer_id: null`.
- **Authenticated call** (`/api/v1/echo` + key) → `consumer_id: alice`.
- **Denied call** (`/api/v1/accounts/summary`, no key) → `response_code: 401` +
  `auth_reason` (e.g. `credential not found`).
- **Log ↔ trace correlation** — from the JSON line extract the Envoy `request_id`
  and grep the Authorino / Limitador logs for it, and open the `traceparent` in
  Tempo (Observe → Traces).

## Access-log fields (reference)

`timestamp` (`%START_TIME%`), `method`, `path`, `protocol`, `response_code`,
`response_flags` (NR/UF/UT…), `duration_ms`, `client_ip`, `x_forwarded_for`,
`user_agent`, **`request_id`** (`%REQ(X-REQUEST-ID)%` — the Envoy UUID, for
trace/Authorino correlation), `authority`, `upstream_host`/`upstream_cluster`,
`route_name`, **`traceparent`** (W3C Trace Context), `downstream_tls_version`,
`downstream_tls_cipher`, **`consumer_id`** (Authorino identity), **`auth_reason`**
(Authorino denial), and **`flow_trace_id`** (`%REQ(X-FLOW-TRACE-ID)%` — the client
business trace, *not* overwritten by Envoy).

## Troubleshooting

- **No JSON access logs** — check the EnvoyFilter exists
  (`oc -n openshift-ingress get envoyfilter access-log-json`) and that Envoy did
  not reject it (`... logs ... | grep -i "rejected\|error"`). An
  `Not supported field in StreamInfo` error means a referenced field is
  unsupported on this Envoy version — remove it from `json_format`.
- **Grep by a custom x-request-id returns nothing** — Envoy **overwrites**
  `x-request-id` with its own UUID. Use `x-flow-trace-id` for client-side
  correlation (it is preserved, appearing as `flow_trace_id`); to learn the
  Envoy-generated `request_id`, read the `x-request-id` **response** header
  (`curl -v`).
- **`consumer_id` is null** — the `x-consumer-id` header is injected by Authorino
  only on routes protected by an `AuthPolicy`; public routes have none.
- **`auth_reason` empty** — only populated when Authorino **denies** (401/403);
  for authorized (200) requests it is null (expected).
- **`DOWNSTREAM_TLS_CIPHER_SUITE` unsupported** on this Envoy — use
  `DOWNSTREAM_TLS_CIPHER` (already fixed in the manifests).

> In production, ship the stdout access logs with ClusterLogForwarder (OpenShift
> Logging) to Loki, Splunk or another SIEM.

## Cleanup

```bash
bash tests/audit-and-traceability/scripts/cleanup.sh
# or:
oc -n openshift-ingress delete envoyfilter access-log-json access-log-filter --ignore-not-found
```

## References

- [Kuadrant — Envoy Access Logs](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/observability/envoy-access-logs/)
- [Envoy — Access Log Format Variables](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)
- [W3C Trace Context — traceparent](https://www.w3.org/TR/trace-context/#traceparent-header)
