---
title: Backend TLS 1.2 / 1.3
summary: Terminate and re-originate TLS to backends over TLS 1.2 / 1.3.
category: TLS & mTLS
status: done
---

# REQ 47 — Backend TLS 1.2 / 1.3 (PoC)

See [`../backend-tls-versions/README.md`](../backend-tls-versions/README.md). Uses **banking-api-v1** HTTPS (:8443) and
`GET /api/tls/info` — no separate probe app.

## Files

| File | What it shows |
|------|---------------|
| [`manifests/00-httproute-backend-tls.yaml`](manifests/00-httproute-backend-tls.yaml) | HTTPRoute `backend-tls` → `banking-api-v1:8443` |
| [`manifests/01-backendtlspolicy.yaml`](manifests/01-backendtlspolicy.yaml) | `BackendTLSPolicy` for upstream TLS |
| [`manifests/02-service-ca-configmap.yaml`](manifests/02-service-ca-configmap.yaml) | Service CA (playbook creates it automatically) |
| [`index.html`](index.html) | Browser console for `/api/tls/info` |

## Prerequisites

```bash
oc get deploy banking-api-v1 -n rhcl-apps
oc get httproute backend-tls -n rhcl-apps
oc get backendtlspolicy backend-tls-backend-tls -n rhcl-apps
oc get secret banking-api-v1-tls -n rhcl-apps
```

## Validate

```bash
HOST=$(oc get httproute backend-tls -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
curl -sk "https://${HOST}/api/tls/info" | jq '{isSSL,tlsVersion,cipherSuite,alpn,instance}'
```

Success: `"isSSL": true` and `tlsVersion` is `TLSv1.2` or `TLSv1.3`.

## Requirement context

## Requirement demonstrated

| Item | Requirement |
|------|-------------|
| **47** | Communicate with backend APIs over **TLS 1.2** and **TLS 1.3** (gateway → backend hop), with HTTP/2 where negotiated. |

The **banking-api** already ships everything the app needs:

- HTTPS listener on **:8443** (`APPS_BACKEND_TLS_ENABLED=true`, `QUARKUS_PROFILE=tls`)
- `GET /api/tls/info` — reports `tlsVersion`, `cipherSuite`, `alpn`, `isSSL`, peer certs

This package adds the **RHCL wiring**: a dedicated HTTPRoute whose `backendRef`
points at `banking-api-v1:8443` plus a `BackendTLSPolicy` so Envoy originates TLS
to the pod. The main `banking-api-connectivity` route is unchanged (still HTTP :8080).

> **gRPC bidi** (`EchoStream`) stays on the banking-api HTTP port — see req 48/54.

---

## Target service: `banking-api-v1`

| Endpoint | Use |
|----------|-----|
| `GET /api/tls/info` | JSON snapshot of negotiated TLS on the pod |
| HTTPS `:8443` | OpenShift service serving cert (`banking-api-v1-tls` secret) |

Demo hostname: `tls.${RHCL_ZONE_ROOT_DOMAIN}` (HTTPRoute `backend-tls`).

Success via RHCL:

```json
{
  "isSSL": true,
  "tlsVersion": "TLSv1.3",
  "cipherSuite": "TLS_AES_128_GCM_SHA256",
  "instance": "banking-api-v1"
}
```

If `isSSL` is `false`, the gateway is still using plain HTTP to the pod.

---

## Architecture

```
[ client ] ──TLS (edge)──► [ RHCL Gateway ] ──TLS 1.2/1.3──► [ banking-api-v1 :8443 ]
                                    │                              │
                                    │  HTTPRoute backend-tls       │  /api/tls/info
                                    │  + BackendTLSPolicy          │
                                    └──────────────────────────────┘
```

Provisioned by `apps-install` when `APPS_BACKEND_TLS_ROUTE_ENABLED=true` (default).

---

## Manifests

| File | Purpose |
|------|---------|
| [`manifests/00-httproute-backend-tls.yaml`](manifests/00-httproute-backend-tls.yaml) | HTTPRoute → `banking-api-v1:8443` |
| [`manifests/01-backendtlspolicy.yaml`](manifests/01-backendtlspolicy.yaml) | Upstream TLS + CA validation |
| [`manifests/02-service-ca-configmap.yaml`](manifests/02-service-ca-configmap.yaml) | Placeholder; playbook copies the real CA |

---

## Validate

```bash
export NS=rhcl-apps
export TLS_HOST="$(oc get httproute backend-tls -n $NS -o jsonpath='{.spec.hostnames[0]}')"

# Via RHCL
curl -sk "https://${TLS_HOST}/api/tls/info" | jq '{isSSL,tlsVersion,cipherSuite,alpn,instance}'

# Direct to Service (in-cluster)
oc run -n $NS tls-curl --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  -- curl -sk --http2 \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
    "https://banking-api-v1.${NS}.svc:8443/api/tls/info" | jq .
```

---

## Distinction from item 55

| Item | What it proves |
|------|----------------|
| **55** ([`req055`](../req055)) | Client → **gateway** TLS 1.2/1.3 |
| **47** (this package) | Gateway → **banking-api** TLS 1.2/1.3 |

---

## Related

- Banking-api TLS profile: [`apps/backend/banking-api/src/main/resources/application.properties`](../apps/backend/banking-api/src/main/resources/application.properties)
- Automation: `APPS_BACKEND_TLS_ROUTE_*` in [`automation/README.md`](../automation/README.md)
