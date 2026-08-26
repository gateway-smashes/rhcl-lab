# PoC Applications

- Backend: `backend/banking-api`
- Ledger (downstream microservice, REQ 038 trace propagation): `backend/ledger-api`
- IP filter probe: `backend/ipfilter-php`
- Frontend: `frontend/mobile-bank`

## Local prerequisites

- Java 17 installed and active for the backend
- Maven 3.9+
- Flutter SDK

### Java setup with SDKMAN (recommended)

Install SDKMAN (if needed):

```bash
curl -s "https://get.sdkman.io" | bash
source "$HOME/.sdkman/bin/sdkman-init.sh"
```

```bash
cd apps/backend/banking-api
sdk env
```

List available Java distributions:

```bash
sdk list java
```

Install Java 17 (example with Red Hat build of OpenJDK):

```bash
sdk install java 17.0.12-tem
```

Set Java 17 as default:

```bash
sdk default java 17.0.12-tem
```

Validate active versions:

```bash
java -version
mvn -version
```

### Pin Java version per project with `.sdkmanrc`

The backend already includes `.sdkmanrc` in `apps/backend/banking-api`.

Use it with:

```bash
cd apps/backend/banking-api
sdk env
java -version
```

Optional (auto-load on directory change): set `sdkman_auto_env=true` in `~/.sdkman/etc/config`.

## Quick start

Backend v1:

```bash
cd apps/backend/banking-api
APP_INSTANCE_NAME=banking-api-v1 mvn quarkus:dev
```

Backend v2:

```bash
cd apps/backend/banking-api
APP_INSTANCE_NAME=banking-api-v2 mvn quarkus:dev -Dquarkus.http.port=8081
```

Frontend:

```bash
cd apps/frontend/mobile-bank
flutter create .
flutter pub get
flutter run -d chrome
```

IP filter probe:

```bash
cd apps/backend/ipfilter-php
php -S 0.0.0.0:8080 -t src
```

Notes:
- `flutter create .` is only required once to generate platform folders/files.
- If you run Flutter Web, backend CORS is already enabled in `apps/backend/banking-api/src/main/resources/application.properties`.

## API testing links (Swagger UI + endpoints)

Open Swagger UI and use `Try it out` to simulate `GET`/`POST` requests directly in the browser:

- v1 instance (port 8080): [http://localhost:8080/q/swagger-ui](http://localhost:8080/q/swagger-ui)
- v2 instance (port 8081): [http://localhost:8081/q/swagger-ui](http://localhost:8081/q/swagger-ui)

### Catálogo completo de endpoints

A coluna **Via Gateway?** indica se o endpoint está exposto pela `HTTPRoute banking-api-connectivity` (Kuadrant) — implica passar pelas policies de Auth + Plan + TLS. Endpoints marcados ✗ só são acessíveis pela `Route` direta do OpenShift (`banking-api-v1-rhcl-apps.apps...`) ou via port-forward.

#### Domain — Banking (negócio)

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| GET | `/api/v1/accounts/summary` | Saldos das contas (v1) | ✓ |
| GET | `/api/v2/accounts/summary` | Saldos das contas (v2) | ✓ |
| POST | `/api/v1/transfers` | Simulação de transferência (v1) | ✓ |
| POST | `/api/v2/transfers` | Simulação de transferência (v2) | ✓ |
| POST | `/api/v1/accounts/reset` | Zera saldos pra reiniciar uma demo | ✓ |
| GET | `/api/v1/cors` | Endpoint dedicado pra demo CORS (item 14) | ✓ |
| GET | `/api/v1/timeout?ms=` | Demora `ms` antes de responder — testa Timeout (item 13) | ✓ |
| GET | `/api/lb-test` | Mesmo backend do `/api/echo`, com peso v1/v2 — testa LB por peso (item 5) | ✓ |

#### Diagnóstico / inspeção

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| GET / POST | `/api/echo` | Eco da request (headers, cookies, params, body) | ✓ |
| GET | `/api/whoami` | Identidade injetada pelo gateway (`Authorization`, `x-consumer-id`, `x-jwt-*`, `x-forwarded-*`) | ✗ |
| GET | `/api/tls/info` | TLS negociado (versão, cipher, ALPN) + cadeia de cert do peer (item 47–53) | ✗ |

#### IP filter probe

The PHP probe is deployed separately from the banking API and is exposed
through its own HTTPRoute (`ipfilter`), default hostname
`ipfilter.<RHCL_ZONE_ROOT_DOMAIN>` (override with `APPS_IPFILTER_ROUTE_HOSTNAME`).
It shows the peer IP seen by the application, the `x-forwarded-for` chain,
and the effective client IP used by the IP ACL policy. The req 72 test package
([`tests/req072`](../tests/req072)) targets this route with three IP-ACL engines
(OPA, CEL, Envoy RBAC).

| Method | Endpoint | Purpose | Via Gateway? |
|---|---|---|---|
| GET | `/` | Browser UI for source-IP and `x-forwarded-for` inspection | ✓ |
| GET | `/api/ip` | JSON snapshot of `REMOTE_ADDR`, `x-forwarded-for`, `x-real-ip`, and related headers | ✓ |
| GET | `/healthz` | Container health check | ✗ |

#### Backend TLS (item 47)

The banking-api already exposes HTTPS on port **8443** (`APPS_BACKEND_TLS_ENABLED=true`,
`QUARKUS_PROFILE=tls`) and `GET /api/tls/info` reports the negotiated TLS parameters.
Req 47 adds a **dedicated HTTPRoute** (`backend-tls`, hostname `tls.<zone>`) whose
`backendRef` targets `:8443` with a `BackendTLSPolicy` — see [`tests/req047`](../tests/req047).
The main `banking-api-connectivity` route keeps using HTTP :8080 for all other endpoints.

| Method | Endpoint | Purpose | Via Gateway? |
|---|---|---|---|
| GET | `/api/tls/info` | Negotiated TLS version, cipher, ALPN, peer certs (items 47–53) | ✓ on `tls.<zone>` (HTTPS backend hop); also on direct Route / :8080 with `isSSL: false` |

#### Test / chaos (gated por `APP_TEST_ENDPOINTS_ENABLED=true`)

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| GET | `/api/test/echo-error?status=&delay=&size=` | Retorna o `status` HTTP pedido com delay/payload opcional | ✗ |
| GET | `/api/test/flaky?failRate=` | 200 ou 503 aleatório baseado em `failRate` + modo atual | ✗ |
| GET | `/api/test/mode` | Modo atual do backend (`healthy`/`degraded`/`down`) | ✗ |
| POST | `/api/test/mode` | Muda o modo: `{ "mode": "...", "failRate": 0.0-1.0 }` | ✗ |
| GET | `/api/test/propagate?target=&calls=` | Chama o microserviço `ledger-api` downstream (REQ 38 propagação de traces). `target`=`direct`\|`gateway`, `calls`=1..20 | ✓ (regra `/api/test`) |

#### Large body / streaming

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| POST | `/api/files/upload` | Streams o body, computa SHA-256 e retorna tamanho + duração (item 26) | ✗ |
| GET | `/api/files/download?size=&chunkSize=` | Payload sintético com tamanho/chunk customizáveis | ✗ |

#### AI (OpenAI-shaped, item 33)

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| GET | `/api/v1/models` | Lista o modelo mock (`banking-mock-gpt`) | ✓ |
| POST | `/api/v1/chat/completions` | Mock OpenAI Chat Completions. `Accept: text/event-stream` ativa SSE | ✓ |
| POST | `/api/v1/completions` | Mock legacy text completions with OpenAI-shaped `usage` accounting | ✓ |
| POST | `/api/v1/embeddings` | Mock embeddings response with prompt token accounting | ✓ |
| POST | `/api/v1/responses` | Mock Responses API object with input/output token accounting | ✓ |

Config (env): `OPENAI_MODE=mock` (default) ou `disabled` (503 em rotas AI); `OPENAI_DEFAULT_MODEL`, `OPENAI_STREAM_CHUNK_DELAY_MS`. Lógica em `io.gatewaysmashes.rhcl.ai.MockOpenAiChatService`.

Gateway: todos sob `PathPrefix /api/v1` em `banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}`. AuthPolicy anônima: [`tests/req033/manifests/`](../tests/req033/manifests/). Token rate limit em [`tests/req060/manifests/`](../tests/req060/manifests/) para todos os paths de chat completions acima.

#### WebSocket

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| WS | `/ws/live` | Feed de eventos em tempo real (`transfer.completed`, `balance.updated`) — itens 23/46 | ✓ |

#### MCP (item 59 / Sprint 3)

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| POST | `/mcp` | MCP server (Streamable HTTP, 2025-03-26). Tools: `getAccountSummary`, `simulateTransfer`, `getBackendMode`, `setBackendMode`. Exposed to clients via **MCP Gateway** on dedicated Gateway `rhcl-mcp-gateway` (req 59), not via `banking-api-connectivity`. | ✗ |
| GET | `/mcp/sse` | Transport SSE legado (mesmas tools) | ✓ |

#### Quarkus management (padrão)

| Método | Endpoint | Propósito | Via Gateway? |
|---|---|---|---|
| GET | `/q/health` | Liveness + readiness agregados | ✗ |
| GET | `/q/health/live` | Liveness probe — sempre 200 a menos que a JVM esteja morta | ✗ |
| GET | `/q/health/ready` | Readiness probe — 503 quando `mode=down` | ✗ |
| GET | `/q/metrics` | Prometheus scrape (`banking_*` counters + HTTP server metrics) | ✗ |
| GET | `/q/swagger-ui` | Swagger UI interativo | ✗ |
| GET | `/q/openapi` | OpenAPI spec (YAML por default; `?format=json` pra JSON) | ✗ |

#### gRPC (porta 8080, gRPC-Web habilitado)

| RPC | Propósito | Via Gateway? |
|---|---|---|
| `BankingService.GetSummary` | Mesmo dado de `/api/v1/accounts/summary` via gRPC (itens 48, 54) | ✓ |
| `BankingService.StreamHealth` | Stream server-side de eventos de health pra demos de L7 streaming | ✓ |
| `BankingService.EchoStream` | Bidi streaming — cliente envia `EchoMessage`, server eco com `sequence` (itens 47, 54) | ✓ |

> **Como expor endpoints `✗` via Gateway?** Adicionar uma regra (`rules[].matches`) na `HTTPRoute banking-api-connectivity` casando o path. Padrão atual é **opt-in por design**: só `/api/v1`, `/api/v2`, `/api/echo`, `/api/lb-test`, `/ws` passam pelas policies. MCP (`/mcp`) usa o **MCP Gateway** em `rhcl-mcp-gateway` (req 59). Veja `automation/roles/apps/templates/connectivity-httproute.yml.j2`.

## PoC validation endpoints

These endpoints exist to exercise RHCL/Kuadrant policies end-to-end. They are gated by `app.test-endpoints.enabled` (env `APP_TEST_ENDPOINTS_ENABLED`, default `true`). Disable in production overlays by setting it to `false`.

| Method | Endpoint | Purpose | Requirement IDs |
|---|---|---|---|
| GET | `/q/health/live` | Liveness probe (always 200 unless JVM is dead). | 4 |
| GET | `/q/health/ready` | Readiness probe; returns 503 when mode is `down`. | 1, 4 |
| GET | `/q/metrics` | Prometheus scrape (HTTP server metrics + `banking_transfers_total`). | 38, 40, 41 |
| GET | `/api/test/echo-error?status=&delay=&size=` | Returns the requested HTTP status, with optional delay (ms) and payload size (bytes). | 1, 13, 22, 25, 34, 35 |
| GET | `/api/test/flaky?failRate=` | Random 200/503 based on the requested fail rate combined with the current backend mode. | 1 |
| GET | `/api/test/mode` | Current `mode` (`healthy`/`degraded`/`down`) and `failRate`. | 1 |
| POST | `/api/test/mode` | Body `{ "mode": "...", "failRate": 0.0-1.0 }`. Mode `down` makes readiness fail. | 1 |
| GET | `/api/test/propagate?target=&calls=` | Calls the downstream `ledger-api` microservice to demonstrate trace propagation (`rhcl-gateway → banking-api → ledger-api`). `target`=`direct`\|`gateway`. Context propagated by the injected OTel Java agent. | 38 |
| GET | `/api/whoami` | Echoes `Authorization`, `x-consumer-id`, `x-jwt-*`, `x-auth-*` and `x-forwarded-*` headers injected by the gateway. The backend never validates them. | 30, 67, 71 |
| POST | `/api/v1/chat/completions` | OpenAI-shaped mock for AI Gateway routing/cost policies. Returns JSON by default; set `Accept: text/event-stream` for SSE token streaming. Backend emits no token counter itself — Kuadrant Limitador reads `response.body.usage.total_tokens` (REQ 60) and increments `authorized_hits` (REQ 40). | 2, 33, 37, 40, 60 |
| POST | `/api/v1/completions` | Legacy OpenAI text completions mock. Returns an OpenAI-shaped `usage` block; token accounting is performed by Kuadrant Limitador on the same route. | 33, 40 |
| POST | `/api/v1/embeddings` | OpenAI embeddings mock. Returns an OpenAI-shaped `usage` block; token accounting is performed by Kuadrant Limitador on the same route. | 33, 40 |
| POST | `/api/v1/responses` | OpenAI Responses API mock. Returns an OpenAI-shaped `usage` block; token accounting is performed by Kuadrant Limitador on the same route. | 33, 40 |
| POST | `/api/files/upload` | Streams the request body, computes SHA-256, returns size + duration. Use to validate large-body limits and timeouts on the gateway. | 26 |
| GET | `/api/files/download?size=&chunkSize=` | Returns a synthetic payload of the requested size (default 1 MiB). | 26 |
| gRPC | `BankingService.GetSummary` (`io.gatewaysmashes.rhcl.grpc`) | Same data as `/api/v1/accounts/summary` over gRPC. Available on the same port as REST (8080) via gRPC-Web (`application/grpc-web+proto`) thanks to `quarkus.grpc.server.use-separate-server=false`. | 48, 54 |
| gRPC | `BankingService.StreamHealth` | Server-streaming health events; useful for L7 streaming policies. | 48, 54 |
| gRPC | `BankingService.EchoStream` | Bidirectional streaming echo: every client `EchoMessage` is mirrored back with `server_recv_epoch_ms`, `instance` and a monotonic `sequence`. Validates HTTP/2 bidi proxying through the gateway. | 47, 54 |
| GET | `/api/tls/info` | Returns the negotiated TLS parameters (ALPN/HTTP version, TLS version, cipher suite, session id) and a parsed view of the peer certificate chain plus `x-forwarded-client-cert`. Useful for validating mTLS termination either at the backend (`tls` profile) or at an upstream gateway. | 47, 49, 50, 51, 52, 53 |
| POST | `/mcp` | Model Context Protocol server (Streamable HTTP, MCP 2025-03-26). Tools: `getAccountSummary`, `simulateTransfer`, `getBackendMode`, `setBackendMode`. Legacy SSE transport at `/mcp/sse`. | 21, 59 |

OpenTelemetry traces are emitted via OTLP/gRPC. The SDK is **disabled by default** so `mvn quarkus:dev` works without a collector. Enable with:

```bash
OTEL_SDK_DISABLED=false OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 mvn quarkus:dev
```

### Quick checks

```bash
# Phase A — circuit breaker / readiness flip
curl -i 'http://localhost:8080/api/test/echo-error?status=503&delay=2000&size=1024'
curl -X POST -H 'content-type: application/json' -d '{"mode":"down"}' \
  http://localhost:8080/api/test/mode
curl -i http://localhost:8080/q/health/ready   # expect 503
curl -X POST -H 'content-type: application/json' -d '{"mode":"healthy"}' \
  http://localhost:8080/api/test/mode

# Phase A — flaky backend for outlier detection
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    'http://localhost:8080/api/test/flaky?failRate=0.5'
done

# Phase F — Prometheus + transfer counter
curl -s http://localhost:8080/q/metrics | grep -E 'banking_transfers_total|http_server_requests'

# Phase G — claims echo (run after gateway introspection injects headers)
curl -H 'authorization: Bearer x' \
     -H 'x-consumer-id: alice' \
     -H 'x-jwt-sub: alice' \
     -H 'x-jwt-scope: read write' \
     http://localhost:8080/api/whoami
```

### Phase B — large bodies / streaming uploads & downloads

```bash
# Upload a 50 MiB random payload, get sha256 + duration back
head -c 50M /dev/urandom | curl -s -X POST --data-binary @- \
  -H 'content-type: application/octet-stream' \
  http://localhost:8080/api/files/upload

# Download a 10 MiB synthetic payload in 256 KiB chunks
curl -s -o /tmp/blob.bin -w 'received=%{size_download}\n' \
  'http://localhost:8080/api/files/download?size=10485760&chunkSize=262144'
```

### Phase C — AI Gateway mock (OpenAI-shaped)

```bash
# Model discovery (SDK health checks)
curl -s http://localhost:8080/api/v1/models | jq .

# JSON completion
curl -s -X POST http://localhost:8080/api/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-consumer-id: alice' \
  -d '{"model":"banking-mock-gpt","messages":[{"role":"user","content":"What is my balance?"}]}'

# SSE streaming completion (token chunks)
curl -N -X POST http://localhost:8080/api/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'accept: text/event-stream' \
  -d '{"messages":[{"role":"user","content":"Stream a long answer please"}]}'

# AI token usage is counted by Kuadrant Limitador (REQ 40) — see tests/req040/
```

### Phase D — gRPC and TLS / mTLS

The backend exposes a gRPC server on the **same port as the REST API** (8080,
shared via `quarkus.grpc.server.use-separate-server=false`) so that gRPC-Web
clients reach it without an extra listener. Under the `tls` profile an
additional HTTPS listener is enabled on `8443` with optional client-cert auth.
In OpenShift, the app automation enables this profile by default and mounts
OpenShift service serving certificates into the backend pods, so `/mcp` is also
available on HTTPS at `https://banking-api-v1.rhcl-apps.svc:8443/mcp`.

```bash
# Generate a CA + server cert + sample client cert (one-off)
./tls/generate-certs.sh

# Start the backend with HTTPS enabled
mvn -f apps/backend/banking-api/pom.xml quarkus:dev -Dquarkus.profile=tls

# Plain HTTPS
curl -v --cacert apps/backend/banking-api/tls/ca.crt \
  https://localhost:8443/api/v1/accounts/summary

# mTLS — client presents a certificate
curl -v --cacert apps/backend/banking-api/tls/ca.crt \
  --cert apps/backend/banking-api/tls/client.crt \
  --key  apps/backend/banking-api/tls/client.key \
  https://localhost:8443/api/v1/accounts/summary

# gRPC unary call (requires grpcurl) — served on the main port (8080)
grpcurl -plaintext -d '{"api_version":"v1"}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary

# gRPC server streaming (5 events, 500 ms apart)
grpcurl -plaintext -d '{"interval_ms":500,"max_events":5}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth

# gRPC bidirectional streaming — echoes every message back with server timing
grpcurl -plaintext -d '{"text":"hello"}
{"text":"world"}' \
  localhost:8080 io.gatewaysmashes.rhcl.grpc.BankingService/EchoStream
```

### Phase E — MCP server (Model Context Protocol)

The backend embeds a Quarkus MCP server (`quarkus-mcp-server-http` extension) that
exposes the banking domain as MCP tools. This validates **req 21** (expose REST
APIs as MCP servers) and **req 59** (MCP support) and gives the gateway something
concrete to register through `MCPServerRegistration`.

Endpoints:

- `POST /mcp` — Streamable HTTP transport (MCP 2025-03-26, preferred)
- `/mcp/sse` — legacy HTTP/SSE transport (MCP 2024-11-05)

Tools exposed:

| Tool | Arguments | Purpose |
|---|---|---|
| `getAccountSummary` | `version` (`v1`/`v2`, optional) | Same payload as `GET /api/v{1,2}/accounts/summary`. |
| `simulateTransfer` | `version`, `fromBank`, `toBank`, `amount`, `clientTraceId?` | Same as `POST /api/v{1,2}/transfers`; `EXTERNAL` is allowed as `toBank`. |
| `getBackendMode` | — | Mirrors `GET /api/test/mode`. |
| `setBackendMode` | `mode?`, `failRate?` | Mirrors `POST /api/test/mode` for chaos / readiness-flip demos. |

Quick check with the MCP Inspector or any MCP client:

```bash
# List tools (Streamable HTTP — JSON-RPC 2.0 over POST)
curl -s http://localhost:8080/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# Invoke getAccountSummary
curl -s http://localhost:8080/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"getAccountSummary","arguments":{"version":"v1"}}}'
```

In dev mode (`mvn quarkus:dev`) the tools are also testable from the Dev UI at
`http://localhost:8080/q/dev-ui` under the *MCP Server* card.

## PoC requirement coverage matrix

> **Looking for step-by-step test procedures?** See
> [apps/TESTING.md](TESTING.md) — it contains a per-requirement walkthrough
> with the exact `curl` command and the matching PoC console panel for every
> requirement listed below.

The table below lists every RHCL/Kuadrant PoC requirement that this application
helps validate. Requirements not listed here are **gateway-only** or
infrastructure concerns (HA, multi-cloud topology, DNS, RBAC on the OpenShift
console, certificate scale tests, Backstage integration, Grafana dashboards,
etc.) and do not require app changes.

Legend — *Source*: `existing` = already in the demo before the PoC work,
`new` = added by phases A–G.

| Req | Topic | Endpoint / artifact | Source |
|---|---|---|---|
| 1 | Circuit breaker / health-driven routing | `/q/health/ready`, `POST /api/test/mode`, `GET /api/test/flaky` | new (Phase A/F) |
| 2 | Semantic cache for AI Gateway | `POST /api/v1/chat/completions` (deterministic mock) | new (Phase C) |
| 4 | Liveness / readiness probes | `/q/health/live`, `/q/health/ready` | new (Phase F) |
| 5 | Weighted load balancing across versions | `/api/v1/*` and `/api/v2/*` returning `instance` + `backendTag` | existing |
| 6 | Header-based routing | `/api/echo` returns full request headers; `instance`/`backendTag` exposed by all endpoints | existing |
| 7 | Sticky sessions / session affinity | `instance` field in every response payload makes affinity observable | existing |
| 13 | Per-route timeouts | `GET /api/test/echo-error?delay=` | new (Phase A) |
| 14 | CORS | `quarkus.http.cors.*` in `application.properties` (allows `x-consumer-id`, `x-test-mode`, `x-jwt-*`, `x-forwarded-*`) | existing (extended) |
| 21 | Expose REST APIs as MCP servers | `POST /mcp` with `getAccountSummary` / `simulateTransfer` tools | new (Phase E) |
| 22 | Active-health-check 5xx behavior | `GET /api/test/echo-error?status=5xx` | new (Phase A) |
| 25 | Slow / partial responses | `GET /api/test/echo-error?delay=&size=` | new (Phase A) |
| 26 | Body streaming + max body size | `POST /api/files/upload`, `GET /api/files/download?size=&chunkSize=`, `quarkus.http.limits.max-body-size` | new (Phase B) |
| 30 | Proxy with full request access | `GET /`, `GET /ping` on host `req030.*` (standalone `req030-hello-world` backend); internal inspection via ext_authz + `RequestMirror` (lab uses sample `request-interceptor` — any custom interceptor service can replace it) | [`tests/req030`](../tests/req030) |
| 33 | OpenAI-compatible API surface | `GET /api/v1/models`, `POST /api/v1/chat/completions` (OpenAI request/response shape) | new (Phase C) |
| 34 | Structured error logs | `LOG.warnf(...)` on transfers + `/api/test/echo-error` | new (Phase A) |
| 35 | Error log size limits | `GET /api/test/echo-error?size=` | new (Phase A) |
| 37 | Prompt logging | `AiV1CompletionsResource` logs prompt at INFO (truncated to 500 chars) | new (Phase C) |
| 38 | OpenTelemetry export | `quarkus-opentelemetry` extension; OTLP endpoint via `OTEL_EXPORTER_OTLP_ENDPOINT` | new (Phase F) |
| 40 | Token counting per route | `usage` fields from OpenAI-shaped responses are read by Kuadrant Limitador's `TokenRateLimitPolicy` (REQ 60), which emits `authorized_hits` / `authorized_calls` / `limited_calls` counters scraped via ServiceMonitor → user-workload Prometheus → Grafana. Per-consumer call breakdown uses gateway Envoy access logs (`x-consumer-id`) → Alloy → Loki → Grafana. No banking-api Micrometer counter. | new (Phase C/F) |
| 41 | Metrics interface | `/q/metrics` (Prometheus scrape) | new (Phase F) |
| 44 | Request enrichment | `/api/whoami` echoes `x-jwt-*`, `x-consumer-id`, `x-forwarded-*` injected by the gateway | new (Phase G) |
| 43 | RAG context injection | `POST /api/v1/chat/completions` accepts an optional `context` array (chunks of strings or `{text}` objects); response headers `x-context-items`, `x-context-tokens` and a top-level `context` block report what was injected | new (Phase C) |
| 47 | Backend TLS 1.2 / 1.3 + HTTP/2 / gRPC bidi | `-Dquarkus.profile=tls` / HTTPS :8443; `GET /api/tls/info`; HTTPRoute `backend-tls` + `BackendTLSPolicy` for gateway→backend TLS; gRPC bidi `EchoStream` on :8080 | new (Phase D) |
| 48 | gRPC backend support | `BankingService.GetSummary` / `StreamHealth` / `EchoStream` exposed on the main HTTP port (8080) via gRPC + gRPC-Web | new (Phase D) |
| 49 | Backend mTLS | `tls` profile supports `TLS_CLIENT_AUTH=request`; sample client cert via `tls/generate-certs.sh`; `/api/tls/info` shows the parsed peer chain and `x-forwarded-client-cert` | new (Phase D) |
| 50 | TLS visibility / negotiated parameters | `/api/tls/info` returns `tlsVersion`, `cipherSuite`, ALPN/HTTP version, session id | new (Phase D) |
| 51 | Peer certificate inspection | `/api/tls/info` parses every `peerCertificates[]` entry (subject, issuer, serial, validity, signature/key algorithm) | new (Phase D) |
| 52 | XFCC propagation | `/api/tls/info.xForwardedClientCert` echoes the gateway-injected header verbatim; the PoC console renders it as a key=value list | new (Phase G) |
| 53 | Forwarded scheme / protocol detection | `/api/tls/info.forwardedProto` echoes `x-forwarded-proto`; HSTS is added when the request is HTTPS or `x-forwarded-proto=https` | new (Phase D) |
| 54 | HTTP/1.1, HTTP/2, gRPC, gRPC-Web | REST on HTTP/1.1; HTTP/2 enabled by `tls` profile; gRPC + gRPC-Web on port 8080; bidi `EchoStream` rpc | new (Phase D) |
| 55 | TLS exposure on the backend | `tls` profile, port 8443; OpenShift deployment mounts service serving certificates by default | new (Phase D) |
| 56 | Backend cert chain validation | CA + signed server cert generated by `tls/generate-certs.sh` (CN=localhost, SAN list) | new (Phase D) |
| 59 | MCP Gateway | `POST /mcp` brokered via MCP Gateway operator on dedicated Istio Gateway `rhcl-mcp-gateway` (`http://mcp-gateway.<zone>:8080/mcp`); tools prefixed `banking_`. See `tests/req059/` and `mcp_gateway-install.yml` | new (Phase E) |
| 60 | TokenRateLimit policy | `TokenRateLimitPolicy` reads mock `usage` blocks; Limitador exposes `authorized_hits` / `limited_calls` | new (Phase C) |
| 58 | HSTS on HTTPS responses | `HstsResponseFilter` adds `Strict-Transport-Security: max-age=31536000; includeSubDomains` whenever the request scheme is HTTPS or `x-forwarded-proto=https` | new (Phase D) |
| 66 | Request tracing correlation + access log | `clientTraceId` echoed by transfers; `traceId` returned by `/api/files/upload`; OTel spans emitted; Quarkus access log enabled (`quarkus.http.access-log.enabled=true`) with a pattern that includes `x-flow-trace-id`, `x-consumer-id`, status, bytes and request duration | existing + new (Phase F) |
| 67 | OAuth2 introspection / scopes | `/api/whoami` echoes `Authorization` and `x-jwt-scope` header injected after introspection | new (Phase G) |
| 71 | OIDC / JWT enforcement | `/api/whoami` echoes the `x-jwt-*` claim headers injected by the gateway | new (Phase G) |
| 72 | Source-IP ACLs | `backend/ipfilter-php`, HTTPRoute `ipfilter`, and AuthPolicy `ipfilter-ip-acl` isolate IP filtering from the banking API | new (Phase G) |
| 68 | Sensitive header redaction in logs | `RequestAuditFilter` writes structured `req`/`res` lines under the `audit` logger and masks `authorization`, `cookie`, `x-api-key`, `x-jwt-assertion`, `x-auth-token`, `proxy-authorization`, `set-cookie` (toggle: `app.audit-log.enabled` / `APP_AUDIT_LOG_ENABLED`) | new (Phase F) |

Out of scope for the apps (gateway / infra / control-plane only): **3, 8–12,
15–20, 23, 24, 27–29, 31, 32, 36, 39, 42, 45, 46, 57, 61–65, 69, 70**.

## Frontend behavior (current)

- App branding: **Red Hat Digital Bank** (dark theme by default)
- Settings are opened via the gear icon in the top-right corner
- `Flow mode` starts as `Primary only (v1)`
- Secondary backend input is shown only for:
  - `Round robin (v1/v2)`
  - `Secondary only (v2)`
- `Transfer` sends an external transfer with a random amount from:
  - `500`
  - `1000`
  - `5000`
- External transfers reduce the total balance
- Home screen auto-loads account data at startup
- The UI displays the **last 5 transfers** with amount, status, source, and time
- The UI displays a **Flow state** card with dotted routes and green active source highlighting
- The UI displays a **Live operations feed** card sourced from backend WebSocket events
- The UI displays a **Real-time transfer status** card showing the lifecycle PENDING → PROCESSING → COMPLETED via WebSocket
- Balance card auto-updates in real-time when `balance.updated` events arrive (no manual refresh needed)
- Transfer lifecycle is broadcast with delays: `transfer.pending` (0ms) → `transfer.processing` (600ms) → `transfer.completed` (1500ms) → `balance.updated` (2000ms)
- Frontend sends trace headers (`x-flow-trace-id`, `x-flow-mode`, `x-client-app`)
- Backend returns `backendTag` for origin mapping with or without RHCL/gateway in front

### PoC console (technical opt-in)

- Opened via the **flask icon** (`Icons.science`) in the top-right corner, next to the Settings button
- Routes to `PocConsolePage` (see [apps/frontend/mobile-bank/lib/poc_console.dart](frontend/mobile-bank/lib/poc_console.dart))
- The console derives the API base URL from the same backend URL configured for the dashboard
- Bearer token, `x-consumer-id` and the trace UI link template are persisted in `localStorage`
- Seven tabs map to the new backend phases:
  - **Chaos** (Phase A): toggles `mode` (healthy/degraded/down) and `failRate` via `/api/test/mode`, polls `/q/health/ready`, runs burst tests against `/api/test/flaky`, and exercises `/api/test/echo-error` with custom status/delay/size
  - **Streaming** (Phase B): uploads any file via `POST /api/files/upload` with live upload progress, downloads configurable-size payloads via `GET /api/files/download` and reports MB/s
  - **AI** (Phase C): `GET /api/v1/models` and `POST /api/v1/chat/completions` (JSON/SSE) on the connectivity gateway host. **Test all (3)** runs every OpenAI endpoint. Accumulates token counters, surfaces `RateLimit-*` headers and `429` responses; reports **TTFT (ms)** and **tokens/s** for SSE
  - **Auth** (Phase G): edits the bearer token / consumer headers and calls `/api/whoami` to render the JWT and forwarded-header maps, plus a dedicated **mTLS — x-forwarded-client-cert (XFCC)** card that splits the Envoy-style header into key=value pairs
  - **Observability** (Phase F): generates a fresh `x-flow-trace-id`, fires `/api/v1/accounts/summary`, exposes a configurable trace UI link template (`{traceId}` placeholder), and scrapes `/q/metrics` to aggregate `banking_transfers_total` and `http_server_requests_seconds_count`. AI token usage is no longer sourced from `/q/metrics` — see [REQ 40](../tests/req040.md) for the RHCL-native counter (`authorized_hits` from Kuadrant Limitador exposed via ServiceMonitor)
  - **WebSocket**: connects to `/ws/live`, sends ping frames every 5 s, computes the server-side roundtrip from the `pingTimestamp` echo and shows the rolling event log; auto-reconnects with backoff to validate WebSocket upgrade through the gateway
  - **gRPC-Web**: hand-encodes a `SummaryRequest` protobuf, sends it to `/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary` with `content-type: application/grpc-web+proto`, and reports HTTP status, `grpc-status`, `grpc-message`, payload bytes, duration and a hex dump of the response — useful to validate gRPC-Web translation/passthrough at the gateway
