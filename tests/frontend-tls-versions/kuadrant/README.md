# REQ 55 — TLSPolicy demo (Kuadrant)

Manifests that expose an API over **TLS 1.2 / 1.3** using a Kuadrant
[`TLSPolicy`](https://docs.kuadrant.io/1.0.x/kuadrant-operator/doc/user-guides/tls/gateway-tls/)
backed by cert-manager.

## What gets created

| File | Purpose |
| --- | --- |
| `00-namespaces.yaml` | `req55-gateway` (Gateway + TLSPolicy) and `req55-api` (HTTPRoute). |
| `01-clusterissuer-selfsigned.yaml` | `ClusterIssuer/req55-selfsigned` — self-signed CA (lab only). |
| `02-gateway.yaml` | `Gateway/req55-gateway` — HTTP:80 + HTTPS:443 listeners. The HTTPS listener references `Secret/req55-gateway-tls` (created later by cert-manager). |
| `03-tlspolicy.yaml` | `TLSPolicy/req55-tls-policy` (`kuadrant.io/v1`) — targets the Gateway, points at the ClusterIssuer. Kuadrant generates a `Certificate` that fills the listener Secret. |
| `04-httproute.yaml` | `HTTPRoute/req55-banking-route` — routes `req55-banking.<apps>` `/api` to `banking-api-v1` in `rhcl-apps`. |

## Why a TLSPolicy is enough for REQ 55

The Kuadrant `TLSPolicy` spec exposes only `targetRef` and `issuerRef`. It does
**not** have a `minVersion` / `maxVersion` field. The negotiated TLS protocol
version is decided by the **Istio / Envoy data plane**, whose defaults already:

- accept **TLS 1.2** and **TLS 1.3**, and
- reject **TLS 1.0 / 1.1 / SSLv3**.

So once the Gateway has a working HTTPS listener (provisioned by the TLSPolicy),
hitting it with `curl --tlsv1.2` and `curl --tlsv1.3` proves REQ 55. If the
project later needs to *restrict* to one specific version, that has to be done
at the Istio / Envoy layer (e.g. `meshConfig.meshMTLS.minProtocolVersion`,
`DestinationRule.trafficPolicy.tls`, or an `EnvoyFilter` on the listener), not
in the TLSPolicy.

## Prerequisites

- OpenShift cluster with Kuadrant, Sail/Istio and the Gateway API CRDs already
  installed (the lab automation in `automation/` does this).
- **cert-manager Operator** installed cluster-wide. The TLSPolicy will not
  produce a cert until the Issuer/ClusterIssuer is `Ready`.
- A backend Service to route to. The HTTPRoute defaults to `banking-api-v1` in
  `rhcl-apps` (deployed by `deploy/kustomize`).

## Adapt the hostnames before applying

The Gateway and HTTPRoute use `*.apps.example.com` as a default
example. Replace it with your cluster's apps domain in **both files** before
applying:

```bash
APPS_DOMAIN="apps.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')"
echo "$APPS_DOMAIN"

sed -i.bak "s/apps.example.com/$APPS_DOMAIN/g" \
  02-gateway.yaml 04-httproute.yaml
```

## Apply

```bash
# from this folder
oc apply -k .

# Watch the Certificate appear and become Ready
oc -n req55-gateway get certificate,secret,tlspolicy -w

# Confirm the Gateway listener is Programmed: True
oc -n req55-gateway get gateway req55-gateway -o yaml \
  | yq '.status.listeners[] | {name, conditions: [.conditions[] | {type,status}]}'
```

Expected: `Certificate/req55-gateway-tls` reaches `READY=True`,
`Secret/req55-gateway-tls` of type `kubernetes.io/tls` is created, and the
Gateway listener `https` reports `Programmed=True`.

## Verify TLS 1.2 / 1.3 against the gateway

```bash
# Resolve the gateway VIP
GW=$(oc -n req55-gateway get gateway req55-gateway \
       -o jsonpath='{.status.addresses[?(@.type=="IPAddress")].value}')
HOST=req55-banking.apps.example.com   # adjust to your apps domain

# TLS 1.3 — must succeed (HTTP 200, TLSv1.3)
curl -vk --tlsv1.3 --tls-max 1.3 \
  --resolve "$HOST:443:$GW" \
  "https://$HOST/api/v1/accounts/summary" 2>&1 \
  | grep -E 'SSL connection|TLSv|ALPN|HTTP/'

# TLS 1.2 — must succeed
curl -vk --tlsv1.2 --tls-max 1.2 \
  --resolve "$HOST:443:$GW" \
  "https://$HOST/api/v1/accounts/summary" 2>&1 \
  | grep -E 'SSL connection|TLSv|ALPN|HTTP/'

# TLS 1.1 — must fail
curl -vk --tlsv1.1 --tls-max 1.1 \
  --resolve "$HOST:443:$GW" \
  "https://$HOST/api/v1/accounts/summary" 2>&1 \
  | grep -E 'TLSv|alert|error'

# Full inventory of accepted versions / ciphers
nmap --script ssl-enum-ciphers -p 443 "$HOST"
```

## Cleanup

```bash
oc delete -k .
oc delete ns req55-api req55-gateway
```
