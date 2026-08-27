---
title: Frontend HTTP versions (1.1 / 2 / 3)
summary: Expose an API over HTTP/1.1, HTTP/2 and HTTP/3 (QUIC) at the gateway edge, protected by API-key auth over TLS.
category: Traffic & routing
status: done
---

# Frontend HTTP versions (1.1 / 2 / 3)

Demonstrates that Kuadrant / Istio can expose the same API over the three HTTP
protocol versions on the **client → gateway (downstream)** connection,
negotiating the right version with each client. The route is protected with
API-key auth over TLS.

| Version | Transport | Negotiation |
|--------|-----------|------------|
| HTTP/1.1 | TCP (port 80 or 443) | Default for HTTP; TLS without ALPN |
| HTTP/2 | TCP TLS (port 443) | ALPN `h2` negotiated in the TLS handshake |
| HTTP/3 | UDP/QUIC (port 443) | Advertised via the `alt-svc: h3=":443"` header |

The `rhcl-apps-gateway` gateway (in `openshift-ingress`) exposes two dedicated
listeners:
- `req057-http` (port 80): HTTP/1.1 cleartext
- `req057-https` (port 443): HTTP/1.1 and HTTP/2 via ALPN TLS; HTTP/3 advertised
  via `alt-svc`

> **Architecture note:** this item reuses the existing `rhcl-apps-gateway`,
> avoiding a separate gateway and reusing the wildcard DNS OpenShift manages
> automatically in that namespace.

## Prerequisites

1. Logged in as cluster-admin.
2. Environment:
   ```bash
   export NS=req057
   export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
   export HOST=banking-api.${CLUSTER_DOMAIN}
   ```
3. `curl` with HTTP/3 support (for the HTTP/3 validation):
   ```bash
   curl --version | grep -i http3   # Features: [...] HTTP3 [...]
   ```
   If your `curl` lacks HTTP/3, use the [alternative HTTP/3 validation](#alternative-http3-validation).

## Run it

**1. Create the namespace.**

```bash
oc apply -f frontend-http-versions/namespace.yaml
```

**2. Set the hostname in the manifests.**

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
sed -i "s/banking-api.apps.example.com/banking-api.${CLUSTER_DOMAIN}/g" frontend-http-versions/httproute.yaml
```

**3. Add the listeners to the shared gateway** (`req057-http` on 80,
`req057-https` on 443, reusing the wildcard cert):

```bash
oc patch gateway rhcl-apps-gateway -n openshift-ingress --type='json' -p='[
  {"op":"add","path":"/spec/listeners/-","value":{
    "name":"req057-http","hostname":"banking-api.'"${CLUSTER_DOMAIN}"'","port":80,
    "protocol":"HTTP","allowedRoutes":{"namespaces":{"from":"All"}}}}
]'

oc patch gateway rhcl-apps-gateway -n openshift-ingress --type='json' -p='[
  {"op":"add","path":"/spec/listeners/-","value":{
    "name":"req057-https","hostname":"banking-api.'"${CLUSTER_DOMAIN}"'","port":443,
    "protocol":"HTTPS","allowedRoutes":{"namespaces":{"from":"All"}},
    "tls":{"mode":"Terminate","certificateRefs":[{
      "group":"","kind":"Secret","name":"cert-manager-ingress-cert","namespace":"openshift-ingress"}]}}}
]'
```

**4. Configure the cloud load balancer for TCP passthrough.** The HTTPS listener
terminates TLS in Envoy (not the load balancer), so on AWS the Classic ELB must
be in TCP passthrough with an HTTP health check on the status port:

```bash
GW_SVC=$(oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway -o name | head -1 | cut -d/ -f2)
oc annotate svc $GW_SVC -n openshift-ingress \
  "service.beta.kubernetes.io/aws-load-balancer-backend-protocol=tcp" \
  "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol=HTTP" \
  "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path=/healthz/ready" \
  --overwrite
```

**5. Apply the item's resources.**

```bash
oc apply -f frontend-http-versions/tlspolicy.yaml
oc apply -f frontend-http-versions/httproute.yaml
oc apply -f frontend-http-versions/referencegrant.yaml
```

**6. Configure API-key auth.** The api-key Secret **must be in `kuadrant-system`**
(where Authorino looks when `allNamespaces: false`):

```bash
sed -i "s/redhat/my-secret-key/g" frontend-http-versions/secret-apikey.yaml
oc apply -f frontend-http-versions/secret-apikey.yaml
oc apply -f frontend-http-versions/authpolicy-apikey.yaml

# Confirm Authorino picked up the Secret
oc -n kuadrant-system get secret banking-api-apikey -o jsonpath='{.metadata.labels}'
# must contain: authorino.kuadrant.io/managed-by=authorino
```

**7. Wait for the DNSRecord** to be Published (`oc get dnsrecord -n openshift-ingress -w`).

## What to look for

```bash
# HTTP/1.1 — port 80, no TLS
curl -si --http1.1 http://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key"
# → HTTP/1.1 200 OK

# HTTP/2 — port 443, ALPN h2
curl -v -k https://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key" 2>&1 | grep -E "ALPN|HTTP/"
# ALPN: server accepted h2
# < HTTP/2 200

# HTTP/3 — alt-svc advertised on HTTPS responses
curl -si -k https://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key" | grep alt-svc
# alt-svc: h3=":443"; ma=86400

# HTTP/3 direct (needs curl with HTTP/3)
curl -v --http3-only -k https://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key"
# < HTTP/3 200
```

### Alternative HTTP/3 validation

If your `curl` lacks HTTP/3, run it from a temporary pod in the cluster:

```bash
oc run curl-h3 -n $NS --image=curlimages/curl:latest --restart=Never -it --rm \
  -- curl -v --http3-only -k https://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key"
```

### Auth check

```bash
curl -si -k https://$HOST/api/v1/accounts/summary | head -1                            # HTTP/2 401 (no key)
curl -si -k https://$HOST/api/v1/accounts/summary -H "api-key: my-secret-key" | head -1 # HTTP/2 200
```

| Command | Listener | Negotiated version |
|---------|----------|-----------------|
| `curl --http1.1 http://...` | HTTP / 80 | HTTP/1.1 |
| `curl -k https://...` | HTTPS / 443 | HTTP/2 (ALPN h2) |
| `curl --http3-only -k https://...` | HTTPS/QUIC / UDP 443 | HTTP/3 |

## How it works — notes

- **HTTP/1.1 vs HTTP/2 on the same HTTPS listener:** Istio/Envoy negotiates via
  ALPN — if the client offers `h2`, it uses HTTP/2, else HTTP/1.1. No separate
  listener needed.
- **TLS certificate:** the `req057-https` listener uses the
  `cert-manager-ingress-cert` Secret (a `*.apps.<CLUSTER_DOMAIN>` wildcard from
  cert-manager + Let's Encrypt).
- **AWS Classic ELB in TCP mode:** port 443 must be TCP passthrough since Envoy
  terminates TLS; the `aws-load-balancer-backend-protocol=tcp` annotation and the
  correct health check are essential.
- **Authorino Secrets:** the api-key Secret must be in `kuadrant-system` when
  Authorino runs with `allNamespaces: false`.
- **HTTP/3 is experimental in OSSM:** QUIC needs a recent Istio and may be off by
  default; UDP 443 must be open on the cloud security group and the NodePort.

## Cleanup

```bash
oc delete -f frontend-http-versions/authpolicy-apikey.yaml -f frontend-http-versions/secret-apikey.yaml \
  -f frontend-http-versions/httproute.yaml -f frontend-http-versions/tlspolicy.yaml \
  -f frontend-http-versions/namespace.yaml --ignore-not-found

# Remove the listeners added to the shared gateway (indexes may differ)
oc patch gateway rhcl-apps-gateway -n openshift-ingress --type='json' -p='[
  {"op":"remove","path":"/spec/listeners/3"},
  {"op":"remove","path":"/spec/listeners/2"}
]'
```
