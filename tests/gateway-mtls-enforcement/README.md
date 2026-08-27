---
title: Gateway mTLS enforcement
summary: Enforce mutual TLS at the gateway (client-certificate authentication).
category: TLS & mTLS
status: done
---

# REQ 051 + 056 — Gateway mTLS enforcement

Manifests and tooling to expose APIs via **mutual TLS** (mTLS) using a
dedicated Gateway (backed by Istio via `openshift-default` GatewayClass) with
**EnvoyFilter** to require and validate client certificates.

Two listeners demonstrate two trust models:

| Listener | Hostname | Trusted CA | Purpose |
|----------|----------|-----------|---------|
| `https-single-ca` | `req056-mtls.*` | Intermediate CA only | REQ 056 — single-CA validation |
| `https-chain-ca` | `req051-mtls.*` | Root CA only | REQ 051 — certificate chain validation |

## Prerequisites

- OpenShift cluster with **Service Mesh 3.x** (Istio/Sail) and Gateway API CRDs.
- The `openshift-default` GatewayClass (backed by Istio).
- Backend `banking-api-v1` Service in namespace `rhcl-apps` (deployed by the
  lab automation).
- `openssl` CLI (for cert generation).
- `envsubst` (from `gettext` package).
- `python3` (for EnvoyFilter generation — handles multi-line PEM embedding).

## What gets created

| File | Purpose |
|------|---------|
| `manifests/generate-certs.sh` | Generates the full PKI (Root CA, Intermediate CA, server cert, 3 client certs). |
| `manifests/00-namespace.yaml` | `req051-gateway` namespace. |
| `manifests/10-gateway.yaml` | Gateway with two HTTPS listeners (TLS terminate, `openshift-default` class). |
| `manifests/15-envoyfilter-mtls.yaml` | Template doc describing the EnvoyFilter approach. |
| `manifests/deploy-envoyfilter.sh` | Generates EnvoyFilter JSON with inline CA PEM and applies it. |
| `manifests/deploy.sh` | One-shot script that deploys everything (namespace, secrets, gateway, envoyfilter, routes). |
| `manifests/20-httproute.yaml` | HTTPRoutes (one per hostname), path-split: `/api/echo` → `echo-server`, `/api` → `banking-api-v1`. |
| `manifests/25-referencegrant.yaml` | ReferenceGrant in `rhcl-apps` allowing the `/api` routes to reach `banking-api-v1` cross-namespace. |
| `manifests/30-passthrough-routes.yaml` | OpenShift Routes (TLS passthrough) so the gateway hostnames reach our gateway via the router. |
| `manifests/40-echo-backend.yaml` | Echo backend (`ealen/echo-server`) in `req051-gateway` — serves `/api/echo`, returning the full request (all headers, incl. XFCC) as JSON. Only the XFCC test uses it; every other test hits `banking-api-v1`. |

## How it works

The `openshift-default` GatewayClass is handled by Istio (OpenShift Service Mesh 3.x).
A Gateway with two HTTPS listeners creates a single Envoy listener (`0.0.0.0_443`)
with SNI-based filter chains (one per hostname).

Since OpenShift ships the **standard-channel** Gateway API CRDs (without the
experimental `frontendValidation` field), we use **EnvoyFilter** resources to
patch each filter chain's transport socket:

1. Set `require_client_certificate: true`
2. Inject `validation_context.trusted_ca` with the CA PEM content inline

The `deploy-envoyfilter.sh` script reads the CA cert files and generates proper
JSON manifests using Python (to handle multi-line PEM content in YAML/JSON safely).

### Traffic flow

```
Client → hostname DNS → Default OpenShift Router → passthrough Route → Gateway Pod (Envoy)
                                                                        ↓ mTLS validated
                                                                   banking-api-v1
```

The passthrough Routes (`30-passthrough-routes.yaml`) tell the default OpenShift
router to forward the encrypted TLS connection directly to our gateway service
without inspecting or terminating TLS. Our Envoy handles the full mTLS handshake.

## Certificate hierarchy

```
Root CA (CN=RHCL PoC Root CA)
 └── Intermediate CA (CN=RHCL PoC Intermediate CA)
      ├── Server cert (SAN=req051-mtls.DOMAIN, req056-mtls.DOMAIN, *.DOMAIN)
      ├── client-direct.crt (CN=banking-client-direct, signed by Root)
      └── client-chain.crt (CN=banking-client-chain, signed by Intermediate)

Untrusted CA (CN=Untrusted External CA)
 └── client-untrusted.crt (CN=untrusted-client)
```

## Setup

### Option A: One-shot deploy (recommended)

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster
cd tests/gateway-mtls-enforcement/manifests
./generate-certs.sh
./deploy.sh
```

### Option B: Step by step

#### 1. Generate certificates

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster
cd tests/gateway-mtls-enforcement/manifests
./generate-certs.sh
cd -
```

#### 2. Create namespace

```bash
oc apply -f tests/gateway-mtls-enforcement/manifests/00-namespace.yaml
```

#### 3. Create Secrets

```bash
NS=req051-gateway
CERTS=tests/gateway-mtls-enforcement/manifests/certs

# Server TLS Secret (used by both Gateway listeners)
oc -n $NS create secret tls req051-server-tls \
  --cert=$CERTS/server-fullchain.crt \
  --key=$CERTS/server.key

# Intermediate CA Secret (kept as backup, used by deploy-envoyfilter.sh)
oc -n $NS create secret generic req051-intermediate-ca-sdscert \
  --from-file=ca.crt=$CERTS/intermediate-ca.crt

# Root CA Secret (kept as backup, used by deploy-envoyfilter.sh)
oc -n $NS create secret generic req051-root-ca-sdscert \
  --from-file=ca.crt=$CERTS/root-ca.crt
```

#### 4. Deploy Gateway and HTTPRoutes

```bash
envsubst < tests/gateway-mtls-enforcement/manifests/10-gateway.yaml | oc apply -f -
envsubst < tests/gateway-mtls-enforcement/manifests/20-httproute.yaml | oc apply -f -
oc apply -f tests/gateway-mtls-enforcement/manifests/25-referencegrant.yaml
```

#### 5. Deploy EnvoyFilter (mTLS enforcement)

```bash
cd tests/gateway-mtls-enforcement/manifests && ./deploy-envoyfilter.sh
```

#### 6. Wait for the Gateway to be programmed

```bash
oc -n req051-gateway get gateway req051-mtls-gateway -w
# Wait for PROGRAMMED=True
```

## Verification

### Connectivity

The gateway hostnames resolve to the default OpenShift router. The
passthrough Routes (step 6 of deploy.sh) tell the router to forward the
encrypted connection to our gateway service, preserving the full mTLS handshake.

No `--resolve` or port-forward needed — just use the real hostnames:

### REQ 056 — Single-CA validation (`req056-mtls.*`)

```bash
CERTS=tests/gateway-mtls-enforcement/manifests/certs
HOST=req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}

# PASS — client cert signed by Intermediate CA
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-chain.crt --key $CERTS/client-chain.key \
  "https://$HOST/api/tls/info"

# FAIL — client cert signed by Root CA (not directly trusted)
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://$HOST/api/tls/info"

# FAIL — untrusted CA
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://$HOST/api/tls/info"

# FAIL — no client cert
curl -v --cacert $CERTS/root-ca.crt \
  "https://$HOST/api/tls/info"
```

### REQ 051 — Chain-CA validation (`req051-mtls.*`)

```bash
HOST=req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}

# PASS — client cert signed by Intermediate, sends full chain bundle
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-chain-bundle.crt --key $CERTS/client-chain.key \
  "https://$HOST/api/tls/info"

# PASS — client cert signed directly by Root CA
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://$HOST/api/tls/info"

# FAIL — untrusted CA
curl -v --cacert $CERTS/root-ca.crt \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://$HOST/api/tls/info"

# FAIL — no client cert
curl -v --cacert $CERTS/root-ca.crt \
  "https://$HOST/api/tls/info"
```

### Validation matrix

| Listener | Client cert | Expected |
|----------|-------------|----------|
| `https-single-ca` (req056) | `client-chain.crt` (signed by Intermediate) | **PASS** — HTTP 200 |
| `https-single-ca` (req056) | `client-chain-fullchain.crt` (leaf + Intermediate + Root) | **PASS** — HTTP 200 (path stops at the trusted Intermediate; extra Root ignored) |
| `https-single-ca` (req056) | `client-direct.crt` (signed by Root) | **FAIL** — TLS rejected |
| `https-single-ca` (req056) | `client-untrusted.crt` | **FAIL** — TLS rejected |
| `https-single-ca` (req056) | (none) | **FAIL** — TLS rejected |
| `https-chain-ca` (req051) | `client-chain-bundle.crt` (Intermediate → Root chain) | **PASS** — HTTP 200 |
| `https-chain-ca` (req051) | `client-direct.crt` (signed by Root) | **PASS** — HTTP 200 |
| `https-chain-ca` (req051) | `client-untrusted.crt` | **FAIL** — TLS rejected |
| `https-chain-ca` (req051) | (none) | **FAIL** — TLS rejected |
| `https-accept-untrusted` | `client-untrusted.crt` (untrusted CA) | **PASS** — HTTP 200 (trust not enforced) |
| `https-accept-untrusted` | `client-chain.crt` (any presented cert) | **PASS** — HTTP 200 |
| `https-accept-untrusted` | (none) | **FAIL** — TLS rejected (`require_client_certificate`) |

> **`trust_chain_verification: ACCEPT_UNTRUSTED`** (listener `https-accept-untrusted`,
> host `req051-untrusted.*`) makes chain-trust **non-fatal**: any presented client cert
> is accepted regardless of issuing CA — the same `client-untrusted.crt` that is rejected
> by `https-single-ca` is accepted here. Envoy still **requires a `trusted_ca`** to be set,
> and `ACCEPT_UNTRUSTED` also **disables SAN matching** (`match_typed_subject_alt_names` is
> not enforced) — to gate by SAN you must use `VERIFY_TRUST_CHAIN`. Verified on OSSM Envoy
> 1.35 (OpenSSL build).

### Forwarding the client cert to the backend (XFCC)

mTLS is terminated at the gateway, so the backend sees plain HTTP and can't inspect
the client cert directly. To pass it through, the `req051-xfcc` EnvoyFilter patches the
gateway's HTTP Connection Manager to inject the **`x-forwarded-client-cert`** header:

```yaml
forward_client_cert_details: SANITIZE_SET      # Istio defaults to SANITIZE (strips it)
set_current_client_cert_details: { subject: true, cert: true, chain: true, dns: true, uri: true }
```

Because it lives on the HCM (shared by all SNI filter chains on `0.0.0.0_443`), it applies
to every host on this gateway. The echo backend then shows it, e.g. via `GET /api/echo`:

```
x-forwarded-client-cert: Hash=a0a2...;Subject="CN=banking-client-chain,O=RHCL-PoC,...";
  Cert="-----BEGIN%20CERTIFICATE-----%0A...";Chain="..."
```

`Cert` is the leaf certificate PEM (URL-encoded); `Chain` is the full presented chain.
Test 13 (`./test-mtls.sh 13`) verifies the backend received the XFCC with `Cert=`.

### Expected `/api/tls/info` response (on success)

```json
{
  "instance": "banking-api-v1",
  "timestamp": "2026-06-30T19:50:08.010Z",
  "scheme": "http",
  "isSSL": false,
  "forwardedProto": "https",
  "alpn": "HTTP_1_1",
  "note": "Request was not TLS-terminated by this JVM (plain HTTP or TLS terminated upstream by the gateway)."
}
```

The `forwardedProto: "https"` confirms the request traversed TLS at the gateway.
mTLS enforcement is proven by the rejection of unauthenticated or untrusted clients.

## Technical notes

### Why EnvoyFilter with inline CA?

1. OpenShift Service Mesh 3.x uses the **standard-channel** Gateway API CRDs,
   which do not include the experimental `frontendValidation` field.
2. The `openshift-default` GatewayClass creates a single Envoy listener
   `0.0.0.0_443` with SNI-based filter chains (not separate listeners per hostname).
3. Istio SDS (Secret Discovery Service) only auto-exposes secrets referenced in
   Gateway `certificateRefs` — generic secrets for client CA validation are NOT
   auto-mounted or exposed via SDS.
4. The EnvoyFilter patches each filter chain (matched by SNI) to add
   `require_client_certificate: true` and `validation_context.trusted_ca` with
   the CA PEM content embedded inline.

### Portability

- The `deploy-envoyfilter.sh` script reads CA certs from the `./certs/` directory
  at deploy time and generates JSON manifests. This makes the solution portable
  across any cluster — just regenerate certs for the target domain.
- The only cluster-specific value is `RHCL_ZONE_ROOT_DOMAIN`.

## Cleanup

```bash
envsubst < tests/gateway-mtls-enforcement/manifests/30-passthrough-routes.yaml | oc delete -f -
oc -n req051-gateway delete envoyfilter req056-mtls-single-ca req051-mtls-chain-ca
oc delete -f tests/gateway-mtls-enforcement/manifests/25-referencegrant.yaml
envsubst < tests/gateway-mtls-enforcement/manifests/20-httproute.yaml | oc delete -f -
envsubst < tests/gateway-mtls-enforcement/manifests/10-gateway.yaml | oc delete -f -
oc -n req051-gateway delete secret req051-server-tls req051-intermediate-ca-sdscert req051-root-ca-sdscert
oc delete -f tests/gateway-mtls-enforcement/manifests/00-namespace.yaml
rm -rf tests/gateway-mtls-enforcement/manifests/certs
```

## Requirement context

Demonstrates that the RHCL / Gateway enforces **mutual TLS** and validates
client certificates through a **certificate chain** (Root CA → Intermediate CA
→ client leaf). Only clients presenting a certificate whose trust chain
terminates at the configured Root CA are allowed through.

## How it works

The Gateway listener `https-chain-ca` trusts **only the Root CA** (via an
EnvoyFilter with inline PEM). When a client connects:

1. The client presents its leaf certificate **plus the Intermediate CA cert**
   in the TLS handshake.
2. The gateway (Envoy) builds the chain: leaf → intermediate → root.
3. If the root matches the trusted CA, the handshake succeeds.
4. If the client cert was signed by an unrelated CA, the handshake is rejected.

This proves REQ 51: mTLS closure by certificate chain — only certificates
within the trusted hierarchy are accepted.

## Files

- [tests/gateway-mtls-enforcement/](req051/) — manifests, cert generation script, and test page
- [tests/gateway-mtls-enforcement/index.html](gateway-mtls-enforcement/index.html) — interactive PoC console
- [tests/gateway-mtls-enforcement/manifests/](gateway-mtls-enforcement/manifests/) — Kubernetes resources
- [tests/gateway-mtls-enforcement/README.md](gateway-mtls-enforcement/README.md) — full setup instructions

## Quick start

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster

# Generate PKI + deploy everything
cd tests/gateway-mtls-enforcement/manifests
./generate-certs.sh
./deploy.sh
```

## Verify

```bash
CERTS=tests/gateway-mtls-enforcement/manifests/certs

# Port-forward (if LB not directly reachable)
oc -n req051-gateway port-forward svc/req051-mtls-gateway-openshift-default 8443:443 &

# PASS — client cert signed by Intermediate, full chain sent
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-chain-bundle.crt --key $CERTS/client-chain.key \
  "https://req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# PASS — client cert signed directly by Root
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# FAIL — untrusted CA (TLS handshake rejected)
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# FAIL — no client cert
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  "https://req051-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"
```

## What success looks like

- The first two `curl` commands return HTTP 200 with a JSON body from
  `/api/tls/info`.
- The last two `curl` commands fail at the TLS handshake level with
  connection reset (the gateway rejects the client).

## Related

- [REQ 56 — Expose APIs via mTLS](../gateway-mtls-enforcement/README.md) (same manifests, single-CA listener)
- [REQ 55 — TLS 1.2 / 1.3](../frontend-tls-versions/README.md)

## Single-CA mTLS variant (Item 56)

Demonstrates that the RHCL / Gateway exposes an API protected by **mutual TLS**
(mTLS). Clients must present a valid certificate signed by a **specific CA** to
access the API. Requests without a client certificate or with a certificate
from an untrusted CA are rejected at the TLS handshake level.

## How it works

The Gateway listener `https-single-ca` trusts **only the Intermediate CA**
(via an EnvoyFilter with inline PEM). When a client connects:

1. The gateway requests a client certificate during the TLS handshake.
2. If the client presents a certificate signed directly by the Intermediate CA,
   the handshake succeeds.
3. If the client presents a certificate signed by a different CA (even the
   Root CA that signed the Intermediate), the handshake is rejected.

This proves REQ 56: APIs are exposed via mTLS, accessible only to clients
holding a certificate from the trusted CA.

## Files

- [tests/gateway-mtls-enforcement/](req051/) — shared manifests with REQ 51 (same Gateway, different listener)
- [tests/gateway-mtls-enforcement/index.html](gateway-mtls-enforcement/index.html) — interactive PoC console
- [tests/gateway-mtls-enforcement/manifests/](gateway-mtls-enforcement/manifests/) — Kubernetes resources
- [tests/gateway-mtls-enforcement/README.md](gateway-mtls-enforcement/README.md) — full setup instructions

## Quick start

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com   # adjust to your cluster

# Generate PKI + deploy everything
cd tests/gateway-mtls-enforcement/manifests
./generate-certs.sh
./deploy.sh
```

## Verify

```bash
CERTS=tests/gateway-mtls-enforcement/manifests/certs

# Port-forward (if LB not directly reachable)
oc -n req051-gateway port-forward svc/req051-mtls-gateway-openshift-default 8443:443 &

# PASS — client cert signed by Intermediate CA
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-chain.crt --key $CERTS/client-chain.key \
  "https://req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# FAIL — client cert signed by Root CA (not directly trusted by this listener)
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# FAIL — untrusted CA
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"

# FAIL — no client cert
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443:127.0.0.1" \
  "https://req056-mtls.apps.${RHCL_ZONE_ROOT_DOMAIN}:8443/api/tls/info"
```

## What success looks like

- The first `curl` command returns HTTP 200 with a JSON body from
  `/api/tls/info`.
- The remaining commands fail at the TLS handshake level (connection reset
  by the gateway).

## Related

- [REQ 51 — Close mTLS by certificate chain](../gateway-mtls-enforcement/README.md) (same manifests, chain-CA listener)
- [REQ 55 — TLS 1.2 / 1.3](../frontend-tls-versions/README.md)
