# load-generator

A small Quarkus service that fires a **continuous, tunable stream of traffic** at
the RHCL/Kuadrant gateway, so the dashboards, access logs and traces always have
something to show. A configurable share of the traffic targets 5xx errors (via
the banking-api `/api/test/echo-error` endpoint), which is handy for demoing the
gateway's **Error Rate** panels, error-logging pipeline and alerting.

It follows the same format as the other backends (`banking-api`, `ledger-api`):
plain Quarkus REST, a `/q/health` probe and Prometheus metrics at `/q/metrics`.
The firing loop is a `quarkus-scheduler` tick; requests go out on the JDK
`HttpClient` over virtual threads, so there is no extra HTTP-client dependency.

## How it works

Every second the scheduler fires `rps` requests. For each request it rolls
against `errorRate`:

- **error** → `GET /api/test/echo-error?status={500|503|502}` (weighted toward 500)
- **healthy** → `GET /api/v1/accounts/summary` (authenticated 2xx) or `GET /api/echo` (public 2xx)

Authenticated requests carry the `api-key` header. Every request also sends an
`x-flow-trace-id` so it can be correlated in the gateway access logs and traces.

## Configuration (env vars)

| Env var                      | Default | Meaning                                                        |
| ---------------------------- | ------- | -------------------------------------------------------------- |
| `LOADGEN_TARGET_BASE_URL`    | *(empty)* | Gateway base URL, e.g. `https://banking-api-connectivity.<domain>`. **Required** — the generator stays idle until it is set. |
| `LOADGEN_API_KEY`            | *(empty)* | API key for the authenticated endpoints (from the banking-api api-key Secret). |
| `LOADGEN_RPS`                | `5`     | Requests per second.                                           |
| `LOADGEN_ERROR_RATE`         | `0.8`   | Share of requests aimed at 5xx (0.0–1.0).                      |
| `LOADGEN_AUTOSTART`          | `true`  | Start firing on boot (once a target URL is set).              |
| `LOADGEN_INSECURE_TLS`       | `true`  | Skip TLS verification (lab certs are self-signed / Let's Encrypt). |
| `LOADGEN_TIMEOUT_MS`         | `5000`  | Per-request timeout.                                           |
| `LOADGEN_MAX_IN_FLIGHT`      | `500`   | Ceiling on concurrent in-flight requests (excess ticks are skipped). |

## Control API

Retune the running generator without a redeploy:

| Method | Path                                | Description                                   |
| ------ | ----------------------------------- | --------------------------------------------- |
| `GET`  | `/loadgen/stats`                    | Live counters + per-status breakdown.         |
| `GET`  | `/loadgen/config`                   | Current configuration.                        |
| `POST` | `/loadgen/start`                    | Begin firing (409 if no target is set).       |
| `POST` | `/loadgen/stop`                     | Stop firing (counters kept).                  |
| `POST` | `/loadgen/reset`                    | Zero the counters.                            |
| `POST` | `/loadgen/config?rps=20&errorRate=0.5` | Retune rate / error share at runtime.      |

```bash
# watch it work
curl -s https://<loadgen-route>/loadgen/stats | jq

# dial to 20 req/s, 100% errors
curl -sX POST "https://<loadgen-route>/loadgen/config?rps=20&errorRate=1.0" | jq
```

## Build / run

```bash
# Local (points at any gateway)
LOADGEN_TARGET_BASE_URL=https://banking-api-connectivity.<domain> \
LOADGEN_API_KEY=<key> mvn quarkus:dev

# Container (same as the other backends: OpenShift BuildConfig)
oc start-build bc/load-generator --from-dir=apps/backend/load-generator -n rhcl-apps --wait
```

## Deploy

Deployed by the Ansible `apps` role (gated by `apps_load_generator_enabled`,
default `false` — it is a demo utility, off unless you ask for it). The
Deployment wires:

- `LOADGEN_TARGET_BASE_URL` to the banking-api gateway host,
- `LOADGEN_API_KEY` from the banking-api api-key Secret,

and exposes the control API through an OpenShift Route. Turn it on with
`-e apps_load_generator_enabled=true`.
