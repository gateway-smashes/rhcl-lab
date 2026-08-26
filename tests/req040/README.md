# REQ 40 — Token counting per route (RHCL-native)

This runbook demonstrates AI-token observability **without instrumenting the
backend**. Token counting happens entirely in Kuadrant Limitador thanks to the
existing `TokenRateLimitPolicy` from [REQ 60](../req060/README.md) attached to
`HTTPRoute/banking-api-connectivity`. The Limitador `add_n_to_counter` CEL
expression reads the OpenAI-shaped `usage.total_tokens` field from each
response and increments `authorized_hits` — a counter Prometheus already knows
how to scrape.

Per-consumer breakdown is provided by a **second, complementary path** that
stays RHCL-native at the gateway: an Envoy access log on `rhcl-apps-gateway`
emits `RHCL_ACCESS` lines with `x-consumer-id`, Grafana Alloy ships those lines
to Loki, and a Grafana dashboard queries LogQL (with `regexp` parsers) by
consumer.

Summary card: [`tests/req040.md`](../req040.md). Interactive page:
[`index.html`](index.html). Manifest index: [`manifests/README.md`](manifests/README.md).

No new Prometheus or banking-api Micrometer code is created by this
requirement. The previous `PodMonitor` that scraped `/q/metrics` from
banking-api was **removed**, and the per-consumer `banking_ai_tokens_total`
Micrometer counters that used to live in `MockOpenAiChatService` /
`AiV1ExtraResource` no longer exist.

## Target flow

```text
Client / PoC page
  -> RHCL Gateway / HTTPRoute banking-api-connectivity
       Lua HTTP filter: usage.total_tokens (response body) -> metadata rhcl.ai/total_tokens
       Envoy RHCL_ACCESS log -> stdout  [x-consumer-id, tokens, path, status, ...]
       Alloy (K8s API tail) -> Loki -> Grafana "RHCL AI Consumer Access Logs"
  -> Kuadrant Authorino + Limitador (TokenRateLimitPolicy from REQ 60)
       add_n_to_counter(response.body.usage.total_tokens)
       -> authorized_hits{limitador_namespace="rhcl-apps/banking-api-connectivity"}
       -> authorized_calls{limitador_namespace=...}
       -> limited_calls{limitador_namespace=...}     (on 429)
  -> banking-api /api/v1/chat/completions  (any OpenAI-shaped path)
  -> ServiceMonitor /metrics  -> Prometheus (user-workload)
  -> Thanos Querier -> Grafana dashboard "RHCL AI Token Usage"
```

## Metrics (Limitador)

Scraped from `kuadrant-system/limitador-limitador:8080/metrics` via the
ServiceMonitor in this requirement. Queryable through Thanos and the Grafana
stack from [REQ 41](../req041/README.md).

| Metric | Labels | Purpose |
| --- | --- | --- |
| `authorized_hits` | `limitador_namespace` (= `<ns>/<HTTPRoute>`) | Sum of token counts added by every `TokenRateLimitPolicy` on the route. |
| `authorized_calls` | `limitador_namespace` | Number of calls that crossed the gateway and were authorized. |
| `limited_calls` | `limitador_namespace` | Calls that hit a rate-limit (HTTP 429). |

## Logs (gateway → Loki)

| Label / field | Source | Purpose |
| --- | --- | --- |
| `consumer` | `x-consumer-id` request header | Per-consumer breakdown of AI API calls. |
| `path` | Envoy `%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%` | Filter to `/api/v1/chat/completions` and sibling OpenAI paths. |
| `status` | HTTP response code | Spot HTTP 429 from Limitador rate-limit. |
| `duration_ms` | Envoy request duration | Gateway latency per call. |
| `tokens` | Lua filter → dynamic metadata `rhcl.ai/total_tokens` | Per-request token count in access log (`-` for SSE/streaming). |

## Relationship with other requirements

| Requirement | Role in REQ 40 |
| --- | --- |
| [REQ 33](../req033/README.md) | OpenAI-compatible API surface under `/api/v1` (where the `usage` block originates). |
| [REQ 38](../req038/README.md) | OpenTelemetry/Tempo for span correlation when enabled. |
| [REQ 41](../req041/README.md) | Grafana/Prometheus stack the dashboards plug into. |
| [REQ 60](../req060/README.md) | Owns the `TokenRateLimitPolicy` and rate-limit semantics; REQ 40 consumes the Prometheus counters Limitador exposes as a side-effect. |

## Prerequisites

### Tooling

- `oc` logged in to the target cluster (`oc whoami` must succeed).
- `jq` (optional) for parsing Thanos and Loki query responses.
- `python3` (optional) for URL-encoding LogQL queries in shell examples.

### Cluster baseline

```bash
oc whoami
oc -n rhcl-apps get deploy/banking-api-v1
oc -n rhcl-apps get httproute banking-api-connectivity
oc -n rhcl-apps get tokenratelimitpolicy banking-api-chat-completions-token-limit
```

Install [REQ 60](../req060/README.md) first if the token policy is not yet
enforced. The connectivity AuthPolicy must allow anonymous
`/api/v1/chat/completions` (same predicate as REQ 33 / REQ 60).

Set the public DNS zone used by the lab:

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"
export BACKEND="https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}"
```

### Observability baseline

```bash
# User Workload Monitoring must be enabled (lab default)
oc -n openshift-monitoring get cm cluster-monitoring-config \
  -o jsonpath='{.data.config\.yaml}'   # enableUserWorkload: true

# Grafana/Prometheus from REQ 41
oc -n rhcl-grafana get grafana rhcl-grafana
oc -n rhcl-grafana get grafanadatasource rhcl-prometheus
```

## Files

| File | Purpose |
| --- | --- |
| [`index.html`](index.html) | Interactive page: generate AI traffic, query Limitador via Thanos, link to Grafana dashboards. |
| [`manifests/kustomization.yaml`](manifests/kustomization.yaml) | Kustomize entrypoint for the full REQ 40 stack. |
| [`manifests/README.md`](manifests/README.md) | Manifest index by numeric range and namespace. |

See [`manifests/README.md`](manifests/README.md) for the per-manifest breakdown.

## Installation

Apply all manifests. The ServiceMonitor lives in `kuadrant-system`; Loki and
Alloy live in `rhcl-logging`; the EnvoyFilter and Telemetry CR patch
`openshift-ingress`; Grafana CRs register with the existing `rhcl-grafana`
instance via `instanceSelector.matchLabels.dashboards=rhcl`.

```bash
oc apply -k tests/req040/manifests/

oc -n kuadrant-system  get servicemonitor rhcl-limitador-tokens
oc -n rhcl-logging     get deploy loki rhcl-alloy-gateway-logs
oc -n openshift-ingress get envoyfilter rhcl-gateway-access-log telemetry rhcl-gateway-rhcl-access-only
oc -n rhcl-grafana     get grafanadashboard rhcl-ai-token-usage rhcl-ai-consumer-access-logs
oc -n rhcl-grafana     get grafanadatasource rhcl-loki
```

Confirm Alloy is running (replaces a hostPath Promtail DaemonSet that cannot
run under OpenShift restricted SCC):

```bash
oc -n rhcl-logging get pods -l app=rhcl-alloy-gateway-logs
oc -n rhcl-logging logs deploy/rhcl-alloy-gateway-logs --tail=20
```

If Loki was recreated, restart Alloy so it reconnects cleanly:

```bash
oc -n rhcl-logging rollout restart deploy/rhcl-alloy-gateway-logs
# wait ~60s for the first Kubernetes log backfill, then generate traffic
```

Confirm gateway `RHCL_ACCESS` lines include `consumer` and `tokens`. Tokens are
extracted at the gateway by the Lua filter in
[`manifests/30-envoyfilter-access-log.yaml`](manifests/30-envoyfilter-access-log.yaml):
it parses `usage.total_tokens` from the JSON response body (the same
OpenAI-shaped field Kuadrant's WASM reads for the `TokenRateLimitPolicy`),
stores it in dynamic metadata `rhcl.ai/total_tokens`, and the access log prints
it via `%DYNAMIC_METADATA(rhcl.ai:total_tokens)%`. No backend instrumentation
is required; SSE/streaming responses are skipped and log `tokens=-`.

```bash
curl -sk -X POST "${BACKEND}/api/v1/chat/completions" \
  -H 'content-type: application/json' -H 'x-consumer-id: probe' \
  -d '{"model":"x","mock_usage":{"prompt_tokens":20,"completion_tokens":25},"messages":[{"role":"user","content":"x"}]}' \
  -o /dev/null

GW=$(oc -n openshift-ingress get pods \
  -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway \
  -o jsonpath='{.items[0].metadata.name}')
oc -n openshift-ingress logs "$GW" -c istio-proxy --tail=5 | grep RHCL_ACCESS
# expected: ... consumer=probe tokens=45 ...
```

Confirm the Limitador target is being scraped (give it ~60s for the first
sync):

```bash
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
THANOS=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://${THANOS}/api/v1/query?query=authorized_hits" | jq .
```

Expected: a `vector` with `__name__=authorized_hits` and
`limitador_namespace="rhcl-apps/banking-api-connectivity"`.

## Validate with curl

Generate deterministic token usage for multiple consumers:

```bash
for c in alice-req40 bob-req40 charlie-req40; do
  for i in $(seq 1 3); do
    curl -sk -X POST "${BACKEND}/api/v1/chat/completions" \
      -H 'content-type: application/json' \
      -H "x-consumer-id: ${c}" \
      -d '{
        "model": "banking-mock-gpt",
        "mock_usage": {
          "prompt_tokens": 20,
          "completion_tokens": 25
        },
        "messages": [
          {
            "role": "user",
            "content": "Return a short account summary."
          }
        ]
      }' >/dev/null
  done
done
```

Inspect Limitador metrics (each call adds 45 to `authorized_hits`):

```bash
oc -n kuadrant-system port-forward svc/limitador-limitador 18080:8080 &
PF=$!; sleep 2
curl -s http://localhost:18080/metrics | grep -E '^authorized_|^limited_'
kill $PF
```

Query Loki for per-consumer call counts (from inside the cluster):

```bash
QUERY='sum by (consumer) (count_over_time({job="rhcl-gateway"} |= "RHCL_ACCESS" | regexp `consumer=(?P<consumer>[^ ]+)` | regexp `path=(?P<path>[^ ]+)` | path="/api/v1/chat/completions" | consumer!="-" [1h]))'
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$QUERY'''))")
oc -n rhcl-logging exec deploy/loki -- wget -qO- \
  "http://127.0.0.1:3100/loki/api/v1/query?query=${ENCODED}" \
  | jq '.data.result[] | {consumer: .metric.consumer, calls: .value[1]}'
```

## Validate with the interactive test page

Open the static test catalog and choose **REQ 40**. The page reads `/env.json`
and uses `APPS_CONNECTIVITY_ROUTE_HOSTNAME` to derive `${BACKEND}` and the
Thanos query endpoint. Use the controls to:

1. Generate AI traffic with one or more `x-consumer-id` values.
2. Pull `authorized_hits`, `authorized_calls`, and `limited_calls` from
   Limitador via Thanos.
3. Open Grafana dashboard **RHCL AI Consumer Access Logs** to see the
   per-consumer breakdown from gateway access logs.

## Validate in Grafana

Open the existing Grafana route:

```bash
oc -n rhcl-grafana get route
```

| Dashboard | Datasource | What it shows |
| --- | --- | --- |
| **RHCL AI Token Usage** | Prometheus (Thanos) | `authorized_hits` / `authorized_calls` / `limited_calls` per route (Limitador). |
| **RHCL AI Consumer Access Logs** | Loki (`uid: rhcl-loki`) | AI calls and HTTP 429 per `x-consumer-id` from Envoy access logs. |

Useful PromQL (Limitador):

```promql
sum(increase(authorized_hits{limitador_namespace="rhcl-apps/banking-api-connectivity"}[$__range]))
sum(rate(authorized_hits{limitador_namespace="rhcl-apps/banking-api-connectivity"}[5m])) * 60
sum(increase(limited_calls{limitador_namespace="rhcl-apps/banking-api-connectivity"}[$__range]))
```

Useful LogQL (per consumer):

```logql
sum by (consumer) (count_over_time({job="rhcl-gateway"} |= "RHCL_ACCESS" | regexp `consumer=(?P<consumer>[^ ]+)` | regexp `path=(?P<path>[^ ]+)` | path="/api/v1/chat/completions" | consumer!="-" [1h]))
sum by (consumer) (rate({job="rhcl-gateway"} |= "RHCL_ACCESS" | regexp `status=(?P<status>[^ ]+)` | status="429" | regexp `path=(?P<path>[^ ]+)` | path=~"/api/v1/chat/completions" [5m])) * 60
{job="rhcl-gateway"} |= "RHCL_ACCESS" | regexp `consumer=(?P<consumer>[^ ]+)` | consumer="alice-req40"
```

## Expected result

After the curl loop above (3 consumers × 3 calls, 45 tokens per call):

- `authorized_hits{limitador_namespace="rhcl-apps/banking-api-connectivity"}`
  grows by `9 × 45 = 405`.
- `authorized_calls` grows by `9`.
- Loki shows three consumers (`alice-req40`, `bob-req40`, `charlie-req40`)
  with three calls each on `/api/v1/chat/completions`.
- Gateway pod logs contain `RHCL_ACCESS` lines with `consumer=<name>`
  `tokens=45` for each JSON response.

## Known limitations

- **Token totals per consumer** are not available from Limitador 2.3.1
  (`authorized_hits` has no consumer label). Loki shows **call counts** and
  HTTP status per consumer; token totals remain aggregated in Limitador until
  upstream exposes counter-qualifier labels.
- Alloy tails gateway logs via the Kubernetes API (single-replica Deployment).
  High-volume production clusters would use OpenShift Logging or a node-level
  collector instead.
- Loki uses `emptyDir` storage (PoC retention 7 days). Data is lost if the Loki
  pod is rescheduled without persistent volumes.

## Cleanup

```bash
oc -n rhcl-grafana    delete grafanadashboard rhcl-ai-token-usage rhcl-ai-consumer-access-logs --ignore-not-found
oc -n rhcl-grafana    delete grafanadatasource rhcl-loki --ignore-not-found
oc -n kuadrant-system delete servicemonitor rhcl-limitador-tokens --ignore-not-found
oc -n openshift-ingress delete envoyfilter rhcl-gateway-access-log --ignore-not-found
oc -n openshift-ingress delete telemetry rhcl-gateway-rhcl-access-only --ignore-not-found
oc delete ns rhcl-logging --ignore-not-found
oc delete clusterrole,clusterrolebinding rhcl-alloy-gateway-logs --ignore-not-found
```
