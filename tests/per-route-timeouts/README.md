---
title: Per-route request timeouts
summary: Gateway API enforces a per-route request timeout, cutting slow calls with 504 regardless of how long the backend takes.
category: Traffic & routing
status: done
---

# Per-route request timeouts

Demonstrates how RHCL / Gateway API enforces a **request timeout per route** —
independent of how long the backend actually takes to respond. It uses the
`banking-api` endpoint `/api/v1/timeout` (which sleeps a fixed 3s) to force a
slow response and observe the gateway cutting the call with
`504 Gateway Timeout`.

## Requirement context

An API gateway must be able to bound how long a client waits, per route, so a
slow or hung upstream cannot tie up connections. The Gateway API expresses this
natively through `HTTPRoute.spec.rules[].timeouts.request` — no custom filter or
sidecar tuning required. The timeout is bound to the **route**, not to the
backend endpoint: the same upstream resource can be reached through two routes
with different timeouts and behave differently.

## What it demonstrates

- A single `HTTPRoute` with three rules pointing at the **same** backend
  endpoint (`/api/v1/timeout`, which sleeps 3s), each with a different
  `timeouts.request`:

  | External path            | `timeouts.request` | Filter                             | Expected result           |
  | ------------------------ | ------------------ | ---------------------------------- | ------------------------- |
  | `/api/v1/timeout`        | `2s`               | —                                  | **504** (gateway cuts)    |
  | `/api/v1/timeout-longer` | `30s`              | `URLRewrite` → `/api/v1/timeout`   | **200** after ~3s         |
  | `/api/v1` (PathPrefix)   | `30s`              | —                                  | **200** for the rest of v1 |

- The `/api/v1/timeout-longer` rule uses `URLRewrite` (a native Gateway API
  filter) to rewrite the path before forwarding. This proves, against the
  **same upstream resource**, that `timeouts.request` is tied to the route and
  not to the backend endpoint.
- The backend keeps processing after the gateway has already returned 504 — the
  pod log shows the request completing, proving the cut was the gateway's.

## Files

- [index.html](index.html) — single-file interactive console (no build).
- [manifests/httproute-timeout.yaml](manifests/httproute-timeout.yaml) — the
  `HTTPRoute`, attached to the lab's wildcard gateway, exposing
  `timeout.${RHCL_ZONE_ROOT_DOMAIN}` with different per-route timeouts.

## Prerequisites

1. The lab wildcard `Gateway rhcl-apps-gateway` (`openshift-ingress`) reconciled
   by the automation, serving `*.${RHCL_ZONE_ROOT_DOMAIN}`.
2. `banking-api` deployed in `rhcl-apps` (it ships the `/api/v1/timeout`
   endpoint used here).
3. `oc` authenticated, with permission to manage `HTTPRoute` in `rhcl-apps`.

### The `RHCL_ZONE_ROOT_DOMAIN` variable

The tests image (`tests/Dockerfile`) generates an `env.json` in the nginx
docroot at boot from the pod's environment. When the page loads it fetches
`/env.json` and, if `rhclZoneRootDomain` is set, pre-fills the **Base URL**
(`https://timeout.<domain>`) and the `HTTPRoute` YAML (substituting
`${RHCL_ZONE_ROOT_DOMAIN}` with the effective hostname, ready for `oc apply`).
Served locally with `python3 -m http.server`, `env.json` simply does not exist
and the page falls back to its hardcoded defaults.

## Run it

Apply the route (the manifest uses `${RHCL_ZONE_ROOT_DOMAIN}` as a placeholder —
export it for your lab domain and apply via `envsubst`):

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.example.com   # your lab domain

envsubst < tests/per-route-timeouts/manifests/httproute-timeout.yaml | oc apply -f -

oc -n rhcl-apps get httproute banking-api-timeout
```

Then serve the interactive page (any port works — it only fires `fetch()`):

```bash
# from the repo root
python3 -m http.server 8080 --directory tests/per-route-timeouts
# open http://localhost:8080
```

> Mind mixed-content if you serve the page over HTTPS and point it at an HTTP
> backend.

### Using the page

1. Fill **Base URL** with the backend address (for "direct" tests) or the
   gateway with the timeout applied (`https://timeout.<domain>`).
2. Use **Route path** or the presets to choose which route to call:
   - `/api/v1/timeout` (2s timeout — expect 504)
   - `/api/v1/timeout-longer` (30s timeout — expect 200 after 3s)
3. Enter the **expected route timeout (ms)** — used only so the page can
   classify the result as coherent. The presets fill this in automatically.
4. Click **Send request**.
   - The *Last request* card shows the URL called, the measured duration and the
     HTTP status.
   - The *Verdict* card compares duration × timeout × delay (the backend's fixed
     3s) to indicate whether the behavior matches expectations.
5. Use the **curl** blocks to reproduce the test from a terminal, and the
   **oc logs** block to confirm, in the pod log, that the backend kept
   processing even after the gateway returned 504.

## What to look for

**Direct backend** (no timeout in the path):
- 200 OK in ≈ `delay` ms, even with `delay = 6000` or `15000`.

**Via gateway with `timeouts.request: 2s`:**
- `delay ≤ 2000` → 200 OK in ≈ `delay` ms.
- `delay > 2000` → **504 Gateway Timeout** in ≈ 2000 ms.
- The pod log still shows the backend line processing — proof the cut came from
  the gateway.

## How it works

The `/api/v1/timeout` endpoint was added to `banking-api` specifically for this
demo: `GET /api/v1/timeout` sleeps a fixed **3s** and then responds with a JSON
body reporting the configured delay and elapsed time. The pod log records a
`timeout demo start` line on receipt and `timeout demo end` on completion —
useful to prove the backend kept running even when the gateway had already
answered 504.

The page also includes an example `HTTPRoute` YAML with different per-route
timeouts (`/api/v1/accounts/summary` 1s, `/api/test/echo-error` 2s, `/api/files`
30s). Apply it and adjust `parentRefs.name` / `backendRefs.name` / `hostnames`
for your lab, then repeat the tests pointing the page at the gateway URL to see
the 504 fire per rule.

## Cleanup

```bash
oc -n rhcl-apps delete httproute banking-api-timeout
```
