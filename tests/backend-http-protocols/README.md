---
title: Backend HTTP protocols (1.1 / 2 / 3)
summary: "Runbook: consume backends over HTTP/1.1, HTTP/2 and HTTP/3."
category: Traffic & routing
status: done
---

# Backend HTTP protocols (1.1 / 2 / 3)

Full walkthrough for the protocol version used on the **gateway → backend
(upstream)** connection. It is controlled by the Kubernetes Service
`appProtocol` field.

> This item evaluates the **Gateway → Backend** (upstream) direction. The
> client → gateway (downstream/ingress) direction is covered by the
> [frontend-tls-versions](../frontend-tls-versions/README.md) item.

## What it demonstrates

| Upstream protocol | Configuration | Status |
|---|---|---|
| **HTTP/1.1** | Default (no extra configuration) | GA — fully supported |
| **HTTP/2 (h2c)** | `appProtocol: kubernetes.io/h2c` on the Service | GA — fully supported |
| **HTTP/3 (QUIC)** | Not configurable | **Not supported** for upstream |

```text
 Client ──────► ┌───────────────┐ ──────────► ┌───────────────┐
                │   Gateway     │              │   Backend     │
                │   (Envoy)     │              │   (Pod)       │
                └───────────────┘              └───────────────┘
                    downstream                     upstream
                 (frontend-tls-                 (this item
                  versions covers               covers this
                  this connection)              connection)
```

### HTTP/3 — a documented limitation

HTTP/3 (QUIC/UDP) is **not supported** for upstream (gateway → backend)
connections:

1. **Istio architecture:** mesh-internal traffic always uses TCP. Envoy connects
   to backends over HTTP/1.1 or HTTP/2 on TCP. QUIC is supported **only at
   ingress** (client → gateway).
2. **OSSM 3.x supported protocols:** `HTTP1.1 / HTTP2 / HTTPS / gRPC / TCP / TLS`
   — HTTP/3 is not on the list.
3. **Envoy** does not implement QUIC as an upstream protocol.
4. **Minimal benefit internally:** HTTP/3 targets unstable networks (mobile,
   WAN). Inside a data-center network, HTTP/2 over TCP already provides
   multiplexing and header compression without the QUIC handshake overhead.

**Conclusion:** RHCL **partially** meets this requirement — HTTP/1.1 and HTTP/2
are fully supported for backend communication; HTTP/3 is not supported for
upstream by an Istio/Envoy architectural limitation, and is not in the OSSM
support matrix.

## How it works

The backends **reuse the existing `banking-api-v1` pods** in `rhcl-apps`. The
demo only creates **additional Services** with a different `appProtocol`:

| Service | appProtocol | Upstream protocol |
|---|---|---|
| `req054-backend-http11` | (empty) | HTTP/1.1 — Envoy default |
| `req054-backend-h2c` | `kubernetes.io/h2c` | HTTP/2 cleartext |

Both select the same pods (`selector: app: banking-api-v1`). Only the
`appProtocol` differs, instructing Envoy to use a different upstream protocol.

- **h2c vs h2:** `h2c` = HTTP/2 cleartext (no TLS); `h2` = HTTP/2 with TLS. For
  mesh-internal traffic (gateway → pod) `h2c` is used because mTLS is handled by
  the sidecar/waypoint, not the application.
- **Alternative:** instead of `appProtocol`, a `DestinationRule` with
  `trafficPolicy.connectionPool.http.h2UpgradePolicy: UPGRADE` has the same
  effect; `appProtocol` is preferred as the Kubernetes-native method.

## Prerequisites

| Component | Check |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant installed | `oc get kuadrant -n kuadrant-system` |
| RHCL Gateway active | `oc -n openshift-ingress get gateway` |
| banking-api-v1 pods running | `oc -n rhcl-apps get pods -l app=banking-api-v1` |
| cluster-admin access | `oc whoami` |
| `curl` (any recent version) | `curl --version` |

## Files

| Manifest | What it creates | Namespace |
| --- | --- | --- |
| [`manifests/service-http11.yaml`](manifests/service-http11.yaml) | Service targeting banking-api-v1 (no `appProtocol` → HTTP/1.1 upstream) | `rhcl-apps` |
| [`manifests/service-http2.yaml`](manifests/service-http2.yaml) | Service with `appProtocol: kubernetes.io/h2c` targeting banking-api-v1 | `rhcl-apps` |
| [`manifests/httproute.yaml`](manifests/httproute.yaml) | HTTPRoute with path-based rules for both backends | `rhcl-apps` |

## Run it

### Via scripts

```bash
# Apply (auto-detects the hostname; creates Services, listener, HTTPRoute, AuthPolicy)
bash tests/backend-http-protocols/scripts/apply.sh

# Validate
bash tests/backend-http-protocols/scripts/validate.sh

# Clean up
bash tests/backend-http-protocols/scripts/cleanup.sh
```

Override the domain manually:

```bash
export CLUSTER_DOMAIN="apps.ocp.xxx.example.com"
bash tests/backend-http-protocols/scripts/apply.sh
```

### Via Ansible

This item is integrated into the automation and enabled by default. The role
resolves the hostname, adds the conditional listener, creates the Services and
HTTPRoute, and applies the AuthPolicy.

```bash
cd automation
ansible-playbook playbooks/apps-install.yml
```

Control variables (in `group_vars/all.yml` or via env): `APPS_REQ054_ENABLED`
(default `true`), `APPS_REQ054_ROUTE_HOSTNAME`, `APPS_REQ054_ROUTE_NAME`.

## What to look for

**Backend HTTP/1.1** (default when the Service has no `appProtocol`):

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="req054-backend.${CLUSTER_DOMAIN}"
curl -sv http://$HOST/http11/api/v1/accounts/summary 2>&1 | grep -E "HTTP/|< "
# → 200 from the backend; gateway→backend uses HTTP/1.1
```

**Backend HTTP/2 (h2c)** (Service has `appProtocol: kubernetes.io/h2c`):

```bash
curl -sv http://$HOST/h2/api/v1/accounts/summary 2>&1 | grep -E "HTTP/|< "
# → 200 from the backend; gateway talks to the backend over HTTP/2 (h2c)
```

**Confirm `appProtocol` on the Services:**

```bash
oc -n rhcl-apps get svc req054-backend-http11 -o jsonpath='{.spec.ports[*]}' | python3 -m json.tool
oc -n rhcl-apps get svc req054-backend-h2c    -o jsonpath='{.spec.ports[*]}' | python3 -m json.tool
# http11 has no appProtocol; h2c shows "appProtocol": "kubernetes.io/h2c"
```

**Confirm the Envoy upstream cluster uses HTTP/2** (config dump):

```bash
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers | head -1)
GW_POD=$(oc -n "$GW_NS" get pods -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" -o name | head -1)
oc -n "$GW_NS" exec $GW_POD -c istio-proxy -- \
  pilot-agent request GET /config_dump 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for config in data.get('configs', []):
    for cluster in config.get('dynamic_active_clusters', []):
        name = cluster.get('cluster', {}).get('name', '')
        if 'req054' in name and 'h2c' in name:
            proto = cluster.get('cluster', {}).get('typed_extension_protocol_options', {})
            print(f'Cluster: {name}\nProtocol options: {json.dumps(proto, indent=2)}')
"
# The h2c cluster carries HttpProtocolOptions indicating HTTP/2.
```

## Troubleshooting

**HTTPRoute not accepted (Accepted=False)** — check the `req054-http` listener
exists and its hostname matches the route:

```bash
oc -n openshift-ingress get gateway -o jsonpath='{.items[0].spec.listeners[*].name}' | tr ' ' '\n' | grep req054
```

**Backend returns 503** — the banking-api-v1 pods may not be ready:
`oc -n rhcl-apps get pods -l app=banking-api-v1`.

**Envoy does not use HTTP/2 for the h2c backend** — confirm `appProtocol` is set
(`oc -n rhcl-apps get svc req054-backend-h2c -o yaml | grep appProtocol`); if
correct, wait for the xDS sync (~15s) and re-check the config dump.

**Request timeouts** — confirm the gateway pod is Running and DNS resolves; if
DNS does not resolve, test with `curl --resolve`.

## Cleanup

```bash
bash tests/backend-http-protocols/scripts/cleanup.sh
```

## References

- [Kubernetes — Service appProtocol](https://kubernetes.io/docs/concepts/services-networking/service/#application-protocol)
- [Istio — Protocol Selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/)
- [RHCL 1.3 — Gateway Policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/configuring_and_deploying_gateway_policies/rhcl-config-deploy-gateway-policies)
- [OSSM 3.x — Feature Support Tables](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/release_notes/ossm-release-notes-feature-support-tables)
- [Istio Wiki — Experimental QUIC/HTTP3 (ingress only)](https://github.com/istio/istio/wiki/Experimental-QUIC-and-HTTP-3-support-in-Istio-gateways)
