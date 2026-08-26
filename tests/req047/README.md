# REQ 47 — Backend TLS 1.2 / 1.3 (PoC)

See [`../req047.md`](../req047.md). Uses **banking-api-v1** HTTPS (:8443) and
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
