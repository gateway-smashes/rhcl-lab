---
title: CORS policy at the gateway
summary: Enforce CORS at the gateway with the Gateway API / Kuadrant — no backend changes.
category: Traffic & routing
status: done
---

# CORS policy at the gateway

A single-file interactive page that demonstrates the CORS problem when the
browser calls the backend from a different origin, and how routing the same
call through a dedicated gateway host fixes it — via the `HTTPRoute`
`ResponseHeaderModifier` filter, with no backend change.

## What it demonstrates

- The browser blocks a cross-origin `fetch()` to a backend that emits no
  `Access-Control-Allow-*` headers.
- Routing the same call through the gateway host (`cors.<domain>`), where an
  `HTTPRoute` filter injects the CORS headers, makes the request succeed.
- The backend endpoint deliberately emits **no** CORS headers, so the effect is
  attributable entirely to the gateway.

## Files

- [index.html](index.html) — single-file interactive console (no build).
- [manifests/httproute-cors.yaml](manifests/httproute-cors.yaml) — the
  `HTTPRoute`, attached to the lab's wildcard gateway, exposing
  `cors.${RHCL_ZONE_ROOT_DOMAIN}` with `Access-Control-Allow-*` headers injected
  by the gateway.

## The dedicated `/api/v1/cors` endpoint

Added to `banking-api` for this demo:

- `GET /api/v1/cors` — returns JSON with `instance`, `backendTag`, `message`,
  `origin` (echo of the received `Origin` header), `referer`, `timestamp`. It
  emits **no** `Access-Control-Allow-*` headers.
- The pod log records `cors demo version=v1 instance=... origin=... referer=...`
  to show which origin the backend received.

The absence of CORS headers is the point of the demo: cross-origin calls only
work once the gateway injects those headers.

## Prerequisites

- The lab wildcard `Gateway rhcl-apps-gateway` (`openshift-ingress`) serving
  `*.${RHCL_ZONE_ROOT_DOMAIN}`.
- `banking-api` deployed in `rhcl-apps` (it ships `/api/v1/cors`).
- `oc` authenticated, able to manage `HTTPRoute` in `rhcl-apps`.

### The `RHCL_ZONE_ROOT_DOMAIN` variable

The tests image (`tests/Dockerfile`) generates `/env.json` at boot from the pod
environment (whitelist in `tests/catalog/generate-env.sh`). When
`RHCL_ZONE_ROOT_DOMAIN` is set on the Deployment, the page pre-fills the "Via
gateway" preset and the shown YAML with the final hostname `cors.<domain>`.

## Run it

Apply the route:

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.example.com   # your lab domain

envsubst < tests/cors-policy/manifests/httproute-cors.yaml | oc apply -f -

oc -n rhcl-apps get httproute banking-api-cors
```

The route attaches to the wildcard `*.${RHCL_ZONE_ROOT_DOMAIN}` gateway. Its one
rule matches `/api/v1/cors` (Exact) and injects:

| Header | Value |
| --- | --- |
| `Access-Control-Allow-Origin` | `*` |
| `Access-Control-Allow-Methods` | `GET, POST, OPTIONS` |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type, Accept, X-Requested-With` |
| `Access-Control-Expose-Headers` | `x-instance, x-flow-trace-id` |
| `Access-Control-Max-Age` | `600` |
| `Vary` | `Origin` |

Then serve the page. It must be served from an **origin different** from the
backend to trigger CORS — opening `index.html` directly via `file://` does not
reproduce the scenario:

```bash
# from the repo root
python3 -m http.server 8080 --directory tests/cors-policy
# open http://localhost:8080
```

### Using the page

1. **Open DevTools first** (F12 → Console + Network). The detailed CORS error is
   printed by the browser, not by JS — `fetch()` only sees a generic
   `TypeError: Failed to fetch`.
2. Use the presets to pick the Base URL and path:
   - **Direct backend** (`https://banking-api-v1-rhcl-apps...`) — no CORS, the
     fetch should fail.
   - **Via gateway** (`https://cors.${RHCL_ZONE_ROOT_DOMAIN}`) — with CORS, the
     fetch should pass.
   - Default path: `/api/v1/cors`.
3. Click **Fetch GET**. The *Last request* card shows the duration, HTTP status
   and the count of CORS headers in the response; the *Verdict* card classifies
   the result.
4. **OPTIONS preflight** sends a manual `OPTIONS` to inspect what the server
   returns for a preflight (not a "real" preflight — the browser fires those).
5. The **curl** blocks reproduce the test from a terminal. Note that `curl`
   ignores CORS (it always returns the body); what changes is the presence or
   absence of the `Access-Control-Allow-*` headers in the response.

## What to look for

**Direct backend:**
- *Fetch GET* logs `TypeError: Failed to fetch`.
- The DevTools Console shows something like: `Access to fetch at 'http://...'
  from origin 'http://localhost:8080' has been blocked by CORS policy: No
  'Access-Control-Allow-Origin' header is present on the requested resource.`
- *OPTIONS preflight* returns no `Access-Control-*` header.

**Via `cors.${RHCL_ZONE_ROOT_DOMAIN}`:**
- *Fetch GET* returns `200 OK` and the JSON body appears in the log.
- *OPTIONS preflight* shows the headers injected by the gateway.

> ⚠ **OPTIONS preflight caveat.** The filter adds CORS headers to every
> response, but the browser also requires the preflight `OPTIONS` to return a
> **2xx** status. If your backend returns a non-2xx (e.g. 403) for `OPTIONS`,
> the browser blocks the request even with the headers injected. Validate with:
> `curl -i -X OPTIONS <backend-url> -H 'Origin: http://x' -H 'Access-Control-Request-Method: GET'`

> **Mixed content.** If the page is served over `https://` (e.g. GitHub Pages)
> and the backend is on `http://`, the browser blocks it as **mixed content**
> before CORS even applies. Serving over `http://localhost` keeps the error
> clearly attributable to CORS.

## How it works

**Requirement:** allow CORS to be configured at the gateway level, so a browser
frontend on one origin can call an API on another origin.

```
SCENARIO 1 — Without the gateway (CORS problem)

  Frontend (app.mydomain.com) --fetch--> Backend API (api.otherdomain.com)
                                          BLOCKED — browser enforces CORS,
                                          backend sends no allow headers

SCENARIO 2 — With RHCL / Gateway API handling CORS

  Frontend (app.mydomain.com) --fetch--> RHCL Gateway (api.mydomain.com)
                                          - terminates TLS
                                          - applies the CORS policy
                                          - handles the OPTIONS preflight
                                          - proxies to the real backend
                                          => browser sees proper CORS headers,
                                             request is allowed
```

The gateway injects the CORS headers with an `HTTPRoute`
`ResponseHeaderModifier` filter, so the same backend becomes reachable
cross-origin without any application change. To restrict access, replace
`Access-Control-Allow-Origin: *` with a specific frontend origin.

## Cleanup

```bash
oc -n rhcl-apps delete httproute banking-api-cors
```
