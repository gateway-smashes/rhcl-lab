---
title: gRPC backends
summary: "Runbook: reach API backends over gRPC through the Gateway API (GRPCRoute)."
category: Traffic & routing
status: done
---

# gRPC backends

Full walkthrough for reaching API backends over **gRPC** through the gateway.

## What it demonstrates

RHCL / Kuadrant (via Istio / Envoy) supports **gRPC** communication with
backends through the gateway, using HTTP/2 as the transport. gRPC is routed by a
standard Gateway API **HTTPRoute** — the primary approach here, integrated with
Kuadrant policies. A complementary example uses a `v1` (GA) **GRPCRoute** — see
[Complementary example: GRPCRoute](#complementary-example-grpcroute) and the
comparison in [HTTPRoute vs GRPCRoute for gRPC](#httproute-vs-grpcroute-for-grpc).

| Mode | Transport | How it works |
|------------|-----------|---------------|
| **Native gRPC (unary)** | HTTP/2 (h2c) | Client sends a request to `/package.Service/Method`; Envoy connects to the backend over HTTP/2 |
| **gRPC server-streaming** | HTTP/2 (h2c) | Multiple responses over a single HTTP/2 connection |
| **gRPC bidirectional** | HTTP/2 (h2c) | Streams in both directions (client and server) |
| **gRPC-Web** | HTTP/1.1 or HTTP/2 | Content-type `application/grpc-web+proto`; browser-compatible |

### Architecture

```
┌──────────────┐       ┌─────────────────────┐       ┌──────────────────────────┐
│  grpcurl /   │       │   RHCL Gateway      │       │  req048-banking-api      │
│  curl        │──────▶│   (Envoy)           │──────▶│  :8080 (gRPC + REST)     │
│  (client)    │ HTTPS │   Listener:req048   │ H2C   │  appProtocol: h2c        │
└──────────────┘  H2   └─────────────────────┘       └──────────────────────────┘
                         hostname:                     Namespace: req048-grpc
                         req048-grpc.<domain>
```

### Protocol Buffers service

The backend implements the `io.gatewaysmashes.rhcl.grpc.BankingService` service with
these RPCs:

| RPC | Type | Description |
|-----|------|-------------|
| `GetSummary` | Unary | Returns an account summary |
| `StreamHealth` | Server streaming | Emits periodic health events |
| `EchoStream` | Bidirectional | Bidirectional echo to validate HTTP/2 framing |

## Prerequisites

| Component | Check |
|---|---|
| OpenShift 4.21 | `oc version` |
| RHCL / Kuadrant installed | `oc get kuadrant -n kuadrant-system` |
| Gateway configured | `oc -n openshift-ingress get gateway` |
| ImageStream `banking-api` in `rhcl-apps` | `oc -n rhcl-apps get is banking-api` |
| `grpcurl` on the workstation | `grpcurl --version` |
| `curl` and `jq` | `curl --version && jq --version` |

> **Note:** if `grpcurl` is unavailable, the gRPC-Web validation via `curl` still
> works. To install: https://github.com/fullstorydev/grpcurl/releases

### Environment variables

```bash
# Cluster domain (auto-detected by the script)
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# gRPC service hostname
export HOST="req048-grpc.${CLUSTER_DOMAIN}"
```

### Technical approach

The requirement is met by combining:

1. **`appProtocol: kubernetes.io/h2c`** on the Service — tells Envoy / Istio to
   use HTTP/2 cleartext to connect to the backend (required for native gRPC).
2. **HTTPRoute** with `PathPrefix: /` — routes all traffic (including gRPC paths
   like `/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary`) with no rewrite.
3. **Dedicated Gateway listener** with hostname `req048-grpc.<domain>` — isolates
   the gRPC traffic.
4. **Quarkus backend** with `use-separate-server=false` — gRPC and REST share
   port 8080.

## Files

| Path | Purpose |
| --- | --- |
| [`manifests/00-namespace.yaml`](manifests/00-namespace.yaml) | Namespace `req048-grpc` |
| [`manifests/01-rolebinding-image-pull.yaml`](manifests/01-rolebinding-image-pull.yaml) | Cross-namespace image-pull permission |
| [`manifests/02-deployment.yaml`](manifests/02-deployment.yaml) | banking-api Deployment with gRPC |
| [`manifests/03-service-grpc.yaml`](manifests/03-service-grpc.yaml) | Service with `appProtocol: kubernetes.io/h2c` |
| [`manifests/04-httproute.yaml`](manifests/04-httproute.yaml) | HTTPRoute for gRPC |
| [`manifests/05-grpcroute.yaml`](manifests/05-grpcroute.yaml) | GRPCRoute — complementary example (matching by gRPC service) |
| [`manifests/06-envoyfilter-grpc-streaming.yaml`](manifests/06-envoyfilter-grpc-streaming.yaml) | Disables the request buffer (from the streaming-and-body-limits item) on the req048 vhosts — required for gRPC reflection / streaming |
| [`scripts/apply.sh`](scripts/apply.sh) | Full deploy script |
| [`scripts/validate.sh`](scripts/validate.sh) | Automated validation |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Remove all resources |
| [`scripts/apply-grpcroute.sh`](scripts/apply-grpcroute.sh) | Deploy the GRPCRoute example (requires `apply.sh` first) |
| [`scripts/validate-grpcroute.sh`](scripts/validate-grpcroute.sh) | Validate the GRPCRoute example + coexistence |
| [`scripts/cleanup-grpcroute.sh`](scripts/cleanup-grpcroute.sh) | Remove only the GRPCRoute example |

## Run it

### Deploy (via scripts)

```bash
# Full deploy (auto-detects the hostname)
bash tests/grpc-backends/scripts/apply.sh

# With a manual domain
export CLUSTER_DOMAIN="apps.ocp.xxx.example.com"
bash tests/grpc-backends/scripts/apply.sh
```

The script runs, in order:
1. Creates namespace `req048-grpc`.
2. Applies the RoleBinding for image-pull.
3. Applies the Deployment and waits for Ready.
4. Applies the Service with `appProtocol: kubernetes.io/h2c`.
5. Adds the `req048-grpc` listener to the gateway.
6. Applies the AuthPolicy (allow public) and the HTTPRoute.
7. Applies an EnvoyFilter that disables the request buffer (installed by the
   streaming-and-body-limits item on the shared gateway) on the req048 vhosts —
   without this, gRPC reflection and streaming RPCs stall at the gateway.

### Validation

Automated:

```bash
bash tests/grpc-backends/scripts/validate.sh
```

Manual — native gRPC (unary):

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="req048-grpc.${CLUSTER_DOMAIN}"

# List services via reflection
grpcurl -plaintext $HOST:80 list
# Expected:
#   io.gatewaysmashes.rhcl.grpc.BankingService
#   grpc.health.v1.Health
#   grpc.reflection.v1alpha.ServerReflection

# Unary call — GetSummary
grpcurl -plaintext -d '{"api_version":"v1"}' \
  $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
# Expected: JSON with apiVersion, instance, banks[], grandTotal
```

Manual — gRPC server-streaming:

```bash
# StreamHealth — receives multiple events
grpcurl -plaintext -d '{"interval_ms":500,"max_events":3}' \
  $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth
# Expected: 3 events with instance, mode, ready, timestamp, increasing sequence
```

Manual — gRPC bidirectional:

```bash
# EchoStream — sends messages and receives the echo
echo '{"text":"hello-1"}{"text":"hello-2"}{"text":"hello-3"}' | \
  grpcurl -plaintext -d @ \
    $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/EchoStream
# Expected: 3 responses with text, serverRecvEpochMs, instance, sequence
```

Manual — gRPC-Web via curl:

```bash
# gRPC-Web (binary format for GetSummary with api_version="v1")
printf '\x00\x00\x00\x00\x04\x0a\x02v1' | \
  curl -sS -X POST --data-binary @- \
    -H 'content-type: application/grpc-web+proto' \
    -H 'x-grpc-web: true' \
    "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary" -i
# Expected: HTTP/1.1 200, headers including grpc-status: 0
```

Manual — appProtocol on the Service:

```bash
oc -n req048-grpc get svc req048-grpc-backend -o jsonpath='{.spec.ports[0].appProtocol}'
# Expected: kubernetes.io/h2c
```

### What to look for

| # | Evidence | Command | Expected result |
|---|-----------|---------|-------------------|
| 1 | gRPC unary via gateway | `grpcurl ... GetSummary` | Response with `apiVersion`, `banks`, `grandTotal` |
| 2 | gRPC streaming via gateway | `grpcurl ... StreamHealth` | Multiple `HealthEvent` with increasing sequence |
| 3 | gRPC bidirectional | `grpcurl ... EchoStream` | Echo of each message with `serverRecvEpochMs` |
| 4 | gRPC-Web via curl | `curl -H 'content-type: grpc-web+proto'` | HTTP 200, `grpc-status: 0` |
| 5 | gRPC reflection | `grpcurl ... list` | `io.gatewaysmashes.rhcl.grpc.BankingService` in the list |
| 6 | appProtocol h2c | `oc get svc ... -o jsonpath` | `kubernetes.io/h2c` |
| 7 | HTTPRoute accepted | `oc get httproute ... status` | `Accepted: True` |
| 8 | GRPCRoute accepted (complementary) | `oc -n req048-grpc get grpcroute req048-grpcroute` | `Accepted: True` |
| 9 | gRPC via GRPCRoute (service match) | `grpcurl ... req048-grpcroute.<domain>:80 ... GetSummary` | Same response as row 1 |

## Complementary example: GRPCRoute

Demonstrates **idiomatic** gRPC routing with a `v1` (GA) `GRPCRoute`, coexisting
with the primary example. It reuses the same backend (Deployment/Service in
`req048-grpc`) and uses a **dedicated hostname and listener** — required by the
spec's hostname-intersection rule (see
[HTTPRoute vs GRPCRoute for gRPC](#httproute-vs-grpcroute-for-grpc)).

```
grpcurl ── req048-grpc.<domain> ──────▶ listener req048-grpc ────── HTTPRoute (PathPrefix /) ──┐
                                                                    + AuthPolicy (Kuadrant)    ├──▶ req048-grpc-backend:8080 (h2c)
grpcurl ── req048-grpcroute.<domain> ─▶ listener req048-grpcroute ─ GRPCRoute (method match) ──┘
                                                                    (outside Kuadrant enforcement)
```

### Deploy

```bash
# Requires the base req048 deployed (apply.sh)
bash tests/grpc-backends/scripts/apply-grpcroute.sh
```

The script verifies the `grpcroutes.gateway.networking.k8s.io` CRD is served at
`v1` (aborts with guidance if not), verifies the base, adds the
`req048-grpcroute` listener, applies
[`manifests/05-grpcroute.yaml`](manifests/05-grpcroute.yaml), and waits for
`Accepted`.

### Validation

```bash
bash tests/grpc-backends/scripts/validate-grpcroute.sh
```

Manual:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST_GRPCROUTE="req048-grpcroute.${CLUSTER_DOMAIN}"

# GRPCRoute accepted by the gateway
oc -n req048-grpc get grpcroute req048-grpcroute \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True

# Reflection (routed by the GRPCRoute infrastructure rule)
grpcurl -plaintext $HOST_GRPCROUTE:80 list

# Unary — matching by service (rules.matches.method.service)
grpcurl -plaintext -d '{"api_version":"v1"}' \
  $HOST_GRPCROUTE:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary

# Coexistence — the HTTPRoute example keeps answering
grpcurl -plaintext -d '{"api_version":"v1"}' \
  req048-grpc.${CLUSTER_DOMAIN}:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
```

### Explicit matching by service

The GRPCRoute routes **only** the services declared in its `rules`
(`io.gatewaysmashes.rhcl.grpc.BankingService`, reflection and health). A call to an
undeclared service is rejected by the **gateway** (the client gets
`UNIMPLEMENTED` / HTTP 404) without reaching the backend. With the HTTPRoute
(`PathPrefix /`), every path reaches the backend. That is the main teaching
difference between the two approaches.

### Cleanup (GRPCRoute example only)

```bash
bash tests/grpc-backends/scripts/cleanup-grpcroute.sh
```

Removes the GRPCRoute and the `req048-grpcroute` listener; the HTTPRoute example
stays active. The full `cleanup.sh` also removes the GRPCRoute resources.

## Technical notes

### HTTPRoute vs GRPCRoute for gRPC

> `GRPCRoute` graduated to `v1` (GA) in Gateway API v1.1. On this cluster
> (OpenShift 4.21, Gateway API bundle v1.3.0) the CRD is served at `v1` and the
> gateway controller (`openshift-default` / Istio) supports it. This item
> demonstrates **both approaches** — HTTPRoute as primary and GRPCRoute as
> complementary.

| Aspect | HTTPRoute | GRPCRoute |
|---------|-----------|-----------|
| Matching | HTTP path/method/headers/query — the gRPC method becomes a manual path (`/package.Service/Method`) | gRPC service/method (`matches.method.service`/`.method`) and metadata — idiomatic |
| HTTP/2 semantics (trailers with `grpc-status`, no upgrade) | Works on Envoy/Istio, but is an **implementation** guarantee | A **spec** guarantee of the Gateway API |
| gRPC-Web (`application/grpc-web+proto`) | Yes (demonstrated here) | Out of spec scope (native gRPC only) |
| Filters | requestHeaderModifier, redirect, mirror, URLRewrite (⚠ rewrite breaks gRPC) | requestHeaderModifier, mirror |
| **Kuadrant policies (AuthPolicy/RateLimitPolicy)** | **Yes** — `targetRef.kind: HTTPRoute` | **Not in RHCL 1.3.5** (see limitation below) |

**When to use which (for gRPC):**

- **HTTPRoute** — when the gRPC API needs Kuadrant governance (authentication,
  rate limiting), when REST and gRPC share the same hostname, or when there are
  gRPC-Web clients.
- **GRPCRoute** — pure gRPC routing with explicit intent: route services/methods
  of the same backend differently (canary per method, split per service), more
  readable manifests for a catalog/governance, and HTTP/2 semantics guaranteed
  by the API (not the implementation).

**RHCL 1.3.5 limitation with GRPCRoute (verified here):**

1. The `authpolicies.kuadrant.io` and `ratelimitpolicies.kuadrant.io` CRDs
   restrict `targetRef.kind` to `HTTPRoute` or `Gateway` (CEL validation) —
   **you cannot attach Kuadrant policies to a GRPCRoute**.
2. The Kuadrant data plane (`kuadrant-<gateway>` WasmPlugin) derives its
   `actionSets` **only from HTTPRoutes**. Traffic routed by a GRPCRoute matches
   no actionSet and **is not enforced — not even by the gateway's deny-all
   AuthPolicy**. Treat this as an architecture decision: gRPC governed by RHCL ⇒
   HTTPRoute.

**Coexistence (Gateway API spec rule):** if an HTTPRoute and a GRPCRoute with
intersecting hostnames attach to the same listener, only the **older** route is
accepted. That is why the GRPCRoute example uses its own hostname and listener
(`req048-grpcroute.<domain>`).

### appProtocol vs port-name prefix

| Method | Example | Status |
|--------|---------|--------|
| `appProtocol` (recommended) | `appProtocol: kubernetes.io/h2c` | GA, Kubernetes standard |
| Port-name prefix (legacy) | `name: grpc-banking` | Works but deprecated |

This item uses `appProtocol`, the recommended and standard method.

### gRPC-Web vs native gRPC

| Aspect | Native gRPC | gRPC-Web |
|---------|-------------|----------|
| Transport | HTTP/2 required | HTTP/1.1 or HTTP/2 |
| Client | `grpcurl`, gRPC libs | Browser (fetch/XHR), `curl` |
| Framing | gRPC standard | gRPC-Web framing (5-byte header) |
| Streaming | Full bidi | Server-streaming only |
| Content-Type | `application/grpc` | `application/grpc-web+proto` |

## Troubleshooting

**Deployment not Ready**

```bash
oc -n req048-grpc get events --sort-by=.lastTimestamp | tail -20
oc -n req048-grpc logs deployment/req048-banking-api
# Common cause: image not found → check the RoleBinding
oc -n rhcl-apps get rolebinding req048-image-puller
```

**grpcurl stalls (DeadlineExceeded) via the gateway, but works directly on the backend**

```bash
# Cause: the streaming-and-body-limits item installs the files-upload-max-body
# EnvoyFilter, which inserts envoy.filters.http.buffer on the WHOLE shared
# gateway. The buffer waits for the full request body — streaming-request RPCs
# (grpcurl reflection, EchoStream) never "complete" and stall. Unary is fine.
oc -n openshift-ingress get envoyfilter files-upload-max-body

# Fix (applied by apply.sh / apply-grpcroute.sh): EnvoyFilter
# req048-grpc-streaming-no-buffer disables the buffer on the req048 vhosts via
# BufferPerRoute (same mechanism the body-limits item uses).
oc -n openshift-ingress get envoyfilter req048-grpc-streaming-no-buffer
```

**grpcurl returns "connection refused"**

```bash
# Check the listener exists on the gateway
oc -n openshift-ingress get gateway -o jsonpath='{.items[0].spec.listeners[*].name}' | tr ' ' '\n' | grep req048
# Check DNS
nslookup req048-grpc.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
# Test from inside the cluster (bypass external DNS)
oc -n req048-grpc run grpc-test --rm -i --restart=Never \
  --image=fullstorydev/grpcurl:latest -- \
  -plaintext -d '{"api_version":"v1"}' \
  req048-grpc-backend.req048-grpc.svc:8080 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
```

**HTTPRoute / GRPCRoute not accepted (Accepted=False)**

```bash
oc -n req048-grpc get httproute req048-grpc-route -o yaml | grep -A5 conditions
oc -n req048-grpc get grpcroute req048-grpcroute -o yaml | grep -A5 conditions
# Common causes: listener missing (re-run the apply script), hostname conflicts
# with another route on the same listener (use distinct hostnames/listeners), or
# the grpcroutes CRD is not served at v1.
```

**grpc-web returns 404 or 415**

```bash
curl -v -X POST \
  -H 'content-type: application/grpc-web+proto' \
  "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"
oc -n req048-grpc exec deployment/req048-banking-api -- \
  curl -s localhost:8080/q/health/ready
```

## Cleanup

```bash
bash tests/grpc-backends/scripts/cleanup.sh
```

The script removes:
- Listeners `req048-grpc` and `req048-grpcroute` from the gateway
- EnvoyFilter `req048-grpc-streaming-no-buffer` in `openshift-ingress`
- Namespace `req048-grpc` (Deployment, Service, HTTPRoute, GRPCRoute, AuthPolicy)
- RoleBinding `req048-image-puller` in `rhcl-apps`

To remove **only** the GRPCRoute example (keeping the HTTPRoute): `bash tests/grpc-backends/scripts/cleanup-grpcroute.sh`

## References

- [RHCL 1.3 — Configuring and deploying gateway policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/configuring_and_deploying_gateway_policies/rhcl-config-deploy-gateway-policies)
- [Kubernetes — Service appProtocol](https://kubernetes.io/docs/concepts/services-networking/service/#application-protocol)
- [Istio — Protocol Selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/)
- [Gateway API — HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [Gateway API — GRPCRoute](https://gateway-api.sigs.k8s.io/api-types/grpcroute/)
- [gRPC — Core concepts](https://grpc.io/docs/what-is-grpc/core-concepts/)
- [gRPC-Web — Protocol specification](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md)
