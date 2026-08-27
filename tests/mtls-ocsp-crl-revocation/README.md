---
title: mTLS with OCSP stapling and CRL
summary: Certificate revocation on the mTLS gateway via OCSP stapling and CRL validation.
category: TLS & mTLS
status: done
---

# REQ 050 — OCSP stapling + CRL validation

Manifests and tooling that add **certificate revocation** controls on top of the
mTLS Gateway pattern from [req051](../gateway-mtls-enforcement/README.md). The same mechanism is
used — an **EnvoyFilter** patching the Envoy `DownstreamTlsContext` per SNI —
extended with the revocation fields Envoy exposes.

Two listeners demonstrate the two controls:

| Listener | Hostname | Control | Proves |
|----------|----------|---------|--------|
| `https-crl`  | `req050-crl.*`  | mTLS + `validation_context.crl` | a **revoked client cert** is rejected in the handshake |
| `https-ocsp` | `req050-ocsp.*` | mTLS + `tls_certificate.ocsp_staple` | the gateway **staples the OCSP response** of its own server cert |

## Scope note — what Envoy does and does not do

- **Client-cert revocation is only via CRL.** Envoy's `CertificateValidationContext`
  has no real-time OCSP check for peer/client certificates — only `crl`
  (and `only_verify_leaf_cert_crl`). The AIA OCSP URL embedded in a client cert
  is **ignored**.
- **OCSP is server-side only** (stapling). `tls_certificate.ocsp_staple` +
  `ocsp_staple_policy` let the gateway attach a pre-fetched OCSP response for its
  own server certificate, which the client validates during the handshake.
- **Envoy never fetches CRL/OCSP from the certificate's CDP/AIA URLs.** Both the
  CRL and the OCSP staple are supplied as static files (mounted Secrets) and must
  be refreshed out-of-band (see [Technical notes](#technical-notes)).

## Prerequisites

- OpenShift cluster with **Service Mesh 3.x** (Istio/Sail) and Gateway API CRDs.
- The `openshift-default` GatewayClass (backed by Istio).
- Backend `banking-api-v1` Service in namespace `rhcl-apps` (lab automation).
- `openssl` CLI (PKI + CRL + OCSP response generation).
- `envsubst` (from `gettext`), `python3` (EnvoyFilter JSON generation).

## What gets created

| File | Purpose |
|------|---------|
| `manifests/generate-certs.sh` | Builds the PKI **via `openssl ca`** (tracked in `index.txt`), revokes one client, emits `crl.pem` and the server `server-ocsp.der` staple. |
| `manifests/00-namespace.yaml` | `req050-gateway` namespace. |
| `manifests/10-gateway.yaml` | Gateway with two HTTPS listeners (TLS terminate, `openshift-default`). |
| `manifests/deploy-envoyfilter.sh` | Generates the two EnvoyFilters (CRL / OCSP) and applies them. |
| `manifests/deploy.sh` | One-shot: namespace, secrets, gateway, volume mounts, EnvoyFilters, routes. |
| `manifests/20-httproute.yaml` | Two HTTPRoutes (one per hostname) → `banking-api-v1`. |
| `manifests/25-referencegrant.yaml` | ReferenceGrant in `rhcl-apps` for cross-namespace backend refs. |
| `manifests/30-passthrough-routes.yaml` | OpenShift Routes (TLS passthrough) so the gateway hostnames reach our gateway via the router. |
| `manifests/test-req050.sh` | Interactive validator (CRL scenarios + OCSP staple inspection). |

## How it works

The `openshift-default` GatewayClass is handled by Istio (OSSM 3.x). Two HTTPS
listeners collapse into a single Envoy listener (`0.0.0.0_443`) with SNI-based
filter chains. Each EnvoyFilter matches its filter chain by SNI and merges a
`DownstreamTlsContext`:

**CRL listener** — extends the req051 `validation_context`:

```yaml
require_client_certificate: true
common_tls_context:
  validation_context:
    trusted_ca: { filename: /etc/certs/intermediate-ca/ca.crt }
    crl:        { filename: /etc/certs/crl/crl.pem }
    only_verify_leaf_cert_crl: true   # only the client leaf is CRL-checked
```

**OCSP listener** — the EnvoyFilter only enforces mTLS; the OCSP **staple is
delivered through the SDS TLS secret** (see below), not the EnvoyFilter:

```yaml
require_client_certificate: true
common_tls_context:
  validation_context:
    trusted_ca: { filename: /etc/certs/intermediate-ca/ca.crt }
```

Why not attach the staple in the EnvoyFilter? Istio serves the server cert via
SDS, and Envoy rejects a filter chain that mixes an SDS cert with an inline one
(*"SDS and non-SDS TLS certificates may not be mixed in server contexts"*).
Istio's supported path is to place the staple in the TLS secret under the key
**`tls.ocsp-staple`**; Pilot forwards it inline on the SDS cert. So `deploy.sh`
builds `req050-server-tls` with three keys — `tls.crt`, `tls.key`,
`tls.ocsp-staple` (the DER from `generate-certs.sh`) — and Envoy staples it
(default `LENIENT_STAPLING`).

### Traffic flow

```
Client → hostname DNS → Default OpenShift Router → passthrough Route → Gateway Pod (Envoy)
                                                                        ↓ mTLS + CRL / OCSP staple
                                                                   banking-api-v1
```

## Certificate hierarchy

```
Root CA (CN=RHCL PoC Root CA)
 └── Intermediate CA (CN=RHCL PoC Intermediate CA)   ← CRL issuer / OCSP responder
      ├── Server cert       (SAN=req050-crl.DOMAIN, req050-ocsp.DOMAIN, *.DOMAIN)
      ├── client-valid.crt   (CN=banking-client-valid)   — NOT revoked
      └── client-revoked.crt (CN=banking-client-revoked) — revoked → listed in crl.pem

Untrusted CA (CN=Untrusted External CA)
 └── client-untrusted.crt (CN=untrusted-client)
```

## Setup

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster
cd tests/mtls-ocsp-crl-revocation/manifests
./generate-certs.sh
./deploy.sh
```

`generate-certs.sh` prints the exact `oc create secret` and test commands; the
one-shot `deploy.sh` runs the equivalent apply flow and mounts the CA, CRL, OCSP
staple and server cert as volumes on the gateway pod.

## Verification

### CRL — revocation of client certs (`req050-crl.*`)

```bash
CERTS=tests/mtls-ocsp-crl-revocation/manifests/certs
HOST=req050-crl.${RHCL_ZONE_ROOT_DOMAIN}

# PASS — valid (non-revoked) client
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-valid.crt --key $CERTS/client-valid.key \
  "https://$HOST/api/tls/info"

# FAIL — revoked client (rejected by CRL check)
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-revoked.crt --key $CERTS/client-revoked.key \
  "https://$HOST/api/tls/info"

# FAIL — untrusted CA / no cert
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://$HOST/api/tls/info"
curl -v --cacert $CERTS/root-ca.crt "https://$HOST/api/tls/info"
```

### OCSP stapling — server cert status (`req050-ocsp.*`)

```bash
HOST=req050-ocsp.${RHCL_ZONE_ROOT_DOMAIN}

# Inspect the stapled OCSP response
openssl s_client -connect ${HOST}:443 -servername ${HOST} -status \
  -cert $CERTS/client-valid.crt -key $CERTS/client-valid.key </dev/null \
  | grep -E "OCSP Response Status|Cert Status"
# Expected:  OCSP Response Status: successful
#            Cert Status: good

# curl equivalent
curl -v --cert-status --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-valid.crt --key $CERTS/client-valid.key \
  "https://$HOST/api/tls/info"
```

Run everything interactively: `./test-req050.sh` (or `./test-req050.sh A`).

### Validation matrix

| Listener | Scenario | Expected |
|----------|----------|----------|
| `https-crl`  | `client-valid` (not revoked) | **PASS** — HTTP 200 |
| `https-crl`  | `client-revoked` (in CRL) | **FAIL** — TLS rejected |
| `https-crl`  | `client-untrusted` (unknown CA) | **FAIL** — TLS rejected |
| `https-crl`  | (no client cert) | **FAIL** — TLS rejected |
| `https-ocsp` | staple inspection with valid client | **PASS** — `Cert Status: good` |

### Regression: revoke a live client

```bash
cd tests/mtls-ocsp-crl-revocation/manifests
openssl ca -config certs/openssl.cnf -revoke certs/client-valid.crt -crl_reason keyCompromise
openssl ca -config certs/openssl.cnf -gencrl -out certs/crl.pem
oc -n req050-gateway create secret generic req050-crl \
  --from-file=crl.pem=certs/crl.pem --dry-run=client -o yaml | oc apply -f -
oc -n req050-gateway rollout restart deployment/req050-revocation-gateway-openshift-default
# client-valid is now rejected on req050-crl.*
```

## Technical notes

### Why EnvoyFilter and not the native mTLS mechanisms

mTLS client-cert validation can be done several ways, but **only the EnvoyFilter
path exposes `crl` and `ocsp_staple`** — every native option validates against a
CA bundle and nothing more:

| Approach | EnvoyFilter? | Prerequisite | Exposes `crl` / `ocsp_staple`? |
|----------|--------------|--------------|--------------------------------|
| Gateway API `tls.frontendValidation` (`caCertificateRefs`) | No | Gateway API CRDs **≥ v1.5.0** (standard channel) + Istio support | ❌ CA bundle only |
| Istio `Gateway` CRD `tls.mode: MUTUAL`/`OPTIONAL_MUTUAL` (`credentialName` with `ca.crt`) | No | use Istio's own Gateway API | ❌ `caCertificates` only |
| Kuadrant/RHCL `AuthPolicy` x509 (Authorino) | Envoy still requests the cert | XFCC propagation gap (Kuadrant RFC 0015) | ❌ authz on subject, not revocation |
| **EnvoyFilter → `DownstreamTlsContext`** (this req) | **Yes** | none | ✅ `validation_context.crl` + `tls_certificate.ocsp_staple` |
| ~~`PeerAuthentication`~~ | — | — | not applicable (mesh-internal mTLS, SPIFFE certs) |

req051 originally used EnvoyFilter because `frontendValidation` was not in the
cluster's standard-channel CRDs (it landed in Gateway API v1.5.0). For req050 the
EnvoyFilter is not a workaround but the **only** option, since revocation fields
are not surfaced by any native API.

### CRL / OCSP data is static — Envoy does not fetch it

Envoy ignores the certificate's CRL Distribution Point (CDP) and AIA OCSP URL. It
only uses the `crl` file and the OCSP staple supplied here (the latter via the
`tls.ocsp-staple` key of the SDS secret). In production both would be **refreshed**
by an external CronJob/sidecar (fetch the CRL from the CDP; query the OCSP
responder from the AIA and update the staple) because both expire — the lab
regenerates them with `generate-certs.sh` (staple valid `OCSP_DAYS`, default 7)
and re-applies the secrets. Envoy defaults to `LENIENT_STAPLING` (serve without
staple if absent/expired rather than failing connections).

## Cleanup

```bash
envsubst < tests/mtls-ocsp-crl-revocation/manifests/30-passthrough-routes.yaml | oc delete -f -
oc -n req050-gateway delete envoyfilter req050-crl req050-ocsp
oc delete -f tests/mtls-ocsp-crl-revocation/manifests/25-referencegrant.yaml
envsubst < tests/mtls-ocsp-crl-revocation/manifests/20-httproute.yaml | oc delete -f -
envsubst < tests/mtls-ocsp-crl-revocation/manifests/10-gateway.yaml | oc delete -f -
oc -n req050-gateway delete secret req050-server-tls req050-intermediate-ca req050-crl
oc delete -f tests/mtls-ocsp-crl-revocation/manifests/00-namespace.yaml
rm -rf tests/mtls-ocsp-crl-revocation/manifests/certs
```

## Requirement context

Demonstrates **certificate revocation** controls on top of the mTLS Gateway
pattern from [REQ 51](../gateway-mtls-enforcement/README.md). Two listeners on the same Istio-backed
Gateway prove two distinct mechanisms:

| Listener | Hostname | Control |
|----------|----------|---------|
| `https-crl`  | `req050-crl.*`  | mTLS + CRL — a **revoked** client cert is rejected |
| `https-ocsp` | `req050-ocsp.*` | mTLS + OCSP stapling — the gateway **staples** its server cert's OCSP response |

Both are applied via **EnvoyFilter** patching the Envoy
`DownstreamTlsContext` per SNI — the only path that exposes `crl` and
`ocsp_staple` (no native Gateway API or Istio CRD surfaces these fields).

## How it works

- **CRL listener** — extends `validation_context` with a `crl` file
  (mounted Secret). Clients whose serial number appears in the CRL are
  rejected during the TLS handshake.
- **OCSP listener** — the OCSP staple is delivered through the SDS TLS
  secret (`tls.ocsp-staple` key); Istio/Pilot forwards it inline on the
  SDS cert. Envoy defaults to `LENIENT_STAPLING`.
- Envoy **never** fetches CRL/OCSP from the certificate's CDP/AIA URLs;
  both are supplied as static files and must be refreshed out-of-band.

## Files

- [tests/mtls-ocsp-crl-revocation/](req050/) — manifests, cert generation script, and test page
- [tests/mtls-ocsp-crl-revocation/index.html](mtls-ocsp-crl-revocation/index.html) — interactive PoC console
- [tests/mtls-ocsp-crl-revocation/manifests/](mtls-ocsp-crl-revocation/manifests/) — Kubernetes resources
- [tests/mtls-ocsp-crl-revocation/README.md](mtls-ocsp-crl-revocation/README.md) — full setup instructions and technical notes

## Quick start

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster

cd tests/mtls-ocsp-crl-revocation/manifests
./generate-certs.sh      # build PKI, revoke one client, emit CRL + OCSP staple
./deploy.sh              # namespace, secrets, gateway, EnvoyFilters, routes
```

## Verify

```bash
CERTS=tests/mtls-ocsp-crl-revocation/manifests/certs
HOST_CRL=req050-crl.${RHCL_ZONE_ROOT_DOMAIN}
HOST_OCSP=req050-ocsp.${RHCL_ZONE_ROOT_DOMAIN}

# PASS — valid (non-revoked) client on CRL listener
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-valid.crt --key $CERTS/client-valid.key \
  "https://$HOST_CRL/api/tls/info"

# FAIL — revoked client (CRL rejects it)
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-revoked.crt --key $CERTS/client-revoked.key \
  "https://$HOST_CRL/api/tls/info"

# PASS — inspect OCSP staple (Cert Status: good)
openssl s_client -connect ${HOST_OCSP}:443 -servername ${HOST_OCSP} -status \
  -cert $CERTS/client-valid.crt -key $CERTS/client-valid.key </dev/null \
  | grep -E "OCSP Response Status|Cert Status"
```

Run the full interactive test script: `./test-req050.sh`

## What success looks like

- Valid client on `req050-crl.*` returns HTTP 200.
- Revoked / untrusted / missing client on `req050-crl.*` is rejected at the
  TLS handshake.
- `openssl s_client -status` on `req050-ocsp.*` shows
  `OCSP Response Status: successful` and `Cert Status: good`.

## Related

- [REQ 51 — Close mTLS by certificate chain](../gateway-mtls-enforcement/README.md) (base mTLS pattern this builds on)
- [REQ 56 — Expose APIs via mTLS](../gateway-mtls-enforcement/README.md)
- [REQ 55 — TLS 1.2 / 1.3](../frontend-tls-versions/README.md)
