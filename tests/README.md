# PoC requirement test guide

This document is a **per-requirement walkthrough** for the RHCL/Kuadrant PoC.
For every requirement that this application helps validate it shows:

- **Goal** — what the requirement asks for, in one line.
- **Backend (curl)** — copy/paste commands you can run from any shell.
- **Frontend (PoC console)** — the exact tab + button to click in
  [`apps/frontend/mobile-bank`](frontend/mobile-bank/lib/poc_console.dart).
- **Expected result** — what success looks like.

> The matrix that lists each requirement against its endpoint is in
> [apps/README.md → PoC requirement coverage matrix](README.md#poc-requirement-coverage-matrix).
> This guide is the **operational** companion: how to actually test each one.

---

## 0. Prerequisites

All commands target the **PoC application running inside OpenShift** — the
backend (`banking-api`, two replicas / two versions) and the frontend
(`mobile-bank`) are deployed by the cluster automation and exposed through the
RHCL/Kuadrant Gateway. There is no local Quarkus or Flutter process involved.

What you need on your workstation:

- `oc` logged in to the target cluster and on the namespace where the apps run
- `curl` (any recent version), `jq`, and `grpcurl` for gRPC tests
- A browser to open the frontend and the **PoC console**

Discover the public URLs exposed by the gateway and store them as variables.
The exact resource names depend on the lab; the cluster automation always
creates one route/host per backend version plus one for the frontend:

```bash
# Adjust the namespace if needed
export NS=banking

# Backend v1 / v2 (REST, WebSocket, gRPC-Web all share the same host)
export BACKEND_V1=https://$(oc -n $NS get route banking-api-v1     -o jsonpath='{.spec.host}')
export BACKEND_V2=https://$(oc -n $NS get route banking-api-v2     -o jsonpath='{.spec.host}')
# Default "backend" used by most tests
export BACKEND=$BACKEND_V1

# Frontend (Flutter Web)
export FRONTEND=https://$(oc -n $NS get route mobile-bank          -o jsonpath='{.spec.host}')

# gRPC host:port for grpcurl (the route is TLS-terminated by the gateway)
export GRPC_HOST="$(oc -n $NS get route banking-api-v1 -o jsonpath='{.spec.host}'):443"

# Conventions used in every example
export CONSUMER=alice
export TRACE=poc-$(date +%s)
```

If the lab uses a single Gateway hostname with HTTPRoute path matching instead
of per-service routes, point `BACKEND` / `BACKEND_V2` at the gateway hostname
and keep the rest of the commands as-is.

Open the **PoC console**:

1. Open `$FRONTEND` in a browser.
2. Click the 🧪 (`Icons.science`) icon in the top-right corner.
3. The dashboard's "Backend URL" setting becomes the API base for every panel
   (default: same origin as the frontend; override to `$BACKEND` when needed).

Whenever an example asks you to _check the backend log_, use:

```bash
oc -n $NS logs deploy/banking-api-v1 -f | grep "$TRACE"
```

---

## Table of contents

| Phase                | Requirements                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A — Chaos / health   | [1](#req-1--circuit-breaker--health-driven-routing), [13](#req-13--per-route-timeouts), [22](#req-22--active-health-check-5xx-behavior), [25](#req-25--slow--partial-responses), [34](#req-34--structured-error-logs), [35](#req-35--error-log-size-limits)                                                                                                                                                                                                                                |
| B — Streaming bodies | [26](#req-26--body-streaming--max-body-size)                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| C — AI Gateway       | [33](#req-33--openai-compatible-api-surface), [37](#req-37--prompt-logging), [40](#req-40--token-counting-per-consumer), [43](#req-43--rag-context-injection), [60](#req-60--tokenratelimit-policy)                                                                                                                                                                                                                                                                                        |
| D — TLS / gRPC       | [47](#req-47--backend-tls-12--13--http2--grpc-bidi), [48](#req-48--grpc-backend-support), [49](#req-49--backend-mtls), [50](#req-50--tls-visibility--negotiated-parameters), [51](#req-51--peer-certificate-inspection), [52](#req-52--xfcc-propagation), [53](#req-53--forwarded-scheme--protocol-detection), [54](#req-54--http11-http2-grpc-grpc-web), [55](#req-55--tls-exposure-on-the-backend), [56](#req-56--backend-cert-chain-validation), [58](#req-58--hsts-on-https-responses) |
| E — MCP              | [21](#req-21--expose-rest-apis-as-mcp-servers), [59](#req-59--mcp-support)                                                                                                                                                                                                                                                                                                                                                                                                                 |
| F — Observability    | [4](#req-4--liveness--readiness-probes), [38](#req-38--opentelemetry-export), [41](#req-41--metrics-interface), [66](#req-66--request-tracing-correlation--access-log), [68](#req-68--sensitive-header-redaction-in-logs)                                                                                                                                                                                                                                                                  |
| G — Auth / identity  | [30](#req-30--proxy-with-full-request-access), [44](#req-44--request-enrichment), [67](#req-67--oauth2-introspection--scopes), [71](#req-71--oidc--jwt-enforcement)                                                                                                                                                                                                                                                                                                                        |
| Existing             | [5](#req-5--weighted-load-balancing-across-versions), [6](#req-6--header-based-routing), [7](#req-7--sticky-sessions--session-affinity), [14](#req-14--cors)                                                                                                                                                                                                                                                                                                                               |

---

## Phase A — Chaos / health

### Req 13 — Per-route timeouts

**Goal:** prove the gateway enforces request timeouts independently of the
backend's own behaviour.

**Backend (curl):**

```bash
# Backend takes ~3 s to answer; gateway timeout below 3 s should fire 504
time curl -i "$BACKEND/api/test/echo-error?status=200&delay=3000"
```

**Frontend (PoC console):** **Chaos** tab → _Echo error_ card → set
`status=200`, `delay=3000` → press _Send_. The result panel shows the request
duration and HTTP code; through a gateway with a `1500ms` timeout you'll see a
504/gateway error before the backend returns.

**Expected result:** without the gateway the call returns 200 after ~3 s; with
a `<3 s` gateway timeout, the gateway returns 504 while the backend log still
records the slow request.

---

### Req 22 — Active health-check 5xx behavior

**Goal:** force deterministic 5xx responses so the gateway's outlier
detection / passive health checks can be exercised.

**Backend (curl):**

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    "$BACKEND/api/test/echo-error?status=503&size=128"
done

# Mixed pattern via flaky endpoint
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    "$BACKEND/api/test/flaky?failRate=0.5"
done
```

**Frontend (PoC console):** **Chaos** tab → _Flaky burst_ card → set
`failRate=0.5`, `count=20`, press _Run burst_. The histogram shows the 200/503
mix; with the gateway in front, after a few 503s the instance should be ejected
from the pool.

**Expected result:** `/api/test/echo-error?status=503` always returns 503;
`/api/test/flaky?failRate=X` returns ~X fraction of 503s. Gateway logs/metrics
should show ejections.

---

### Req 25 — Slow / partial responses

**Goal:** validate behavior with delayed and oversized responses.

**Backend (curl):**

```bash
# 2 s delay, 256 KiB body
time curl -s -o /dev/null -w 'http=%{http_code} bytes=%{size_download}\n' \
  "$BACKEND/api/test/echo-error?status=200&delay=2000&size=262144"
```

**Frontend (PoC console):** **Chaos** tab → _Echo error_ card → set delay/size
and press _Send_. Result panel shows duration and bytes received.

**Expected result:** server holds the connection for the requested delay then
emits a payload of the requested size. Useful for tuning gateway buffers and
read timeouts.

---

### Req 34 — Structured error logs

**Goal:** every 5xx must be observable in the backend logs with enough context
(path, status, trace id, consumer) to be correlated upstream.

**Backend (curl):**

```bash
curl -s -H "x-flow-trace-id: $TRACE" \
     -H "x-consumer-id: $CONSUMER" \
     "$BACKEND/api/test/echo-error?status=503&delay=100&size=64" >/dev/null

# Now correlate the request in the Pod log
oc -n $NS logs deploy/banking-api-v1 --tail=200 | grep "$TRACE"
```

**Frontend (PoC console):** **Chaos** tab → _Echo error_ card with
`status=503`. Then go to **Observability** tab — the trace id used for the
request is shown so you can grep it in the backend log or your trace UI.

**Expected result:** WARN log line that includes the trace id, consumer,
target status and request duration.

---

### Req 35 — Error log size limits

**Goal:** large error bodies must not flood the logs.

**Backend (curl):**

```bash
# Ask for a 1 MiB error body — backend should still log only a truncated form
curl -s -o /dev/null -w 'bytes=%{size_download}\n' \
  "$BACKEND/api/test/echo-error?status=500&size=1048576"

# Confirm the log line is short
oc -n $NS logs deploy/banking-api-v1 --tail=20 | grep echo-error
```

**Frontend (PoC console):** **Chaos** tab → _Echo error_ card → set
`size=1048576`, `status=500`, _Send_. The HTTP response carries the full 1 MiB,
but the backend log line is truncated.

**Expected result:** wire payload is 1 MiB; the log line preview is short
(no body dump).

---

## Phase B — Streaming bodies

### Req 26 — Body streaming + max body size

**Goal:** demonstrate the RHCL-side controls for streaming traffic — a
gateway-enforced body cap (Envoy buffer filter) that returns **413 before**
the bytes reach the backend, and a per-route request timeout from the
Gateway API. The banking-api backend is treated as a black box: no Quarkus
tuning, no env vars on the deployment.

**Defaults applied by the lab** (see `automation/inventories/example/group_vars/all.yml`,
`apps_streaming_*` block):

- `apps_streaming_max_request_bytes = 33554432` (32 MiB body cap)
- `apps_streaming_upload_request_timeout = 60s` (per-route timeout)

**Backend (curl):**

```bash
# 1 MiB upload → 200 + sha256
head -c 1M /dev/urandom | curl -s -X POST --data-binary @- \
  -H 'content-type: application/octet-stream' \
  -H "api-key: $API_KEY" \
  $GATEWAY/api/files/upload

# 25 MiB upload → 200 (still under the 32 MiB cap)
head -c 25M /dev/urandom | curl -s -X POST --data-binary @- \
  -H 'content-type: application/octet-stream' \
  -H "api-key: $API_KEY" \
  $GATEWAY/api/files/upload

# 50 MiB upload → 413 + x-envoy-buffer-too-large
head -c 50M /dev/urandom | curl -i -X POST --data-binary @- \
  -H 'content-type: application/octet-stream' \
  -H "api-key: $API_KEY" \
  $GATEWAY/api/files/upload

# Download a 10 MiB synthetic payload in 256 KiB chunks
curl -s -o /tmp/blob.bin -w 'received=%{size_download}\n' \
  -H "api-key: $API_KEY" \
  "$GATEWAY/api/files/download?size=10485760&chunkSize=262144"
```

**Frontend (standalone):** open `tests/streaming-and-body-limits/index.html` in the browser,
set the gateway hostname + API key, pick a size (1 / 25 / 50 MiB) and
click **Upload**. The progress bar reacts to `XMLHttpRequest.upload.onprogress`;
50 MiB stops mid-way and the result panel shows the `x-envoy-buffer-too-large`
header — the RHCL punchline.

**Expected result:**
- 1 MiB / 25 MiB uploads → 200 with `{sha256, bytesReceived, durationMs}`.
- 50 MiB upload → **413 Payload Too Large** with `x-envoy-buffer-too-large: 33554432`
  (the bytes never reach the backend).
- Slow uploads (>60 s) → **408** or **504** from the HTTPRoute timeout.

**Runbook:** `tests/streaming-and-body-limits/README.md`. Validation script:
`tests/streaming-and-body-limits/scripts/validate.sh` (asserts all 5 cases). Manifests for
kubectl-only flow: `tests/streaming-and-body-limits/manifests/`.

---

## Phase C — AI Gateway

### Req 33 — OpenAI-compatible API surface

**Goal:** any OpenAI-shaped client can call the AI Gateway without code
changes.

All OpenAI mock paths are under `/api/v1` on `HTTPRoute/banking-api-connectivity`.
Req 33 manifests in [`req033/`](req033/) patch the AuthPolicy so
`/api/v1/models` is anonymous like chat completions (no extra HTTPRoute).

**Backend (curl):**

```bash
curl -s -X POST $BACKEND/api/v1/chat/completions \
  -H 'content-type: application/json' \
  -H "x-consumer-id: $CONSUMER" \
  -d '{"model":"banking-mock-gpt",
       "messages":[{"role":"user","content":"What is my balance?"}]}' | jq .
```

**Frontend (PoC console):** **AI** tab → leave _SSE stream_ off → press _Send_.
The "Answer" card shows the assistant text; "Token usage" chips update.

**Expected result:** JSON shape matches OpenAI: `id`, `object`, `model`,
`choices[].message.content`, `usage.{prompt,completion,total}_tokens`.

---

### Req 37 — Prompt logging

**Goal:** every AI request leaves an auditable record (truncated).

**Backend (curl):**

```bash
curl -s -X POST $BACKEND/api/v1/chat/completions \
  -H 'content-type: application/json' \
  -H "x-consumer-id: $CONSUMER" \
  -H "x-flow-trace-id: $TRACE" \
  -d '{"messages":[{"role":"user","content":"redact this very long prompt..."}]}' \
  > /dev/null

# Find the matching INFO line in the Pod log
oc -n $NS logs deploy/banking-api-v1 --tail=200 | grep "$TRACE"
```

**Frontend (PoC console):** **AI** tab → type any prompt, _Send_. Then look
at the backend terminal — the prompt preview line is correlated to the trace id
shown in the AI tab's _Result_ meta.

**Expected result:** one INFO line per AI call, with the consumer, model and
truncated prompt. Long prompts (>500 chars) are cut.

---

### Req 40 — Token counting per route (RHCL-native)

**Goal:** observe AI token usage **inside Kuadrant Limitador**, without any
backend Micrometer counter. The same `TokenRateLimitPolicy` that enforces
REQ 60 also emits the Prometheus counters consumed here. Per-consumer
breakdown uses gateway Envoy access logs (`x-consumer-id`) shipped to Loki.

**Backend (curl):**

```bash
# Generate some traffic
for c in alice bob charlie; do
  for i in $(seq 1 3); do
    curl -s -X POST $BACKEND/api/v1/chat/completions \
      -H 'content-type: application/json' \
      -H "x-consumer-id: $c" \
      -d '{
        "model": "banking-mock-gpt",
        "mock_usage": {
          "prompt_tokens": 20,
          "completion_tokens": 25
        },
        "messages":[{"role":"user","content":"hello"}]
      }' > /dev/null
  done
done

# Pull authorized tokens / calls directly from Limitador
oc -n kuadrant-system port-forward svc/limitador-limitador 18080:8080 &
PF=$!; sleep 2
curl -s http://localhost:18080/metrics | grep -E '^authorized_|^limited_'
kill $PF

# Per-consumer call counts from gateway access logs (Loki)
QUERY='sum by (consumer) (count_over_time({job="rhcl-gateway"} |= "RHCL_ACCESS" | regexp `consumer=(?P<consumer>[^ ]+)` | regexp `path=(?P<path>[^ ]+)` | path="/api/v1/chat/completions" | consumer!="-" [1h]))'
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$QUERY'''))")
oc -n rhcl-logging exec deploy/loki -- wget -qO- \
  "http://127.0.0.1:3100/loki/api/v1/query?query=${ENCODED}" \
  | jq '.data.result[] | {consumer: .metric.consumer, calls: .value[1]}'
```

**Frontend (PoC console):** **AI** tab → send a few prompts; the
**Observability → Scrape** tab now shows only the generic backend metrics
(`banking_transfers_total`, `http_server_requests_seconds_count`) and renders
a banner pointing to the Limitador-native dashboard for AI tokens.

**Interactive page:** [`tests/per-route-token-counting/index.html`](per-route-token-counting/index.html) generates
AI traffic, queries `authorized_hits` / `authorized_calls` /
`limited_calls` from Limitador through the Thanos Querier, and documents the
Loki/consumer Grafana path.

**Grafana:** apply [`tests/per-route-token-counting/manifests/`](per-route-token-counting/manifests/) on top of the
Req 41 Grafana stack. Dashboards:

- **RHCL AI Token Usage** — Limitador `authorized_hits` / `authorized_calls` /
  `limited_calls` (Prometheus via ServiceMonitor).
- **RHCL AI Consumer Access Logs** — per `x-consumer-id` AI call counts and
  HTTP 429 from gateway access logs (Loki via Alloy).

**Expected result:**
`authorized_hits{limitador_namespace="rhcl-apps/banking-api-connectivity"}`
grows by `9 × 45 = 405` after the loop above (`prompt+completion=45` tokens
per call) and `authorized_calls` grows by `9`. Loki shows three consumers
(`alice`, `bob`, `charlie`) with three calls each on
`/api/v1/chat/completions`.

---

### Req 43 — RAG context injection

**Goal:** confirm the AI endpoint accepts an injected context array (the
typical shape produced by a gateway/RAG plugin) and reports it back.

**Backend (curl):**

```bash
curl -s -X POST $BACKEND/api/v1/chat/completions \
  -H 'content-type: application/json' \
  -H "x-consumer-id: $CONSUMER" \
  -d '{
    "messages":[{"role":"user","content":"summarize my balance"}],
    "context":[
      {"text":"Account 12345 balance is 1500 BRL as of 2026-04-30."},
      {"text":"Last transfer: -200 BRL to EXTERNAL on 2026-04-29."}
    ]
  }' -i
```

Look for response headers:

```
x-context-items: 2
x-context-tokens: 27
```

and a top-level `"context": {"items":2,"tokens":27}` block in the JSON body.

**Frontend (PoC console):** **AI** tab → fill the _RAG context_ field with two
chunks separated by a blank line (or `---`). Press _Send_. The "Last call
performance" card shows the _context items_ chip; the _Result_ meta line shows
the `x-context-tokens` header value.

**Expected result:** the mock answer mentions that it "considered N context
chunks"; headers and JSON `context` block both report the same numbers.

---

### Req 60 — TokenRateLimit policy

**Goal:** the counter from req 40 is the input for an upstream
`TokenRateLimit` policy. We don't enforce limits in the backend but we make
them observable.

Standalone RHCL manifests for enforcing this with the mock OpenAI-compatible
endpoint live in [`req060/`](req060/). **Prerequisite:** apply
`tests/token-rate-limiting/manifests/10-authpolicy-connectivity-openai-access.yaml` so
`POST /api/v1/chat/completions` is anonymous on the connectivity route, then
`30-tokenratelimitpolicy.yaml`.

**Backend (curl):**

```bash
# Drive the counter past a chosen budget, then inspect
for i in $(seq 1 50); do
  curl -s -X POST $BACKEND/api/v1/chat/completions \
    -H 'content-type: application/json' \
    -H "x-consumer-id: heavy-user" \
    -d '{"messages":[{"role":"user","content":"long prompt..."}]}' > /dev/null
done

# Limitador counter (RHCL-native — not /q/metrics)
oc -n kuadrant-system exec deploy/limitador-limitador -- \
  curl -s http://localhost:8080/metrics | grep -E '^authorized_hits|^limited_calls'
```

**Frontend (PoC console):** **AI** tab → keep pressing _Send_; _Token usage
(cumulative)_ reflects the `usage` block in each response. When the gateway
policy enforces a limit, the UI shows `429s` incrementing and `RateLimit-*`
headers in the _Result_ meta line.

**Expected result:** `authorized_hits` grows in Limitador; Grafana dashboard
**RHCL AI Token Usage** reflects the route-level counter; TokenRateLimit policy
returns 429 with `RateLimit-Reset` headers that the AI tab surfaces.

---

## Phase D — TLS / gRPC

In the OpenShift PoC, **TLS is terminated at the gateway**. The Pod listens on
plain HTTP/2 (or h2c for gRPC) and trusts the gateway to inject
`x-forwarded-proto`, `x-forwarded-for` and `x-forwarded-client-cert` (XFCC)
headers. This is what `/api/tls/info` reports and what the
`HstsResponseFilter` keys off of.

When a test below talks about "the negotiated TLS version", that's the
handshake **between curl and the gateway** — not between the gateway and the
Pod. mTLS is configured on the gateway via Kuadrant `TLSPolicy` /
`AuthPolicy`; the backend simply observes the result through XFCC.

### Req 47 — Backend TLS 1.2 / 1.3 + HTTP/2 (+ gRPC bidi on banking-api)

**Goal:** prove the RHCL gateway connects to the backend over **TLS 1.2/1.3**
(not plain HTTP), and that HTTP/2 can be negotiated on that hop.

The **banking-api** already exposes HTTPS on **:8443** and `GET /api/tls/info`.
Req 47 adds a dedicated HTTPRoute (`backend-tls`) whose `backendRef` uses port
**8443** with `BackendTLSPolicy`. Full demo: [`tests/req047`](req047).

```bash
export NS=rhcl-apps
export TLS_HOST="$(oc get httproute backend-tls -n $NS -o jsonpath='{.spec.hostnames[0]}')"
```

**Backend (curl):**

```bash
# Via RHCL — banking-api reports negotiated TLS on the pod
curl -sk "https://${TLS_HOST}/api/tls/info" \
  | jq '{isSSL,tlsVersion,cipherSuite,alpn,instance}'

# Direct to the Service (inside the cluster)
oc run -n $NS tls-curl --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  -- curl -sk --http2 \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
    "https://banking-api-v1.${NS}.svc:8443/api/tls/info" | jq .

# Force TLS 1.2 / 1.3 against the Service
oc run -n $NS tls-openssl --rm -i --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --command -- sh -c '
    microdnf install -y openssl >/dev/null 2>&1
    echo | openssl s_client -connect banking-api-v1.'"${NS}"'.svc:8443 -tls1_2 2>/dev/null | grep Protocol
    echo | openssl s_client -connect banking-api-v1.'"${NS}"'.svc:8443 -tls1_3 2>/dev/null | grep Protocol
  '
```

**Frontend (PoC console):** [`tests/backend-tls-versions/index.html`](backend-tls-versions/index.html) →
_Fetch /api/tls/info_.

**gRPC bidi (banking-api, unchanged):**

```bash
oc -n $NS port-forward svc/banking-api-v1 8080:8080 &
grpcurl -plaintext -d @ localhost:8080 \
  io.gatewaysmashes.rhcl.grpc.BankingService/EchoStream <<'EOF'
{"text":"hello"}
{"text":"world"}
EOF
kill %1
```

**Expected result:** through RHCL, `/api/tls/info` returns `isSSL: true`,
`tlsVersion` is `TLSv1.2` or `TLSv1.3`, and `alpn` is often `h2` when HTTP/2
is negotiated. Both `openssl s_client` probes succeed. The gRPC bidi echo
returns one response per input message with a monotonic `sequence`.

---

### Req 48 — gRPC backend support

**Backend (curl/grpcurl):**

```bash
# Port-forward to talk gRPC directly to a Pod
oc -n $NS port-forward svc/banking-api-v1 8080:8080 &

# Unary
grpcurl -plaintext -d '{"api_version":"v1"}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary

# Server streaming
grpcurl -plaintext -d '{"interval_ms":500,"max_events":5}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth

kill %1
```

**Frontend (PoC console):** **gRPC-Web** tab → set `api_version=v1` →
_Call_. The "Result" chips show `http=200`, `grpc-status=0`, payload bytes;
the "Wire dump" card prints the framed response in hex.

**Expected result:** unary returns the same data as `/api/v1/accounts/summary`;
server streaming yields 5 events spaced 500 ms apart.

---

### Req 49 — Backend mTLS

In the OpenShift PoC, mTLS is enforced by the gateway via Kuadrant `TLSPolicy`
/ `AuthPolicy`. The gateway then forwards the parsed client identity to the
backend through the `x-forwarded-client-cert` (XFCC) header (see Req 52).
For a _direct-to-backend_ mTLS test, port-forward and provide a client cert
issued by a CA the Pod trusts (extracted from the cluster):

**Backend (curl):**

```bash
# Extract the test client cert/key into /tmp/tls (when the lab provides one)
oc -n $NS extract secret/banking-client-tls --to=/tmp/tls --confirm

oc -n $NS port-forward svc/banking-api-v1 8443:8443 &

# Without client cert
curl -sk https://localhost:8443/api/tls/info | jq .peerCertificates

# With client cert — peerCertificates is populated
curl -sk \
  --cert /tmp/tls/tls.crt \
  --key  /tmp/tls/tls.key \
  https://localhost:8443/api/tls/info | jq .peerCertificates

kill %1
```

**Frontend (PoC console):** **Auth** tab → _Whoami_ against
`$BACKEND`. Browsers don't expose the client cert chain
directly, but if a gateway is doing mTLS termination and forwarding XFCC, the
**mTLS — x-forwarded-client-cert (XFCC)** card will list the parsed pairs.

**Expected result:** `peerCertificates[]` contains the client cert
(subject/issuer/serial); without `--cert`, the array is empty.

---

### Req 50 — TLS visibility / negotiated parameters

**Backend (curl):**

```bash
curl -s \
  $BACKEND/api/tls/info | jq '{tlsVersion,cipherSuite,alpn,sessionId,scheme,isSSL}'
```

**Frontend (PoC console):** Use any browser dev-tools to inspect the
`/api/tls/info` response, or hit it from the **Observability** tab via the
trace generator (any GET works since the panel just shows headers).

**Expected result:**

```json
{
  "tlsVersion": "TLSv1.3",
  "cipherSuite": "TLS_AES_256_GCM_SHA384",
  "alpn": "HTTP_2",
  "sessionId": "…hex…",
  "scheme": "https",
  "isSSL": true
}
```

---

### Req 51 — Peer certificate inspection

**Backend (curl):**

```bash
# Direct-to-Pod via port-forward, with a client cert from the cluster
oc -n $NS extract secret/banking-client-tls --to=/tmp/tls --confirm
oc -n $NS port-forward svc/banking-api-v1 8443:8443 &

curl -sk \
  --cert /tmp/tls/tls.crt \
  --key  /tmp/tls/tls.key \
  https://localhost:8443/api/tls/info | jq '.peerCertificates'

kill %1
```

**Expected result:** an array; each entry has `subject`, `issuer`,
`serialHex`, `notBefore`, `notAfter`, `signatureAlgorithm`, `keyAlgorithm`.

---

### Req 52 — XFCC propagation

**Goal:** when a gateway terminates mTLS and forwards
`x-forwarded-client-cert`, the backend must see and expose it.

**Backend (curl) — simulate the gateway:**

```bash
curl -s $BACKEND/api/tls/info \
  -H 'x-forwarded-client-cert: By=spiffe://demo/acct;Hash=abc;Subject="CN=alice,O=demo";URI=spiffe://demo/alice' \
  | jq .xForwardedClientCert
```

**Frontend (PoC console):** **Auth** tab → press _Whoami_ (with the same XFCC
header injected by your gateway) → the **mTLS — x-forwarded-client-cert
(XFCC)** card splits the header on `;` and shows each pair on its own line.

**Expected result:** the JSON `xForwardedClientCert` is the verbatim header
value; the UI shows one parsed pair per row.

---

### Req 53 — Forwarded scheme / protocol detection

**Backend (curl):**

```bash
# Pretend the gateway terminated TLS in front of us
curl -s -i $BACKEND/api/tls/info \
  -H 'x-forwarded-proto: https' \
  -H 'x-forwarded-for: 203.0.113.10' | grep -iE 'strict-transport|x-forwarded|HTTP/'
```

**Frontend (PoC console):** **Auth** tab → _Whoami_ card shows the
`x-forwarded-*` map; **Observability** tab shows the response headers
including HSTS when the request scheme is detected as HTTPS.

**Expected result:** response includes `Strict-Transport-Security: max-age=31536000; includeSubDomains`
even on a plain HTTP listener, because `x-forwarded-proto=https` was honoured.

---

### Req 54 — HTTP/1.1, HTTP/2, gRPC, gRPC-Web

**Backend (curl):**

```bash
# HTTP/1.1
curl -sI --http1.1 $BACKEND/api/v1/accounts/summary | head -1

# HTTP/2 (Routes negotiate h2 by default)
curl -sI --http2 \
  $BACKEND/api/v1/accounts/summary | head -1

# gRPC — via port-forward to a Pod
oc -n $NS port-forward svc/banking-api-v1 8080:8080 &
grpcurl -plaintext -d '{"api_version":"v1"}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary | head
kill %1

# gRPC-Web (raw POST, application/grpc-web+proto)
printf '\x00\x00\x00\x00\x04\x0a\x02v1' | \
  curl -sS -X POST --data-binary @- \
    -H 'content-type: application/grpc-web+proto' \
    -H 'x-grpc-web: 1' \
    $BACKEND/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary -i | head
```

**Frontend (PoC console):** **gRPC-Web** tab — sends exactly the same wire
format from the browser. Result panel reports `http`, `grpc-status`, bytes,
duration.

**Expected result:** all four protocols return success on their respective
ports; `grpc-status: 0` in the gRPC-Web response headers.

---

### Req 55 — TLS exposure on the backend

**Backend (curl):**

```bash
curl -v \
  $BACKEND/api/v1/accounts/summary 2>&1 | grep -E 'SSL connection|TLSv|subject|issuer'
```

**Expected result:** TLS handshake succeeds against the gateway-presented
certificate; cert subject/issuer reflect the cluster's serving cert (e.g.
the `cert-manager` issuer used by the lab automation).

---

### Req 56 — Backend cert chain validation

When the gateway uses a publicly trusted (or cluster-trusted) cert, validation
works out of the box. To exercise the negative path against a self-signed
Pod cert, port-forward and force strict validation:

**Backend (curl):**

```bash
oc -n $NS port-forward svc/banking-api-v1 8443:8443 &

# Negative — strict validation against self-signed Pod cert must fail
curl -v https://localhost:8443/api/v1/accounts/summary 2>&1 | grep -E 'verify|SSL'

# Positive — trust the Pod CA extracted from the cluster
oc -n $NS extract secret/banking-api-tls --to=/tmp/tls --confirm
curl -v --cacert /tmp/tls/ca.crt \
  https://localhost:8443/api/v1/accounts/summary 2>&1 | grep 'SSL certificate verify ok'

kill %1
```

**Expected result:** without `--cacert`, curl reports
`SSL certificate problem: self signed certificate in certificate chain`; with
the extracted CA it prints `SSL certificate verify ok`.

---

### Req 58 — HSTS on HTTPS responses

**Backend (curl):**

```bash
# Direct HTTPS
curl -sI \
  $BACKEND/api/v1/accounts/summary | grep -i strict-transport

# Behind a TLS-terminating gateway (simulate via header)
curl -sI -H 'x-forwarded-proto: https' \
  $BACKEND/api/v1/accounts/summary | grep -i strict-transport
```

**Frontend (PoC console):** **Observability** tab → _Trace_ a `GET` and the
response headers list (in browser dev-tools network panel) shows the HSTS
header on every HTTPS response.

**Expected result:**

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

Plain HTTP (no `x-forwarded-proto: https`) does **not** include the header.

---

## Phase E — MCP

### Req 21 — Expose REST APIs as MCP servers

**Backend (curl):**

```bash
# List the exposed tools
curl -s $BACKEND/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq

# Invoke getAccountSummary
curl -s $BACKEND/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"getAccountSummary","arguments":{"version":"v1"}}}' | jq
```

**Frontend (PoC console):** there's no dedicated MCP tab; use any MCP client
(MCP Inspector, Claude Desktop, etc.) pointed at `$BACKEND/mcp`.
The Quarkus Dev UI is not exposed in the OpenShift build; for tool listing
use the JSON-RPC call above.

**Expected result:** `tools/list` returns `getAccountSummary`,
`simulateTransfer`, `getBackendMode`, `setBackendMode`. `tools/call` returns
the same payload as the equivalent REST endpoint.

---

### Req 59 — MCP Gateway

Use [mcp-gateway/README.md](mcp-gateway/README.md) for the dedicated Istio Gateway
(`rhcl-mcp-gateway`), MCP Gateway operator install, `MCPGatewayExtension`,
`MCPServerRegistration`, browser HTTPRoute, and curl checks against
`http://mcp-gateway.<zone>:8080/mcp` (broker-prefixed tools).

For a direct backend transport smoke test, use:

```bash
# Streamable HTTP (preferred, MCP 2025-03-26)
curl -s -X POST $BACKEND/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2025-03-26",
                 "capabilities":{},
                 "clientInfo":{"name":"curl","version":"0"}}}' | jq

# Legacy SSE (MCP 2024-11-05)
curl -N $BACKEND/mcp/sse
```

**Expected result:** `initialize` returns a server `protocolVersion` and the
list of declared capabilities; SSE keeps the connection open and emits
keepalive events.

---

## Phase F — Observability

### Req 4 — Liveness / readiness probes

**Backend (curl):**

```bash
curl -i $BACKEND/q/health/live      # → 200 (always, while JVM is up)
curl -i $BACKEND/q/health/ready     # → 200 normally, 503 when mode=down
```

**Frontend (PoC console):** **Chaos** tab → _Readiness_ dot polls
`/q/health/ready` continuously.

**Expected result:** liveness ignores backend mode; readiness flips with
`/api/test/mode`.

---

### Req 38 — OpenTelemetry export

The OTel exporter is configured by the Deployment manifest — environment
variables (`OTEL_*`) point at the cluster's OTel Collector / Tempo / Jaeger
endpoint. There is no "restart locally" step.

**Backend (curl):**

```bash
# Confirm the Pod has OTel wired up
oc -n $NS set env deploy/banking-api-v1 --list | grep -E '^OTEL_'

# Generate a span
curl -s -H "x-flow-trace-id: $TRACE" $BACKEND/api/v1/accounts/summary > /dev/null
```

**Frontend (PoC console):** **Observability** tab → _New trace_ generates a
fresh `x-flow-trace-id` and fires a request. The trace UI link template
(configurable, e.g. `https://jaeger.example/trace/{traceId}`) becomes a
clickable link.

**Expected result:** spans appear in your collector / Jaeger / Tempo with the
`x-flow-trace-id` recorded as a span attribute.

---

### Req 41 — Metrics interface

**Backend (curl):**

```bash
curl -s $BACKEND/q/metrics | head -40
curl -s $BACKEND/q/metrics | grep -E 'banking_transfers_total|http_server_requests_seconds_count'
```

**Frontend (PoC console):** **Observability** tab → _Scrape metrics_ fetches
`/q/metrics` and aggregates the relevant counters in a table.

**Expected result:** Prometheus exposition with `http_server_requests_*`,
`jvm_*`, `banking_transfers_total` series. AI token usage is in Limitador
(`authorized_hits`) — see REQ 40.

---

### Req 66 — Request tracing correlation + access log

**Backend (curl):**

```bash
curl -s -H "x-flow-trace-id: $TRACE" \
       -H "x-consumer-id: $CONSUMER" \
       $BACKEND/api/v1/accounts/summary > /dev/null

# In the Pod log (oc -n $NS logs deploy/banking-api-v1) you should see an access log line like:
# 127.0.0.1 - - [30/Apr/2026:10:00:00 +0000] "GET /api/v1/accounts/summary HTTP/1.1" 200 312 4 "weighted.apps.example.com" "poc-1730000000" "alice" "v1" "curl/8.0"
```

The fields, in order, come from the configured pattern:

```
%h %l %u %t "%r" %s %b %D "%{i,host}" "%{i,x-flow-trace-id}" "%{i,x-consumer-id}" "%{i,x-route-version}" "%{i,user-agent}"
```

The access log goes through the standard Quarkus logger
(`quarkus.http.access-log.log-to-file=false`) so every request shows up
on stdout — no volume mount or sidecar required, `oc logs` is enough.
The `%{i,host}` and `%{i,x-route-version}` fields make it possible to
spot, for the same backend pod, which `HTTPRoute` (e.g. `weighted.`,
`cors.`, `timeout.`) fronted the call and, when applicable, which
weighted backendRef the gateway picked (REQ 05).

**Frontend (PoC console):** **Observability** tab → _New trace_ → fire a
request → grep the trace id in the Pod log (oc -n $NS logs deploy/banking-api-v1) to find the matching access
log line.

**Expected result:** every request produces exactly one access log line that
includes the trace id, consumer and request duration in microseconds.

---

### Req 68 — Sensitive header redaction in logs

**Backend (curl):**

```bash
curl -s -H 'authorization: Bearer supersecrettoken12345' \
       -H 'cookie: session=ABCDEF123456' \
       -H 'x-api-key: live_xyz_987654321' \
       -H "x-flow-trace-id: $TRACE" \
       $BACKEND/api/whoami > /dev/null

# In the Pod log (oc -n $NS logs deploy/banking-api-v1), look for the audit logger:
# audit  req method=GET path=/api/whoami consumer=- traceId=poc-... headers={authorization=Bear***45, cookie=sess***56, x-api-key=live***21, ...}
# audit  res status=200 durationMs=3
```

Toggle the filter off (and back on) at runtime via the Deployment env:

```bash
oc -n $NS set env deploy/banking-api-v1 APP_AUDIT_LOG_ENABLED=false
# Revert
oc -n $NS set env deploy/banking-api-v1 APP_AUDIT_LOG_ENABLED=true
```

**Frontend (PoC console):** any panel that sends a bearer token (e.g. **Auth**
tab → set the bearer + _Whoami_) triggers the audit log. The actual masking
only shows in the Pod log (oc -n $NS logs deploy/banking-api-v1).

**Expected result:** no header value is ever logged in full — each is
truncated to `first4***last2`. Toggling `APP_AUDIT_LOG_ENABLED=false` removes
the lines entirely.

---

## Phase G — Auth / identity

### Req 30 — Proxy with full request access

**Backend (curl):**

```bash
curl -s -X POST $BACKEND/api/echo \
  -H 'content-type: application/json' \
  -H 'x-anything: yes' \
  -d '{"hello":"world"}' | jq
```

**Frontend (PoC console):** **Auth** tab → _Whoami_ (which uses
`/api/whoami`); for the more verbose `/api/echo` view, hit it directly with
curl.

**Expected result:** JSON containing the full request line, all headers,
cookies, query params and body.

---

### Req 44 — Request enrichment

**Goal:** when the gateway injects identity/claims headers, the backend echoes
them so we can confirm the enrichment.

**Backend (curl):**

```bash
curl -s -H 'authorization: Bearer fake' \
       -H 'x-consumer-id: alice' \
       -H 'x-jwt-sub: alice' \
       -H 'x-jwt-iss: https://issuer.example' \
       -H 'x-jwt-scope: read write' \
       -H 'x-forwarded-for: 203.0.113.42' \
       -H 'x-forwarded-proto: https' \
       $BACKEND/api/whoami | jq
```

**Frontend (PoC console):** **Auth** tab → set _Bearer_ and _x-consumer-id_,
press _Whoami_. The two cards _JWT headers_ and _Forwarded headers_ render the
maps; the new XFCC card highlights the parsed mTLS info.

**Expected result:** `jwt.{sub,iss,scope,...}` and `forwarded.{x-forwarded-*}`
maps populated with everything the gateway injected.

---

### Req 67 — OAuth2 introspection / scopes

**Backend (curl):**

```bash
# Simulating the AuthPolicy that introspects the token and forwards scopes
curl -s -H 'authorization: Bearer opaque-token-from-gateway' \
       -H 'x-jwt-scope: account:read transfer:write' \
       -H 'x-consumer-id: alice' \
       $BACKEND/api/whoami | jq '{authorization, jwt}'
```

**Frontend (PoC console):** **Auth** tab → set the bearer + consumer →
_Whoami_. The _JWT headers_ card shows the `x-jwt-scope` row.

**Expected result:** the backend never validates the bearer; it relies on the
`x-jwt-*` headers that introspection populated upstream. The response shows
both the original `authorization` header and the resolved scopes.

---

### Req 71 — OIDC / JWT enforcement

Same surface as req 67/44. To simulate end-to-end:

```bash
# A signed JWT (use jwt.io or a script). The gateway validates it and forwards
# the parsed claims as x-jwt-* headers; the backend just echoes them.
JWT='eyJhbGciOi...redacted...'

curl -s -H "authorization: Bearer $JWT" \
       -H 'x-jwt-sub: alice' \
       -H 'x-jwt-iss: https://issuer.example' \
       -H 'x-jwt-aud: banking-api' \
       -H 'x-jwt-exp: 9999999999' \
       $BACKEND/api/whoami | jq .jwt
```

**Frontend (PoC console):** **Auth** tab → paste the JWT in _Bearer_ and the
expected claim values in the trace headers (or rely on the gateway to inject
them). Press _Whoami_.

**Expected result:** the backend returns `jwt.sub`, `jwt.iss`, `jwt.aud`,
`jwt.exp` — proving that the AuthPolicy validated and forwarded the claims.
A request without a valid token shouldn't reach this endpoint at all (the
gateway would return 401 before forwarding).

---

## Existing capabilities (no new code)

### Req 5 — Weighted load balancing across versions

```bash
for i in $(seq 1 20); do
  curl -s $BACKEND/api/v1/accounts/summary | jq -r .instance
  curl -s $BACKEND_V2/api/v2/accounts/summary | jq -r .instance
done | sort | uniq -c
```

**Frontend:** dashboard _Settings_ → set _Flow mode_ to `Round robin (v1/v2)`
and refresh. The _Flow state_ card lights up either v1 or v2 per call.

---

### Req 6 — Header-based routing

```bash
curl -s -H 'x-route-version: v2' $BACKEND/api/echo | jq '.headers["x-route-version"]'
```

**Frontend:** dashboard sends `x-flow-mode` and `x-client-app` on every
request — the gateway can route on either.

---

### Req 7 — Sticky sessions / session affinity

```bash
# Same client → should keep hitting the same instance through the gateway
for i in $(seq 1 10); do
  curl -s -b 'JSESSIONID=abc123' $BACKEND/api/v1/accounts/summary | jq -r .instance
done | sort | uniq -c
```

**Frontend:** the _Flow state_ card shows which instance answered each call;
with affinity enabled the value is stable across refreshes.

---

### Req 14 — CORS

```bash
# Pre-flight from the frontend origin
curl -i -X OPTIONS $BACKEND/api/v1/accounts/summary \
  -H "origin: $FRONTEND" \
  -H 'access-control-request-method: GET' \
  -H 'access-control-request-headers: x-consumer-id,x-flow-trace-id' \
  | grep -i 'access-control'
```

**Frontend:** the dashboard at `$FRONTEND` runs on a different origin from
`$BACKEND` — every API call would fail without CORS. Working = CORS is
correctly configured.

**Expected result:** response includes
`Access-Control-Allow-Origin`, the requested method/headers in
`Access-Control-Allow-*`, and `Access-Control-Expose-Headers` lists
`grpc-status`, `x-instance`, `x-context-tokens`, etc.

---

## Out of scope here

The following requirements are validated **at the gateway / control-plane**
level, not in this application: 3, 8–12, 15–20, 23, 24, 27–29, 31, 32, 36, 39,
42, 45, 46, 57, 61–65, 69, 70, 72. They typically require RHCL/Kuadrant
policies (`AuthPolicy`, `RateLimitPolicy`, `DNSPolicy`, `TLSPolicy`,
`Gateway`/`HTTPRoute`), MetalLB, CoreDNS or cert-manager, none of which live
in this repo's `apps/` tree.
