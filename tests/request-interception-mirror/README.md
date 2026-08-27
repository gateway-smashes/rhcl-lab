---
title: Request interception and mirroring
summary: Intercept requests with external authorization and mirror traffic to a second backend.
category: Traffic & routing
status: done
---

# REQ 030 — Request interception (ext_authz + RequestMirror)

Manifests and tooling that demonstrate **request interception** on a
dedicated RHCL / Istio Gateway. Adapted from the
[rhcl-reference](https://github.com/dsferreira54/rhcl-reference) lab
(`helloWorldApp.requestInterceptor`) into the same standalone pattern used by
[req050](../mtls-ocsp-crl-revocation/README.md): numbered YAMLs + `deploy.sh`.

Two listeners on a **dedicated gateway** prove the two strategies separately:

| Listener | Hostname | Strategy | Proves |
|----------|----------|----------|--------|
| `http-extauthz` | `req030-extauthz.*` | Istio `AuthorizationPolicy` CUSTOM + `envoyExtAuthzHttp` | Envoy **calls** request-interceptor before forwarding to hello-world |
| `http-mirror` | `req030-mirror.*` | Gateway API `RequestMirror` filter | A **copy** of each request is sent to request-interceptor (async) |

## Prerequisites

- OpenShift cluster with **Service Mesh 3.x** (Istio/Sail) and Gateway API CRDs.
- The `istio` GatewayClass (Sail Operator / OSSM 3.x).
- `RHCL_ZONE_ROOT_DOMAIN` set to your cluster's DNS zone (e.g. `example.com`).
- Cluster can pull `docker.io/dsferreira54/request-interceptor:latest` from Docker Hub.

## What gets created

| File | Purpose |
|------|---------|
| `manifests/00-namespace.yaml` | `req030-gateway` and `req030-apps` namespaces |
| `manifests/10-gateway.yaml` | Dedicated Gateway with two HTTP listeners |
| `manifests/15-hello-world-app.yaml` | Hello World test backend (`testcontainers/helloworld`) |
| `manifests/16-request-interceptor-app.yaml` | Deployment, Service (`docker.io/dsferreira54/request-interceptor:latest`) |
| `manifests/20-httproute-extauthz.yaml` | HTTPRoute → hello-world (ext_authz path) |
| `manifests/21-httproute-mirror.yaml` | HTTPRoute with `RequestMirror` → request-interceptor |
| `manifests/25-referencegrant.yaml` | Cross-namespace Service refs from gateway → apps |
| `manifests/36-authorizationpolicy.yaml` | `AuthorizationPolicy` CUSTOM on extauthz hostname |
| `manifests/deploy-istio-extension-provider.sh` | Lists Istio CRs in the cluster, prompts which to patch, merges `envoyExtAuthzHttp` |
| `manifests/30-openshift-routes.yaml` | Edge Routes to the gateway Service |
| `manifests/deploy.sh` | One-shot deploy |
| `manifests/test-req030.sh` | Interactive validator |

## How it works

```
Client ──► OpenShift Route (edge TLS) ──► req030-interceptor-gateway (Envoy)
                                              │
                    ┌─────────────────────────┴─────────────────────────┐
                    │                                                     │
            http-extauthz listener                              http-mirror listener
                    │                                                     │
         AuthorizationPolicy CUSTOM                              RequestMirror filter
         ext_authz → request-interceptor                         copy → request-interceptor
                    │                                                     │
                    └─────────────────────────┬─────────────────────────┘
                                              ▼
                                        hello-world (req030-apps)
```

The **request-interceptor** app ([GitHub](https://github.com/dsferreira54/request-interceptor))
always allows traffic in PoC mode: it logs headers/body and returns `200 OK` with
inspection headers (`X-Inspected-By`, `X-Inspection-Result`).

## Setup

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster
cd tests/request-interception-mirror/manifests
./deploy.sh
```

## Verify

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com

# ext_authz listener
curl -sk -H 'X-Request-ID: extauthz-demo' \
  "https://req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}/"

# RequestMirror listener
curl -sk -H 'X-Request-ID: mirror-demo' \
  "https://req030-mirror.${RHCL_ZONE_ROOT_DOMAIN}/"

# Interceptor logs
oc -n req030-apps logs deployment/request-interceptor --tail=50

# Or run the bundled test
./test-req030.sh
```

## Cleanup

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com
cd tests/request-interception-mirror/manifests

envsubst < 30-openshift-routes.yaml | oc delete -f - --ignore-not-found
envsubst < 20-httproute-extauthz.yaml | oc delete -f - --ignore-not-found
envsubst < 21-httproute-mirror.yaml | oc delete -f - --ignore-not-found
oc delete -f 36-authorizationpolicy.yaml --ignore-not-found
oc delete -f 25-referencegrant.yaml --ignore-not-found
envsubst < 10-gateway.yaml | oc delete -f - --ignore-not-found
oc delete -f 15-hello-world-app.yaml 16-request-interceptor-app.yaml --ignore-not-found
oc delete -f 00-namespace.yaml --ignore-not-found

# Optional: remove extension provider from Istio CR (manual merge required)
```

## Related

- [REQ 050 — OCSP / CRL](../mtls-ocsp-crl-revocation/README.md) — same manifest/deploy pattern
- [REQ 051 / 056 — mTLS gateway](../gateway-mtls-enforcement/README.md) — dedicated gateway pattern
- Ansible integration: `automation/roles/apps/templates/req030-*.yml.j2`

## Requirement context

## Requirement demonstrated

| Item | Requirement |
|------|-------------|
| **30** | Proxy with full request access — the gateway/interceptor can inspect the complete HTTP request (headers, body, metadata) before or alongside forwarding to the backend. |

## Target service

Dedicated test stack — **not** the shared `banking-api-v1` backend.

| Component | Namespace | Hostname / endpoint |
|-----------|-----------|---------------------|
| `hello-world` | `req030-apps` | Backend for both strategies (`GET /`, `GET /ping`) |
| `request-interceptor` | `req030-apps` | Internal inspection service (ext_authz + mirror target) |
| `req030-interceptor-gateway` | `req030-gateway` | Two listeners — see below |

| Listener | Hostname | Strategy |
|----------|----------|----------|
| `http-extauthz` | `req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}` | External authorization (blocking check) |
| `http-mirror` | `req030-mirror.${RHCL_ZONE_ROOT_DOMAIN}` | Request mirroring (async copy) |

## Architecture overview

```
                  ┌──────────────────────────────────────┐
    client ─TLS─► │  OpenShift Route (edge termination)  │
                  └──────────────────┬───────────────────┘
                                     │
                  ┌──────────────────▼───────────────────┐
                  │  req030-interceptor-gateway (Envoy)  │
                  │  GatewayClass: istio                 │
                  └──────────┬─────────────┬─────────────┘
                             │             │
               http-extauthz │             │ http-mirror
                             │             │
              ┌──────────────▼──┐    ┌─────▼──────────────┐
              │ Authorization   │    │ HTTPRoute          │
              │ Policy CUSTOM   │    │ RequestMirror      │
              │ ext_authz       │    │ filter             │
              └──────┬──────────┘    └─────┬──────────────┘
                     │                     │ (async copy)
                     ▼                     ▼
              ┌────────────────────────────────────┐
              │  request-interceptor (req030-apps) │
              │  logs + always-allow in PoC mode   │
              └──────────────────┬─────────────────┘
                                 │ (ext_authz path only blocks if interceptor denies)
                                 ▼
              ┌──────────────────────────────────┐
              │  hello-world (req030-apps)       │
              └──────────────────────────────────┘
```

### Components

- **Gateway** (`req030-interceptor-gateway`) — dedicated ingress for item 30; two HTTP listeners isolate the two strategies.
- **HTTPRoute** (`req030-extauthz-route`) — routes extauthz hostname to `hello-world`; no mirror filter.
- **HTTPRoute** (`req030-mirror-route`) — routes mirror hostname to `hello-world` with a `RequestMirror` filter pointing at `request-interceptor`.
- **AuthorizationPolicy** (`req030-ext-authz`) — `action: CUSTOM` on the gateway; scoped to the extauthz hostname only; triggers Envoy `ext_authz` HTTP call.
- **Istio CR extension provider** (`req030-request-interceptor`) — `envoyExtAuthzHttp` entry merged into the selected Istio CR; points at `request-interceptor.req030-apps.svc.cluster.local:8080` with `pathPrefix: /check`.
- **ReferenceGrant** (`req030-gateway-to-apps`) — allows HTTPRoutes in `req030-gateway` to reference Services in `req030-apps`.
- **hello-world Deployment/Service** — minimal backend (`docker.io/testcontainers/helloworld:1.3.0`).
- **request-interceptor Deployment/Service** — interceptor image `docker.io/dsferreira54/request-interceptor:latest` ([source](https://github.com/dsferreira54/request-interceptor)).

## External authorization vs RequestMirror

### External authorization (`http-extauthz`)

Envoy **must** call the interceptor and receive an allow/deny before the request
reaches hello-world. Configured via:

1. `meshConfig.extensionProviders` → `envoyExtAuthzHttp` (Istio CR patch)
2. `AuthorizationPolicy` with `action: CUSTOM` and `provider.name` matching the extension provider

Use when interception can **block** traffic (authz, WAF, policy engine).

### RequestMirror (`http-mirror`)

Envoy sends a **fire-and-forget copy** of the request to the interceptor while
the original proceeds to hello-world. Configured via the Gateway API
`RequestMirror` filter on the HTTPRoute.

Use for **async observability** (logging, SIEM, shadow traffic) without adding
latency to the critical path.

### Both together

This lab deploys **separate hostnames** so each strategy can be validated
independently. In production you might combine them on one route; here we keep
them isolated for clarity (same approach as req050's separate CRL/OCSP listeners).

| Aspect | ext_authz | RequestMirror |
|--------|-----------|---------------|
| Blocks request? | Yes (if interceptor denies) | No |
| Latency impact | Adds round-trip to interceptor | Minimal (async) |
| Config surface | Istio CR + AuthorizationPolicy | HTTPRoute filter only |
| Body visibility | Yes (`includeRequestBodyInCheck`, max 8192 B) | Full request copied |

## How request interception is done

### External authorization path

| Step | What happens |
|------|--------------|
| 1 | Client calls `https://req030-extauthz.<zone>/` |
| 2 | Envoy matches `AuthorizationPolicy` rule for that host |
| 3 | Envoy POSTs to `http://request-interceptor:8080/check/...` with headers + body (up to 8192 B) |
| 4 | Interceptor returns `200` + `X-Inspected-By` headers |
| 5 | Envoy forwards to `hello-world:8080` |

Key fields:

- `extensionProviders[].envoyExtAuthzHttp.pathPrefix: /check` — client `/` becomes `/check/` on the interceptor
- `AuthorizationPolicy.spec.rules[].to[].operation.hosts` — scopes CUSTOM action to extauthz hostname only

### RequestMirror path

| Step | What happens |
|------|--------------|
| 1 | Client calls `https://req030-mirror.<zone>/` |
| 2 | Envoy applies `RequestMirror` filter → duplicate to `request-interceptor` |
| 3 | Original request proceeds to `hello-world` without waiting for mirror response |

Key field: `HTTPRoute.spec.rules[].filters[].type: RequestMirror`.

## Inputs / outputs (validation payload)

```bash
curl -sk -X POST "https://req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}/" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token' \
  -H 'X-Request-ID: req030-demo-001' \
  -d '{"hello":"world","item":30}'
```

**Expected:**

- HTTP `200` from hello-world (plain text greeting or `200 OK`).
- Interceptor logs show method, URI, headers, body, and `X-Request-ID: req030-demo-001`.
- On ext_authz path, interceptor response headers may be propagated upstream (`X-Inspected-By`, `X-Inspection-Result`, `X-Request-Interceptor-Mode`).

## Known limitations

| Topic | Limitation |
|-------|------------|
| ext_authz body size | Only first **8192 bytes** sent to interceptor (`maxRequestBytes`) |
| RequestMirror | Fire-and-forget — mirror failures do not fail the client request |
| Istio CR ownership | Istio CR is operator-managed; extension provider uses merge-patch (never replace the full list) |
| Image pull | Cluster must reach Docker Hub for `docker.io/dsferreira54/request-interceptor:latest` |
| PoC interceptor | Always allows — production interceptors may return `403` |

## Manifests (reference render)

| File | Resource | Purpose | Automation source |
|------|----------|---------|-------------------|
| [`request-interception-mirror/manifests/00-namespace.yaml`](request-interception-mirror/manifests/00-namespace.yaml) | Namespace ×2 | `req030-gateway`, `req030-apps` | Manual manifests only |
| [`request-interception-mirror/manifests/10-gateway.yaml`](request-interception-mirror/manifests/10-gateway.yaml) | Gateway | Dedicated gateway, two HTTP listeners | `connectivity-gateway.yml.j2` (pattern only) |
| [`request-interception-mirror/manifests/15-hello-world-app.yaml`](request-interception-mirror/manifests/15-hello-world-app.yaml) | Deployment, Service | Test backend | `req030-hello-world-*.yml.j2` |
| [`request-interception-mirror/manifests/16-request-interceptor-app.yaml`](request-interception-mirror/manifests/16-request-interceptor-app.yaml) | Deployment, Service | Interceptor app (`docker.io/dsferreira54/request-interceptor:latest`) | `req030-request-interceptor-*.yml.j2` |
| [`request-interception-mirror/manifests/20-httproute-extauthz.yaml`](request-interception-mirror/manifests/20-httproute-extauthz.yaml) | HTTPRoute | ext_authz listener → hello-world | `req030-httproute.yml.j2` (mirror filter omitted) |
| [`request-interception-mirror/manifests/21-httproute-mirror.yaml`](request-interception-mirror/manifests/21-httproute-mirror.yaml) | HTTPRoute | mirror listener with RequestMirror | `req030-httproute.yml.j2` |
| [`request-interception-mirror/manifests/25-referencegrant.yaml`](request-interception-mirror/manifests/25-referencegrant.yaml) | ReferenceGrant | Cross-namespace backend refs | Manual manifests only |
| [`request-interception-mirror/manifests/36-authorizationpolicy.yaml`](request-interception-mirror/manifests/36-authorizationpolicy.yaml) | AuthorizationPolicy | CUSTOM ext_authz on extauthz host | `req030-authorizationpolicy.yml.j2` |
| [`request-interception-mirror/manifests/deploy-istio-extension-provider.sh`](request-interception-mirror/manifests/deploy-istio-extension-provider.sh) | Istio CR patch | Lists cluster Istio CRs, prompts selection, merges `envoyExtAuthzHttp` | `req030-istio-extension-provider.yml.j2` + `install.yml` merge logic |
| [`request-interception-mirror/manifests/30-openshift-routes.yaml`](request-interception-mirror/manifests/30-openshift-routes.yaml) | Route ×2 | Edge TLS to gateway Service | Manual manifests only |
| [`request-interception-mirror/manifests/deploy.sh`](request-interception-mirror/manifests/deploy.sh) | — | One-shot deploy orchestration | Manual manifests only |

## Apply

### Standalone manifests (recommended for isolated demo)

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com
cd tests/request-interception-mirror/manifests
./deploy.sh
```

### Ansible batch (integrated with main RHCL apps gateway)

```bash
export APPS_REQ030_ENABLED=true
cd automation
ansible-playbook playbooks/apps-install.yml
```

The Ansible path adds req030 to the **shared** connectivity gateway (`req030.<zone>`)
with both RequestMirror and ext_authz on a single hostname. The standalone
manifests in `tests/request-interception-mirror/` use a **dedicated gateway** and **split hostnames**
for clearer validation.

## Validate

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com
cd tests/request-interception-mirror/manifests
./test-req030.sh
```

Manual check:

```bash
curl -sk "https://req030-extauthz.${RHCL_ZONE_ROOT_DOMAIN}/"
curl -sk "https://req030-mirror.${RHCL_ZONE_ROOT_DOMAIN}/"
oc -n req030-apps logs deployment/request-interceptor --tail=30
```

## Expected evidence

```bash
# Workloads ready
oc -n req030-apps get deploy hello-world request-interceptor
oc -n req030-gateway get gateway req030-interceptor-gateway

# HTTPRoutes accepted
oc -n req030-gateway get httproute

# Extension provider present (replace namespace/name with your selection)
oc get istio -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{": "}{.spec.values.meshConfig.extensionProviders[*].name}{"\n"}{end}'

# Interceptor logs contain structured request dump
oc -n req030-apps logs deployment/request-interceptor --tail=20 | grep -E 'REQUEST|X-Request-ID'
```

## Success criteria

1. `hello-world` and `request-interceptor` Deployments are Available in `req030-apps`.
2. `req030-interceptor-gateway` is Programmed with listeners `http-extauthz` and `http-mirror`.
3. `https://req030-extauthz.<zone>/` returns HTTP 200.
4. `https://req030-mirror.<zone>/` returns HTTP 200.
5. `request-interceptor` logs show traffic from **both** hostnames after validation curls.
6. `extensionProviders` in Istio CR includes `req030-request-interceptor`.

## Cleanup

### Standalone manifests

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com
cd tests/request-interception-mirror/manifests

envsubst < 30-openshift-routes.yaml | oc delete -f - --ignore-not-found
envsubst < 20-httproute-extauthz.yaml | oc delete -f - --ignore-not-found
envsubst < 21-httproute-mirror.yaml | oc delete -f - --ignore-not-found
oc delete -f 36-authorizationpolicy.yaml --ignore-not-found
oc delete -f 25-referencegrant.yaml --ignore-not-found
envsubst < 10-gateway.yaml | oc delete -f - --ignore-not-found
oc -n req030-apps delete -f 15-hello-world-app.yaml 16-request-interceptor-app.yaml --ignore-not-found
oc delete -f 00-namespace.yaml --ignore-not-found
```

### Ansible

```bash
export APPS_REQ030_ENABLED=false
cd automation
ansible-playbook playbooks/apps-install.yml
```

## Relationship with other requirements

- **Item 50 / 51 / 56** — same standalone gateway + `deploy.sh` manifest pattern; those items focus on mTLS/revocation, not request interception.
- **Item 44** — request enrichment (identity headers injected upstream); item 30 focuses on **inspection** of the raw request.
- **Item 54** — upstream HTTP protocol selection; orthogonal to interception.
- Ansible `req030-*` templates — integrated path on the shared connectivity gateway; manifests here are the isolated, customer-validated layout.
