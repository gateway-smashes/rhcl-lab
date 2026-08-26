# REQ 030 — Request interception (ext_authz + RequestMirror)

Manifests and tooling that demonstrate **request interception** on a
dedicated RHCL / Istio Gateway. Adapted from the
[rhcl-reference](https://github.com/dsferreira54/rhcl-reference) lab
(`helloWorldApp.requestInterceptor`) into the same standalone pattern used by
[req050](../req050/README.md): numbered YAMLs + `deploy.sh`.

Two listeners on a **dedicated gateway** prove the two strategies separately:

| Listener | Hostname | Strategy | Proves |
|----------|----------|----------|--------|
| `http-extauthz` | `req030-extauthz.*` | Istio `AuthorizationPolicy` CUSTOM + `envoyExtAuthzHttp` | Envoy **calls** request-interceptor before forwarding to hello-world |
| `http-mirror` | `req030-mirror.*` | Gateway API `RequestMirror` filter | A **copy** of each request is sent to request-interceptor (async) |

## Prerequisites

- OpenShift cluster with **Service Mesh 3.x** (Istio/Sail) and Gateway API CRDs.
- The `istio` GatewayClass (Sail Operator / OSSM 3.x).
- `RHCL_ZONE_ROOT_DOMAIN` set to your cluster's DNS zone (e.g. `mycluster.sandbox546.opentlc.com`).
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
export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com   # adjust to your cluster
cd tests/req030/manifests
./deploy.sh
```

## Verify

```bash
export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com

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
export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
cd tests/req030/manifests

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

- [REQ 050 — OCSP / CRL](../req050.md) — same manifest/deploy pattern
- [REQ 051 / 056 — mTLS gateway](../req051.md) — dedicated gateway pattern
- Ansible integration: `automation/roles/apps/templates/req030-*.yml.j2`
