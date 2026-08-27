---
title: Streaming and body-size limits
summary: Server-sent streaming responses and enforcing request / response body caps at the gateway.
category: Traffic & routing
status: done
---

# Streaming and body-size limits

Controls the **byte flow** of uploads at the gateway data plane — a maximum size
(32 MiB) and a maximum duration (60s) — **in streaming mode** (without buffering
the whole request in memory to validate it), without touching the backend. A
50 MiB upload is rejected by the gateway with `HTTP 413` **while the bytes are
still arriving** — the rejection fires on the chunk that crosses the cap.

## What it demonstrates

Two combined gateway (Envoy) controls, **both streaming** — the gateway processes
bytes chunk-by-chunk as they arrive, never holding the whole request:

| Control | Default | Effect |
|----------|---------------|--------|
| **Size cap (streaming)** | 32 MiB | Upload > 32 MiB → `HTTP 413` + `x-rhcl-streaming-cap: 33554432` + `x-rhcl-observed-bytes: <total>`. Fires on the chunk that overflows, **without buffering** the rest — remaining bytes are never read from the client. |
| **Upload timeout** | 60s | An upload taking longer than 60s (slow client / weak connection) → `HTTP 408` or `504`. |

**The backend (banking-api) is a black box** — no Quarkus parameter is changed;
`quarkus.http.limits.max-body-size` stays at its `1G` default, but the gateway
rejects well before that.

**Why an EnvoyFilter at the gateway, not the backend:** a 500 MiB upload rejected
at the gateway consumes no memory/CPU/storage in the app pod; the platform team
owns the cap (one patch changes it, no app redeploy); and the `413` carries an
RHCL signature (`x-rhcl-streaming-cap` + `x-rhcl-observed-bytes`) proving the cut
was at the gateway and that validation was progressive, not buffered.

## Architecture

```
Client ──HTTPS─► Gateway RHCL ──►  EnvoyFilter Lua (streaming)             ──► banking-api
(upload N MiB)   (rhcl-apps-gw)     for chunk in bodyChunks() do               /api/files/upload
                                      total = total + chunk:length()           InputStream → SHA-256
                                      if total > 32 MiB then respond(413)       (64 KiB chunks, streaming)
                                    only active on POST /api/files/upload
                                    HTTPRoute rule: timeouts.request 60s

Reject-by-size (50 MiB upload):
  client sends chunks (16-64 KiB) → Lua counts each → total > 32 MiB on chunk N
    → respond(413) IMMEDIATELY → chunks N+1… never requested → backend never sees it

Success (25 MiB upload):
  chunks stream through → backend receives them chunk-by-chunk → online SHA-256
    → memory: 1 chunk per leg (gateway ~64 KiB, backend 64 KiB)

Reject-by-time (5 MiB at 100 KiB/s ≈ 52s):
  slow bytes → HTTPRoute 60s timer fires → gateway aborts → 408/504
```

## How it works — three pillars

### 1 — EnvoyFilter Lua streaming (the size cap, no buffering)

[`manifests/01-envoyfilter-streaming-cap.yaml`](manifests/01-envoyfilter-streaming-cap.yaml)
injects `envoy.filters.http.lua` before the router with a script that counts via
Envoy's **streaming** `bodyChunks()` iterator:

```lua
for chunk in handle:bodyChunks() do
  total = total + chunk:length()
  if total > MAX_BYTES then
    handle:respond({[":status"] = "413", ...}, "Payload Too Large")
    return
  end
end
```

At any moment the gateway holds only **1 chunk** (16-64 KiB, Envoy's socket
buffer), **not the whole request**. This is why we do **not** use
`envoy.filters.http.buffer` — that holds all bytes in memory until it can validate
the cap ("reject-by-size buffered", not streaming).

- **Scope:** the Lua only activates on `POST /api/files/upload` (the path check is
  the single `if path:sub(1, #UPLOAD_PATH) ~= UPLOAD_PATH then return end`). Other
  paths return immediately — zero overhead for WebSocket upgrades, JSON POSTs,
  GETs, or SSE response streams.
- **Namespace:** the EnvoyFilter must live in the gateway's namespace
  (`openshift-ingress`); `workloadSelector.labels` selects only the lab gateway
  (`gateway.networking.k8s.io/gateway-name: rhcl-apps-gateway`).

**Malformed HTTP framing is rejected before Lua** — Envoy's framing parser runs
first: a request with both `Content-Length` and `Transfer-Encoding: chunked`
(classic request-smuggling vector, forbidden by RFC 9112 §6) gets **400 Bad
Request** from the HTTP Connection Manager; Lua is never invoked.

**Optional symmetry — a response-direction cap:** the item is asymmetric by design
(it limits only the upload / request body). If you need a symmetric cap, the same
EnvoyFilter accepts an `envoy_on_response` callback — but note the trade-off: on
the response the backend has already committed `200` headers, so cutting mid-stream
becomes a `502` + partial bytes. Never cap legitimate streaming (SSE, log tail,
large downloads).

### 2 — HTTPRoute `timeouts.request` (the time cap)

[`manifests/02-httproute-timeout-patch.yaml`](manifests/02-httproute-timeout-patch.yaml)
adds a rule matching `POST /api/files/upload` with `timeouts.request: 60s`. If the
whole upload (client → gateway → backend → response) does not finish in 60s, the
gateway aborts.

- It is a **separate rule** because `timeouts.request` (Gateway API GEP-1742) is
  per-rule — a global 60s would break long-polling / AI streaming.
- **Rule order matters** (longer prefix wins): it goes before the `/api` catch-all
  so `/api/files/upload` matches first.
- **`request` vs `backendRequest`:** `request` covers the whole upload (so slow
  *client* uploads are aborted too); `backendRequest` would time only the upstream
  leg.

For long flows (SSE, WebSocket, large uploads over a slow link) you can remove the
timeout from **just** the upload rule (the HCM `stream_idle_timeout`, default 300s,
still reaps idle streams), or set it large (`1h`) — safer than removing all
timeouts (which loses slowloris/zombie-connection defense).

### 3 — Backend untouched (by design)

`FilesResource.upload()` streams the `InputStream` in 64 KiB chunks and computes an
online SHA-256, returning `{ sha256, bytesReceived, durationMs }`. No special env
vars, no adjusted max-body-size. **Proof of separation:** disable the EnvoyFilter
(`APPS_STREAMING_ENABLED=false`) and 500 MiB uploads work via Quarkus's default
`1G` cap — confirming the protection was 100% RHCL.

## The full streaming-knob catalog

We use 2 of 6; the rest are documented for when you need them:

| Knob | RHCL surface | This item sets |
|------|-----------------|---------------|
| **Streaming size cap** | EnvoyFilter Lua `bodyChunks()` counter | **32 MiB** |
| **Per-route request timeout** | HTTPRoute `timeouts.request` (GEP-1742) | **60s** |
| Per-route backend timeout | HTTPRoute `timeouts.backendRequest` | _(Envoy default)_ |
| Stream idle timeout | EnvoyFilter HCM `stream_idle_timeout` | _(default 300s)_ |
| Max request headers | EnvoyFilter HCM `max_request_headers_kb` | _(default 60 KiB)_ |
| Auth-side body buffering | AuthPolicy `with_request_body` | **off** |

## Configure it

**A — Ansible (canonical):** set env vars before the playbook
(`APPS_STREAMING_MAX_REQUEST_BYTES`, `APPS_STREAMING_UPLOAD_REQUEST_TIMEOUT`,
`APPS_STREAMING_ENABLED`, …).

**B — kubectl apply (fastest for runtime tuning):** edit `MAX_BYTES` in the Lua
`inline_string` of `manifests/01-envoyfilter-streaming-cap.yaml` and re-apply —
Envoy reconfigures in <10s via xDS, no pod restart.

**C — `oc edit`** the `files-upload-streaming-cap` EnvoyFilter directly (emergency
only; does not survive a reinstall).

## Run it

Prerequisites: RHCL installed, gateway `rhcl-apps-gateway` in `openshift-ingress`,
HTTPRoute `banking-api-connectivity` in `rhcl-apps`, banking-api with
`/api/files/upload`, and a valid API key.

```bash
cd tests/streaming-and-body-limits
./scripts/apply.sh                       # applies both manifests (idempotent)

# confirm
oc -n openshift-ingress get envoyfilter files-upload-streaming-cap
oc -n rhcl-apps get httproute banking-api-connectivity -o jsonpath='{.spec.rules[?(@.timeouts)].timeouts}{"\n"}'
# {"request":"60s"}

export API_KEY='<api-key>'; export GATEWAY_HOST='banking-api-connectivity.<your-apps-domain>'
./scripts/validate.sh
```

## What to look for

`./scripts/validate.sh` runs 5 cases (exit 0 if all pass):

| Case | Expected |
|------|---------------------|
| Upload **1 MiB** | `HTTP 200` + `{sha256, bytesReceived:1048576, durationMs}` |
| Upload **25 MiB** | `HTTP 200` + `{sha256, bytesReceived:26214400, ...}` |
| Upload **50 MiB** | `HTTP 413` + `x-rhcl-streaming-cap: 33554432` + `x-rhcl-observed-bytes: <total>` |
| Upload **5 MiB at 100 KiB/s** (~52s) | `HTTP 408` or `504` past 60s |
| Download **10 MiB, 256 KiB chunks** | `HTTP 200` + `Content-Length: 10485760` |

**Proof the cap is RHCL's, not the backend's:**

```bash
oc -n rhcl-apps get deploy banking-api-v1 -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -c HTTP_MAX_BODY_SIZE
# 0 — no body-size env injected into the backend
```

**Proof the rejection was streaming, not buffered:**

```bash
dd if=/dev/urandom bs=1M count=50 status=none | curl -sk \
  -X POST -H "api-key: $API_KEY" -H "Content-Type: application/octet-stream" \
  --data-binary @- -D - -o /dev/null -w "HTTP %{http_code}\n" \
  "https://$GATEWAY_HOST/api/files/upload"
# HTTP 413 + x-rhcl-observed-bytes just above 32 MiB (< 50 MiB). If Envoy had
# buffered everything, observed-bytes would equal the request Content-Length.
```

The interactive [`index.html`](index.html) has 1 MiB / 25 MiB / 50 MiB buttons.

## Known limitations

- **Lua VM CPU cost** — each `POST /api/files/upload` runs the chunk loop
  (microseconds per chunk); monitor `envoy_http_lua_active_scripts` + gateway pod
  CPU, not memory (streaming holds ~1 chunk).
- **Authorino runs before Lua** — an unauthenticated upload gets 401 without
  entering the count loop (good). But do **not** enable `with_request_body` on an
  AuthConfig touching `/api/files/upload` — Authorino would buffer first and change
  the rejection order.
- **Rejection fires one chunk after 32 MiB**, not on the `Content-Length` header
  (which can lie); `x-rhcl-observed-bytes` shows exactly how many bytes Lua saw.
- **The cap only activates on `POST /api/files/upload`** — other endpoints need
  their own EnvoyFilter or an expanded path match.

## Cleanup

```bash
./scripts/cleanup.sh
# or: remove the EnvoyFilter and the timeout rule
oc -n openshift-ingress delete envoyfilter files-upload-streaming-cap
oc -n rhcl-apps patch httproute banking-api-connectivity --type=json -p '[{"op":"remove","path":"/spec/rules/7"}]'
```

## References

- [Gateway API GEP-1742](https://gateway-api.sigs.k8s.io/geps/gep-1742/) — per-rule timeouts.
- [Envoy Lua HTTP filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter) — `bodyChunks()` iterator + `respond()`.
- Istio EnvoyFilter — `applyTo: HTTP_FILTER` / `HTTP_ROUTE`; the EnvoyFilter needs
  `workloadSelector.labels` matching the gateway's `gateway.networking.k8s.io/gateway-name` label, or it is silently ignored.
