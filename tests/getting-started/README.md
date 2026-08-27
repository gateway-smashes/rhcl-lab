---
title: Getting started — declare an API in RHCL
summary: In ~15 minutes, create a new authenticated API from scratch — route, plan, auth, rate limit, dev-portal catalog, and end-to-end test — without touching shared infra.
category: Getting started
status: done
---

# Getting started — declare an API in RHCL

> **Goal:** in ~15 minutes, create a new authenticated API (`banking-lite`) from
> scratch, expose it through the RHCL gateway, wire up API-key auth, per-consumer
> rate limiting, catalog it in the dev portal, test it end to end with a real
> client (mobile-bank), and onboard a user through the portal — all without
> touching the shared infra (the existing gateway, banking-api, and dev portal).

This is the hello-world onboarding flow, not a specific requirement.

## What you will create

A new API called **`banking-lite`** pointing at the existing `banking-api-v1`
backend, reachable at a new hostname (`banking-lite.<your-zone>`), with:

- **7 resources** (HTTPRoute + APIProduct + PlanPolicy + AuthPolicy +
  RateLimitPolicy + Secret + APIKey CR)
- **`api-key` header auth** — a request with no key → 401
- **Per-tier rate limit** — 60 req/min per consumer on the `demo` plan
- **Aggregate rate limit** — 500 req/min across the whole API
- Appears in the **dev portal** (users self-subscribe and get a key)
- Appears in the **Console plugin** (APIProducts → banking-lite)
- **Per-consumer metrics** in Grafana (`RHCL API Metrics`)

## Prerequisites (you already have these)

- A cluster with RHCL installed, gateway `rhcl-apps-gateway` in
  `openshift-ingress`, wildcard listener (any `*.<zone>` lands on it).
- **banking-api-v1** running in `rhcl-apps` (the backend we reuse — no new app).
- **Dev Portal** running in `rhcl-devportal` (optional for onboarding, but
  recommended).
- The console plugin installed (to view the product in the UI).
- `oc` logged in with permission to create Gateway API resources in `rhcl-apps`.

## The pieces — seven resources, three layers

```
   RHCL Gateway (existing, wildcard *.<zone>)
        │ parentRef
   HTTPRoute banking-lite  (hostname: banking-lite.<zone> → banking-api-v1:8080)
        │ targetRef (all policies)
   ┌────┴──────────┬─────────────────┬──────────────────┐
   │ AuthPolicy    │ PlanPolicy      │ RateLimitPolicy   │
   │ (api-key)     │ (60/min tier)   │ (500/min global)  │
   └────┬──────────┴─────────────────┴──────────────────┘
        │ selector.matchLabels
   Secret (real key: labels + annotations + data.api_key)
        ▲ secretRef
   APIProduct + APIKey CR (dev portal / UI governance)
```

**Layer 1 — routing:** `HTTPRoute` (requests on `banking-lite.<zone>/api/*` →
`banking-api-v1:8080`, attached to the gateway via `parentRefs`) and `APIProduct`
(wraps the route as a "product" in the dev-portal catalog).

**Layer 2 — policies** (all `targetRef` → the HTTPRoute): `PlanPolicy` (commercial
plans `gold`/`silver`/`demo` + per-consumer rate limit, selected by the `plan-id`
annotation on the key), `AuthPolicy` (requires the `api-key` header — no key →
401), `RateLimitPolicy` (an **aggregate** ceiling across all consumers, running
in parallel — whichever limit is hit first fires the 429).

**Layer 3 — identity:** `Secret` (the **real key** Authorino uses at runtime;
labels tie it to the AuthPolicy, annotations `user-id`/`plan-id` become consumer
metadata) and the `APIKey` CR (the **governance** object shown in the dev portal —
it does not authenticate). Deleting the Secret breaks the request immediately;
deleting the APIKey CR only removes it from the portal. In production the dev
portal creates both together when a user clicks "subscribe"; here we create them
by hand to see the pieces.

## Run it

**1. Pick the hostname** (derive the zone from the existing banking-api):

```bash
BASE=$(oc get httproutes.gateway.networking.k8s.io banking-api-connectivity \
  -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}' | cut -d. -f2-)
export HOSTNAME="banking-lite.${BASE}"
echo "Using: $HOSTNAME"
```

**2. Apply the 7 manifests:**

```bash
cd tests/getting-started
HOSTNAME="$HOSTNAME" ./scripts/apply.sh
```

The script applies the HTTPRoute (substituting `${HOSTNAME}`), APIProduct,
PlanPolicy, AuthPolicy, RateLimitPolicy, Secret and APIKey CR, waits 5s for
Authorino to sync, and prints the key to test with.

**3. Sanity check via curl:**

```bash
KEY=$(oc -n rhcl-apps get secret banking-lite-onboarding-key -o jsonpath='{.data.api_key}' | base64 -d)

curl -sk -o /dev/null -w "HTTP %{http_code}\n" "https://${HOSTNAME}/api/v1/accounts/summary"     # 401 (no key)
curl -sk -H "api-key: ${KEY}" "https://${HOSTNAME}/api/v1/accounts/summary" | jq '.[0:2]'         # 200 + accounts
```

If you get 401 with a key, Authorino hasn't synced yet — wait ~10s.

**4. Validate everything:**

```bash
HOSTNAME="$HOSTNAME" ./scripts/validate.sh
```

8 checks: HTTPRoute Accepted, APIProduct exists, 3 policies Enforced, no-key →
401, invalid → 401, valid → 200, rate limit fires after 60 requests, dev portal
sees it.

## Test with mobile-bank

The mobile-bank has a settings UI where you swap the RHCL Gateway URL and API key
at runtime (no redeploy):

1. Open mobile-bank → the **gear** icon (top-right).
2. Set **Endpoint profile** to **RHCL Gateway**.
3. **RHCL Gateway URL** = `https://<HOSTNAME>`; **RHCL API Key** = `$KEY`.
4. **Save**, go home — the bank list loads, a transfer works, streaming works, and
   POC Console → Metrics shows requests hitting `https://<HOSTNAME>/...`.

If the list is empty or you see a CORS error: check the key (no trailing space),
the URL (no trailing slash), and the browser Network tab (the AuthPolicy already
allows `OPTIONS` as anonymous, so preflight should pass).

## Onboard via the dev portal

So far we created the key by hand. In production the user self-registers through
the dev portal:

1. Open the portal (`https://portal.<zone>`), log in with a Keycloak user (create
   a consumer user via the portal's `setup-keycloak.sh` in
   [gateway-smashes/rhcl-developer-portal](https://github.com/gateway-smashes/rhcl-developer-portal)).
2. **APIProducts** → **Banking Lite** should be listed.
3. **Subscribe** → pick the **`demo`** plan → the portal creates a new Secret + an
   APIKey CR (auto-approved) → **Copy key**.
4. In the Console plugin (**APIs → Banking Lite → Consumers**) the new user
   appears; generate traffic and they rank in **Top consumers**.
5. In Grafana (`RHCL API Metrics`, filter `route_name = rhcl-apps.banking-lite.0`),
   the **Requests by consumer** panel separates the onboarding user and the
   portal user.

## What you learned

You touched the **6 resource types** that declare any API's behavior in RHCL:
HTTPRoute (routing), APIProduct (catalog/governance), PlanPolicy (plans +
per-consumer rate limit), AuthPolicy (auth), RateLimitPolicy (aggregate
protection), Secret + APIKey CR (identity). Every future API is a variation of
this — different hostname, paths, tiers, consumers; the structure is the same.

## Where to go next

- [`api-cost-monitoring`](../api-cost-monitoring/README.md) — per-consumer cost
  monitoring (Prometheus + a price table in a ConfigMap).
- [`streaming-and-body-limits`](../streaming-and-body-limits/README.md) — file
  streaming with an Envoy body cap.
- [`request-interception-mirror`](../request-interception-mirror/README.md) —
  request interception and inspection (ext_authz + mirror).
- [`gateway-mtls-enforcement`](../gateway-mtls-enforcement/README.md) — advanced
  policy composition.
- [`../automation/`](../automation/) — the Ansible that provisions all of this for
  the full lab.

## Troubleshooting

- **"HTTPRoute NOT Accepted"** — the gateway listener may not admit routes from
  `rhcl-apps`: `oc get gateway -n openshift-ingress rhcl-apps-gateway -o jsonpath='{.spec.listeners[*].allowedRoutes}' | jq` should show `namespaces.from: All`.
- **"AuthPolicy NOT Enforced"** — Kuadrant hasn't synced; wait 30s and re-run
  `validate.sh`.
- **401 with a correct key** — Authorino hasn't discovered the Secret (it needs
  both labels `authorino.kuadrant.io/managed-by=authorino` + `app=banking-lite-apikey`),
  or the key was copied with a trailing space.
- **Rate limit doesn't fire** — Limitador must be running and the PlanPolicy
  Enforced; if so, send 100 requests instead of 65 (serial requests may not
  exceed 60/min under gateway latency).
- **Dev portal doesn't show Banking Lite** — the portal-backend caches 30–60s;
  `oc -n rhcl-devportal delete pod -l app=portal-backend` to refresh.
