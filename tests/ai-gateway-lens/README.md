---
title: AI Gateway lens
summary: Token governance plus an in-console chat playground — the AI gateway view.
category: AI gateway
status: done
---

# REQ 75 — AI Gateway lens (token governance + in-console chat playground)

Turns the OpenAI-compatible route into a governed, observable **AI Gateway**
with an interactive view in the custom console plugin.

> Verified end-to-end on the RHCL lab cluster. Token metering is real
> (`bank_ai_tokens_total` + Kuadrant `TokenRateLimitPolicy`); the 429 in the
> playground is a real gateway rejection over the shared token budget.

## What it wires

**Cluster (A)** — `deploy.sh`:
- **TokenRateLimitPolicy** `banking-api-chat-completions-token-limit` (from
  [`../req060`](../req060)) on `/api/v1/chat/completions` — **300 tokens / 1m**.
- **`ai-chat` TLS front** (`manifests/10-ai-chat-proxy.yaml`): an nginx with an
  OpenShift serving cert that the console proxy trusts, forwarding to the
  gateway's HTTP listener with the route's Host header. The console proxy
  requires HTTPS, and the plugin must reach the endpoint same-origin — this is
  the bridge.
- The **ConsolePlugin `ai-chat` proxy alias** → that TLS front.

**Plugin (B)** — `custom-rhcl-console`, page **Connectivity Link → AI Gateway**
(`/connectivity-link/ai-gateway`):
- KPIs: token rate, **token budget gauge** (vs the policy limit), AI requests,
  throttled (429), consumers, cost.
- The **TokenRateLimitPolicy** card (limit, path, enforcement, consumed vs budget).
- Per-consumer table (requests are real via istio `x-consumer-id`).
- **Try it** — a live chat playground: pick a consumer, send a prompt through
  the gateway, see the `usage` tokens come back, and a **live 429** once the
  per-minute token budget is exhausted.

**Real-only, honest gaps:** per-consumer *token* split is not shown — the mock
app reports token usage globally as `anonymous`, and Limitador `authorized_hits`
comes back empty for this route/version. Per-consumer *requests* are real.

## Deploy

```bash
oc login ...                       # admin on the RHCL cluster
./deploy.sh                        # AI_ROUTE_HOST auto-detected from the HTTPRoute
```

Override the coordinates if your names differ:

```bash
ROUTE_NS=rhcl-apps ROUTE_NAME=banking-api-connectivity \
GATEWAY_SVC=rhcl-apps-gateway-istio.openshift-ingress.svc.cluster.local \
AI_ROUTE_HOST=banking-api-connectivity.<apps-domain> ./deploy.sh
```

## Demo

1. Open **Connectivity Link → AI Gateway**. The budget gauge + KPIs poll live.
2. In **Try it**, pick a consumer (e.g. `banking-api-key-alice`), press **Send**
   a few times — watch `total_tokens` add up and the session counter climb.
3. Keep firing: once the combined token spend crosses **300/min**, the call
   returns **429 — token budget exceeded**, and the dashboard's *Throttled* KPI
   and budget gauge react.
4. Generate background load to fill the gauge quickly:

```bash
H="$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')"
KEY=$(oc get secret banking-api-key-alice -n rhcl-apps -o jsonpath='{.data.api_key}' | base64 -d)
for i in $(seq 1 12); do
  curl -sk -o /dev/null -w "%{http_code} " -X POST "https://$H/api/v1/chat/completions" \
    -H "api-key: $KEY" -H 'content-type: application/json' \
    -d '{"model":"banking-mock-gpt","messages":[{"role":"user","content":"conte ate 20"}]}'
done; echo
```

## Cleanup

```bash
oc delete -f manifests/10-ai-chat-proxy.yaml --ignore-not-found
oc delete tokenratelimitpolicy banking-api-chat-completions-token-limit -n rhcl-apps --ignore-not-found
oc patch consoleplugin custom-rhcl-console --type=json \
  -p "[{\"op\":\"test\",\"path\":\"/spec/proxy\"}]" >/dev/null 2>&1 || true   # then remove the ai-chat alias by index
```
