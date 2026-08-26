# REQ 55 — Expose APIs with TLS 1.2 / 1.3 (PoC)

Static HTML PoC that demonstrates the API exposed by the RHCL / Gateway is
reachable over **TLS 1.2** and **TLS 1.3**, and that legacy versions
(TLS 1.0 / 1.1, SSLv3) are rejected.

The HTTPS exposure itself is provisioned by a Kuadrant
[`TLSPolicy`](https://docs.kuadrant.io/1.0.x/kuadrant-operator/doc/user-guides/tls/gateway-tls/)
backed by cert-manager.

## Files

- [index.html](index.html) — single-file PoC console (no build step).
- [kuadrant/](kuadrant/) — `Gateway` + self-signed `ClusterIssuer` + `TLSPolicy`
  + `HTTPRoute` manifests. Apply with `oc apply -k tests/req055/kuadrant` and
  see [kuadrant/README.md](kuadrant/README.md).

> **Note on TLS versions and TLSPolicy.** The Kuadrant `TLSPolicy` resource
> only drives cert-manager to issue/rotate the serving certificate — its
> spec exposes only `targetRef` and `issuerRef`, with no
> `minVersion` / `maxVersion` field. The accepted TLS protocols are decided
> by the Istio / Envoy data plane, whose defaults already accept 1.2 and 1.3
> and reject 1.0 / 1.1. So applying a TLSPolicy on top of an HTTPS Gateway
> listener is sufficient to satisfy REQ 55.

## Run the page

```bash
# from the repo root
python3 -m http.server 8080 --directory tests/req055
# then open http://localhost:8080
```

Any port works; the browser fetches the backend via HTTPS, so the only
requirement is that the page can reach the Gateway/route created by the
manifests in [kuadrant/](kuadrant/).

## How to use the page

The browser does **not** let JavaScript pick a TLS version — the OS/network
stack negotiates that. So the page is split in two halves:

1. **Browser side (best-effort).**
   - Open DevTools → **Security** tab before clicking *Fetch from browser*.
     The Security panel shows the negotiated TLS version and the certificate
     chain.
   - *Fetch from browser* fires a normal HTTPS GET against the backend URL and
     shows the HTTP status / body, proving that the handshake succeeded with
     whatever version the browser preferred (modern browsers default to 1.3).
   - *Probe /api/tls/info* hits the backend's TLS introspection endpoint
     (when present) so the server tells you exactly what it negotiated:
     `tlsVersion`, `cipherSuite`, `alpn`, `scheme`.

2. **Shell side (authoritative).**
   The bottom of the page renders ready-to-copy commands that force a single
   TLS version, which is the proper way to validate REQ 55:
   - `curl --tlsv1.3 --tls-max 1.3` → must succeed.
   - `curl --tlsv1.2 --tls-max 1.2` → must succeed.
   - `curl --tlsv1.1 --tls-max 1.1` → must fail (`alert protocol version`).
   - `openssl s_client -tls1_3` / `-tls1_2` → prints the exact `Protocol`
     and `Cipher` lines.
   - `nmap --script ssl-enum-ciphers` → enumerates every protocol/cipher the
     gateway accepts (one-shot full inventory).

   Each command block has a *Copy* button. Paste into a terminal and run.

## Backends used in this PoC

| Preset | URL | Notes |
| --- | --- | --- |
| Direct → cluster1.poc | `https://banking-api-v1-rhcl-apps.apps.cluster1.poc.rhcl.com.br/api/v1/accounts/summary` | Default OpenShift route in the lab cluster. |
| Direct → mycluster | `https://banking-api-v1-rhcl-apps.apps.mycluster.sandbox3066.opentlc.com/api/v1/accounts/summary` | Default OpenShift route in the mycluster lab. |
| Via RHCL Gateway | configured at runtime, persisted in `localStorage` | URL exposed by the `Gateway` + `HTTPRoute` covered by the `TLSPolicy` in [kuadrant/](kuadrant/) — typically `https://req55-banking.apps.<cluster>/api/v1/accounts/summary`. |

The Gateway URL is filled at runtime via the *RHCL Gateway URL* field and the
*Save* button. The value is kept in `localStorage` so it survives page reloads.

## What "success" looks like

**Browser fetch** (against the Kuadrant gateway URL):

- HTTP status `200 OK` and a JSON body in the log.
- DevTools → *Security* shows
  `Connection — secure (strong) · TLS 1.3 · AES-256-GCM` (or 1.2).

**`/api/tls/info` probe** (when the backend exposes it):

```json
{
  "tlsVersion": "TLSv1.3",
  "cipherSuite": "TLS_AES_256_GCM_SHA384",
  "alpn": "HTTP_2",
  "scheme": "https",
  "isSSL": true
}
```

`tlsVersion` toggling between `TLSv1.3` and `TLSv1.2` (depending on the client
flag) is the direct proof for REQ 55.

**curl — TLS 1.3 only:**

```
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / ...
* ALPN: server accepted h2
< HTTP/2 200
```

**curl — TLS 1.2 only:**

```
* SSL connection using TLSv1.2 / ECDHE-RSA-AES256-GCM-SHA384 / ...
< HTTP/2 200
```

**curl — TLS 1.1 (must fail):**

```
* OpenSSL/3.x: error:0A000410:SSL routines::sslv3 alert handshake failure
* Closing connection
curl: (35) ... alert protocol version
```

`nmap` prints something like: (this is probably the best test)

```
PORT    STATE SERVICE
443/tcp open  https
| ssl-enum-ciphers:
|   TLSv1.2: ... (multiple ciphers, A grade)
|   TLSv1.3: ... (TLS_AES_256_GCM_SHA384, etc.)
|_  least strength: A
```

If TLS 1.0 or 1.1 appear in the `nmap` output, the data plane is
misconfigured — REQ 55 fails.

## Mixed-content note

If you serve this page from `https://` (e.g. GitHub Pages) the browser will
also block `http://...` backend calls as **mixed content**. For REQ 55 every
backend must already be `https://`, so this is generally not an issue — but if
you add a plain HTTP preset to compare, expect the browser to block it before
the request even reaches the network.
