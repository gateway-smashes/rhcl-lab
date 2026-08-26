# REQ 74 — One request, front-to-back, in the audit trail

A **reproducible demo** for a customer: fire a single request through the RHCL
gateway and show that exact request in the **audit trail** — the gateway's JSON
audit access log (with the *consumer identity*) correlated to the **distributed
trace** (spans across gateway → banking-api → ledger-api). One command.

This item does **not** install the observability stack — it demonstrates it. The
plumbing lives in the observability role and its standalone tests:

| Piece | Provided by |
|---|---|
| JSON audit access log (`consumer_id`, `traceparent`, `request_id`) | `tests/req066` (EnvoyFilter `access-log-json`) |
| Distributed tracing → Tempo + trace-id on the response | `tests/req038` (TempoStack, OTel Collector, tracing EnvoyFilter + Telemetry CR, `trace-response-headers`) |
| Everything via Ansible | `automation/playbooks/observability-install.yml` |

## Prerequisites

- The observability stack installed (`observability-install.yml`, **or**
  `tests/req038/scripts/apply.sh` + `tests/req066/scripts/apply.sh`).
- The `apps` baseline (banking-api + ledger-api, with Java auto-instrumentation —
  defaults on) so the propagate endpoint produces a multi-service trace.
- `oc` logged in; `python3` for pretty-printing.

## Configure (customer environment)

Only `AUDIT_HOST` is required; the rest default to the lab and are overridable:

```bash
export AUDIT_HOST="banking-api.apps.<your-cluster-domain>"   # REQUIRED
export AUDIT_API_KEY="alice-gold-secret"                     # a valid consumer key
# defaults (override if the customer differs):
# AUDIT_GATEWAY_NS=openshift-ingress
# AUDIT_GATEWAY_DEPLOY=rhcl-apps-gateway-openshift-default
# AUDIT_ISTIO_CONTAINER=istio-proxy
# AUDIT_TEMPO_TENANT=dev
# AUDIT_PATH=/api/test/propagate?target=gateway&calls=2
```

> These map to the observability role vars (`OBSERVABILITY_*`) in
> `automation/inventories/example/group_vars/all.yml` — e.g.
> `APPS_CONNECTIVITY_GATEWAY_NAMESPACE`, and the gateway Deployment
> `rhcl-apps-gateway-openshift-default`.

## Run it

```bash
tests/req074-audit-e2e/scripts/trace-one-request.sh
```

It will:

1. **Send one request** with a unique `x-flow-trace-id` correlation id.
2. **Pull the gateway audit line** for that id and print *who / what / where*:
   `consumer_id`, `response_code`, `route_name`, `request_id`, `traceparent`.
3. **Print the trace id** and a ready-to-open **Tempo** link
   (`https://<tempo-gateway-route>/api/traces/v1/dev/trace/<traceId>`), plus the
   Console **Observe → Traces** path.

The closing line ties them together: the access-log `request_id`/`traceparent`
is the same request you see as spans in Tempo — front to back.

## Do it in the UI (for the live demo)

- **Frontend**: mobile-bank → **PoC Console → Trace Propagation** tab → *Run load*
  → shows the **Trace ID** and an **"Open in trace UI"** button (auto-built Tempo
  link).
- **Audit log**: `oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default -c istio-proxy --tail=50 | grep <flow-id>` — the JSON line with `consumer_id`.
- **Trace**: Console → **Observe → Traces** → instance `tempo-rhcl`, tenant `dev`
  → search the trace id → spans `rhcl-gateway → banking-api → ledger-api`.

## Notes / gotchas

- **`consumer_id` only appears on AuthPolicy-protected routes** (Authorino injects
  `x-consumer-id`). Anonymous/public routes log `consumer_id: null`. Use a
  protected path (default `/api/test/propagate`, or `/api/v1/...`) with a valid
  `api-key`.
- **Envoy overwrites the client `x-request-id`** — correlate with the
  `x-flow-trace-id` the script sends, not the client request id.
- **`-k` is expected**: the lab cert covers `*.apps.<cluster>`, not a CNAME host.
- If step 2 finds no line: check `AUDIT_GATEWAY_DEPLOY` (the istio-proxy pod name
  differs per gateway) and that the `access-log-json` EnvoyFilter is installed
  (`OBSERVABILITY_AUDIT_LOG_ENABLED=true`).
- If step 3 has no trace: the tracing EnvoyFilter **and** the Istio `Telemetry`
  CR (`randomSamplingPercentage: 100`) must both be present, or the gateway
  emits no spans.
