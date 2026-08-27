---
title: API cost monitoring
summary: Per-consumer cost view (calls + AI tokens x price per tier) built on Prometheus metrics.
category: Observability & audit
status: done
---

# API cost monitoring

Per-consumer cost view — how many calls each API consumer made, how many AI
tokens it spent, **and what that cost** over a configurable period — built on
RHCL + native OpenShift observability, with no external billing system.

> **Requirement:** monitor API cost per consumer: HTTP calls + AI tokens, with a
> price per tier.

## What this stack delivers

A **"Cost" page** in the console plugin and a **Grafana `RHCL API Costs`
dashboard** that show, per consumer:

- **Calls (24h)** — HTTP calls counted at the gateway (Istio)
- **Tokens (24h)** — prompt+completion sum emitted by the backend
- **Cost (24h)** — `Calls × price_per_call + Tokens × price_per_token`
- **Δ vs previous 24h** — day-over-day comparison

The **price table is per-tier** (`gold` / `silver` / `bronze` / `anonymous`),
lives in a ConfigMap, and is reconfigurable at runtime without a rebuild.

## Why this approach

You could count bytes in Envoy, integrate a billing SaaS, or emit per-request
CDRs. This uses **aggregated Prometheus metrics** for three reasons:

1. **No new infra.** The lab already ships Istio + UWM + Grafana Operator. We
   reuse `istio_requests_total` and add ONE Micrometer counter in the backend.
2. **Controlled cardinality.** Labels are `consumer_id + route`, no trace ID.
3. **Runtime-mutable price.** A ConfigMap watched by the plugin → an operator
   adjusts the `gold` price and the UI reflects it in <60s.

Trade-off: **this is monitoring, not billing** — it emits no invoice and does not
reconcile against an ERP. It is a FinOps/alerting view for expensive consumers.

## Architecture

```
Client ──HTTPS──> Gateway (Istio) ──> banking-api (Quarkus)
                      │                     │
                      ▼                     ▼
             istio_requests_total    bank_ai_tokens_total
             (label                  (Micrometer counter on
              request_headers_        /q/metrics)
              x_consumer_id)               │
                      │                     ▼
                      │             ServiceMonitor (scrapes /q/metrics)
                      ▼                     │
             ┌────────────────────────────────────┐
             │ Prometheus (User Workload) → Thanos │
             └───────────┬──────────────┬──────────┘
                         ▼              ▼
                    Grafana        Plugin "Cost" page
                    dashboard      reads prices from ConfigMap
                                   `<console>-config`.costPricing (watched)
```

## The four pillars

### 1 — Token counter in the backend

Metric: `bank_ai_tokens_total{kind, consumer_id, model, route}`

- `kind` = `prompt` or `completion` (two series per call — allows asymmetric
  "token in" vs "token out" pricing later)
- `consumer_id` = the `x-consumer-id` header the gateway injects after auth;
  `"anonymous"` when the request did not pass through Authorino
- `model` = the requested LLM (`banking-llm`, …)
- `route` = the path **template** (`/api/v1/chat/completions`), never the
  parameterized path — avoids series explosion from URL IDs

Exposed at `/q/metrics` (standard Quarkus Micrometer endpoint), incremented at
the end of each AI call (chat/completions, embeddings, responses).

### 2 — Telemetry CR to label the consumer on gateway metrics

Without this Telemetry CR, `istio_requests_total` has no
`request_headers_x_consumer_id` label — the cost table would collapse into a
single "no consumer" bucket.

> **Critical gotcha:** a Telemetry CR with `selector: {}` (default) only applies
> to sidecar-injected workloads. OpenShift Gateway API gateways are **standalone
> Envoy** (no injection webhook), so istiod silently ignores it and the
> `istio.stats` Wasm filter never gets the tagOverrides —
> `istio_requests_total` comes out without the custom labels and the dashboards
> are empty. **Fix:** set `spec.targetRefs` pointing at the Gateway explicitly.

Labels the CR adds: `request_url_path`, `request_headers_x_consumer_id`,
`route_name`.

### 3 — ServiceMonitor so UWM scrapes `/q/metrics`

Without it, `bank_ai_tokens_total` stays trapped in the pod — UWM has no
discovery in `rhcl-apps` by default.

**Cluster prerequisite:** UWM enabled — set `enableUserWorkload: true` in the
`cluster-monitoring-config` ConfigMap in `openshift-monitoring` (the Ansible role
does not patch this cluster-wide config automatically).

### 4 — Price table in a ConfigMap

Source of truth: the `apps_cost_pricing` Ansible variable, serialized as JSON in
the `costPricing` field of the console-config ConfigMap. Consumers:

- **Plugin:** `useCostByConsumer.ts` watches the ConfigMap via
  `useK8sWatchResource` — changes propagate without a plugin restart.
- **Grafana:** the dashboard has two manual variables (`price_calls_per_1k`,
  `price_tokens_per_1k`) edited at the top of the dashboard (Grafana does not
  read the ConfigMap, avoiding cluster-API RBAC on Grafana).

## The price table

```yaml
data:
  costCurrency: "USD"          # free string — a label only, no conversion
  costPricing: |
    {
      "gold":      { "tokens_per_1k": 0.10, "calls_per_1k": 0.05 },
      "silver":    { "tokens_per_1k": 0.20, "calls_per_1k": 0.10 },
      "bronze":    { "tokens_per_1k": 0.40, "calls_per_1k": 0.20 },
      "anonymous": { "tokens_per_1k": 0.50, "calls_per_1k": 0.25 }
    }
```

**Keys (tiers)** must match the `spec.plan` of the APIProduct/APIKey — the plugin
resolves each APIKey's tier from the `secret.kuadrant.io/plan-id` annotation.
`anonymous` is the fallback for requests without a consumer_id.

**Formula (applied by the plugin):**

```
cost_per_consumer = calls  × pricing[tier].calls_per_1k  / 1000
                  + tokens × pricing[tier].tokens_per_1k / 1000
```

Configure it three ways: **A —** via Ansible (`apps_cost_pricing`, survives a
reinstall); **B —** edit the ConfigMap directly (`oc -n <console-ns> edit
configmap <console>-config`, the plugin re-renders in <60s); **C —** via the
developer portal's **Administration → System Settings** (edits the same
ConfigMap through the portal-backend API).

## Files

All in [`api-cost-monitoring/manifests/`](manifests/):

| # | File | Purpose |
|---|---------|-----------|
| 01 | `01-dashboard-api-costs.yaml` | GrafanaDashboard CR pointing at the JSON ConfigMap |
| —  | `dashboard-api-costs.json`    | Dashboard JSON (source of the ConfigMap above) |
| 02 | `02-servicemonitor-banking-api.yaml` | ServiceMonitor for UWM to scrape `/q/metrics` |
| 03 | `03-telemetry-consumer-labels.yaml` | Telemetry CR adding `request_headers_x_consumer_id` |
| 04 | `04-plugin-config-pricing.yaml` | ConfigMap with `costCurrency` + `costPricing` (example) |

## Run it

```bash
cd tests/api-cost-monitoring/manifests

# 1. Collect HTTP metrics with the consumer label
oc apply -f 03-telemetry-consumer-labels.yaml

# 2. Have UWM scrape /q/metrics from banking-api
oc apply -f 02-servicemonitor-banking-api.yaml

# 3. Publish the price table (edit the values first — defaults are demo values)
oc apply -f 04-plugin-config-pricing.yaml

# 4. Grafana dashboard
oc -n rhcl-grafana create configmap rhcl-api-costs-json \
  --from-file=dashboard.json=./dashboard-api-costs.json
oc apply -f 01-dashboard-api-costs.yaml

# 5. Generate traffic to populate the dashboard
../../simulate-api-traffic.sh --target=banking --forever --rps=8
```

Or all at once: `./scripts/apply.sh`.

## What to look for

`./scripts/validate.sh` runs all the checks below.

**1. Is the backend emitting the counter?**

```bash
POD=$(oc -n rhcl-apps get pods -l app=banking-api-v1 -o jsonpath='{.items[0].metadata.name}')
oc -n rhcl-apps port-forward $POD 18080:8080 >/dev/null 2>&1 &
sleep 3; curl -s http://localhost:18080/q/metrics | grep '^bank_ai_tokens_total' | head; kill %1
```

**2. Does Prometheus/Thanos see it?**

```bash
THANOS=$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "https://$THANOS/api/v1/query?query=bank_ai_tokens_total" | jq '.data.result | length'
# >0 expected; if 0, the ServiceMonitor did not match.
```

**3. Does `istio_requests_total` carry the consumer_id label?**

```bash
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "https://$THANOS/api/v1/query?query=istio_requests_total%7Brequest_headers_x_consumer_id!%3D%22%22%7D" \
  | jq '.data.result | length'
# >0 expected; if 0, the Telemetry CR did not take — check spec.targetRefs.
```

**4. Does the plugin render the cost?** Open Console → the connectivity plugin →
**Cost**. Expect one row per APIKey (alice/bob/carol) + an `anonymous` row, a tier
badge matching the APIKey `plan-id`, and a populated `Cost (24h)` column.

**5. Runtime price change without restart** — edit `gold.tokens_per_1k` in the
ConfigMap; reload the Cost page within <60s and the gold row's cost updates.

**6. Graceful degradation** — set `costPricing` to `""`; the `Cost` column
disappears but `Calls` and `Tokens` remain.

## Known limitations

- **Only banking-api emits tokens** — pix-api/mock-api show `Calls` with
  `Tokens=0`.
- **AI endpoints are anonymous by design in the lab** — their tokens fall into
  the `anonymous` bucket.
- **The plugin period is fixed at 24h** — use the Grafana dashboard for arbitrary
  windows.
- **No multi-currency** — `costCurrency` is a label; it does not convert.
- **Tokens are a best-effort estimate** from the backend (`prompt_tokens +
  completion_tokens` returned by the LLM).
