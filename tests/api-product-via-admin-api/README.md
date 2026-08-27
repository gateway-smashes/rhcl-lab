---
title: API product via the admin API
summary: Create and fully configure an API product end-to-end through the Kubernetes API — no proprietary admin console.
category: Platform & lifecycle
status: done
---

# API product via the admin API

Demonstrates that **the Kubernetes API IS the "admin API"** the requirement asks
for: any HTTP client / SDK can create and fully configure an API product
end-to-end — no console, no GitOps, no Ansible — just by calling the API server
with credentials.

The demo creates a **new path-based `pix-api` product** on the same gateway,
reusing the `banking-api-v1` backend (the product is pure control plane:
policies + APIProduct + APIKey, no new deployment).

## What makes up an "API product"

In RHCL / Kuadrant, a product is the composition of these CRs — all manipulable
through the API server's `/apis/...`:

| CR | Group / Version | Role |
|---|---|---|
| `HTTPRoute` | `gateway.networking.k8s.io/v1` | Routing, matches, filters (URLRewrite, headers) |
| `APIProduct` | `devportal.kuadrant.io/v1alpha1` | Product metadata (displayName, version, publishStatus) |
| `PlanPolicy` | `extensions.kuadrant.io/v1alpha1` | Tiers + per-plan rate limit (CEL predicate) |
| `AuthPolicy` | `kuadrant.io/v1` | Authentication (api-key, jwt, anonymous) + response headers |
| `Secret` (api-key) | `v1` (core) | The key value, the consumer identity |
| `APIKey` | `devportal.kuadrant.io/v1alpha1` | Key request/approval (governance) |
| `Role` + `RoleBinding` | `rbac.authorization.k8s.io/v1` | Permissions for whoever operates via the API |

## Prerequisites

- Cluster with RHCL / Kuadrant installed.
- banking-api already deployed in `rhcl-apps` (the demo reuses `banking-api-v1`).
- HTTPRoute `banking-api-connectivity` present (the script discovers the host
  from it); otherwise export `HOST=banking-api-connectivity.<your-zone>`.
- `oc` authenticated, able to create RBAC in `rhcl-apps` (typical cluster-admin).
- `python3` (JSON decoding in the scripts) and `envsubst` (`${HOST}` substitution).

## Files

```
tests/api-product-via-admin-api/
├── manifests/
│   ├── 00-httproute.yaml      ← HTTPRoute pix-api-connectivity (/pix/v1 → rewrite /api/echo)
│   ├── 01-apiproduct.yaml     ← APIProduct pix-api (Published)
│   ├── 02-planpolicy.yaml     ← pix-gold (unlimited) + pix-bronze (5/min)
│   ├── 03-authpolicy.yaml     ← api-key required (label app=pix-api-keys)
│   ├── 04-apikey-secret.yaml  ← Secret with api_key=pix-tester-secret (plan=pix-bronze)
│   ├── 05-apikey-cr.yaml      ← APIKey CR (dev-portal governance)
│   └── 06-rbac.yaml           ← SA req031-product-admin + Role/RoleBinding
└── scripts/
    ├── create-via-oc.sh           ← Declarative path (oc apply)
    ├── create-via-k8s-api.sh      ← Raw REST path (curl + SA Bearer token)
    └── cleanup.sh
```

## Run it

### Path A — declarative (`oc apply`)

```bash
cd tests/api-product-via-admin-api
./scripts/create-via-oc.sh
```

The script:
1. Discovers the `HOST` from `banking-api-connectivity` (or uses `$HOST`).
2. `envsubst` on the HTTPRoute + `oc apply` on each manifest.
3. Waits for `AuthPolicy.status.Enforced=True` (up to 60s).
4. Smoke test: 401 without a key, 200 with a key, and a 7× burst (bronze=5/min →
   the last 2 = 429).

### Path B — raw REST against the API server

```bash
cd tests/api-product-via-admin-api
./scripts/create-via-k8s-api.sh
```

The script:
1. Applies `06-rbac.yaml` via `oc` (the only cluster-admin step — creates the SA
   + permissions).
2. Mints an ephemeral (1h) token for the `req031-product-admin` SA.
3. Creates EACH CR via `curl POST $APISERVER/apis/.../namespaces/rhcl-apps/<resource>`
   authenticated **only by the Bearer token** (no `oc` from here on).
4. Lists APIProducts via REST to prove it.
5. Smoke test 401/200.

> **The point:** Path B shows that **any HTTP client** (curl, Postman, Python
> `requests`, Go client-go, …) has the same power as `oc`. There is no "admin
> console"; it is the Kubernetes API directly, with granular RBAC.

## What to look for

```bash
HOST=$(oc -n rhcl-apps get httproute banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}')
KEY=$(oc -n rhcl-apps get secret pix-api-key-tester -o jsonpath='{.data.api_key}' | base64 -d)

curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/pix/v1"                       # no auth → 401
curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" "https://$HOST/pix/v1"     # with key → 200
for i in $(seq 1 7); do curl -sk -o /dev/null -w "%{http_code} " -H "api-key: $KEY" "https://$HOST/pix/v1"; done; echo  # 429 after 5 in 60s (bronze)

# List the product via raw REST with the SA token
APISERVER=$(oc whoami --show-server)
TOKEN=$(oc -n rhcl-apps create token req031-product-admin --duration=10m)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/apis/devportal.kuadrant.io/v1alpha1/namespaces/rhcl-apps/apiproducts/pix-api" \
  | python3 -m json.tool | head -30
```

| Command | Expected |
|---|---|
| `oc get apiproduct pix-api -n rhcl-apps` | `spec.publishStatus=Published` |
| `oc get authpolicy pix-api-apikey -n rhcl-apps` | `Accepted=True / Enforced=True` |
| `oc get planpolicy pix-api-plans -n rhcl-apps` | `Accepted=True / Enforced=True` |
| `curl /pix/v1` no key | **401** |
| `curl /pix/v1` bronze key | **200** (5×), then **429** |
| Dev portal / console | "pix-api" listed as a Published product |

## Cleanup

```bash
cd tests/api-product-via-admin-api
./scripts/cleanup.sh
```

## Caveats

- **The dev portal must be enabled** for `APIProduct` to reconcile (in the
  `Kuadrant` CR: `spec.components.developerPortal.enabled=true`). Without it the
  CR is created but not reconciled — auth + rate limit still work (they come
  straight from `AuthPolicy`/`PlanPolicy`).
- **Policy conflict on the same HTTPRoute**: Kuadrant accepts 1 `AuthPolicy` + 1
  `RateLimitPolicy` per route. `PlanPolicy` **replaces** `RateLimitPolicy` (do
  not use both on the same route).
- **Path-based**: the product reuses the banking-api host. For a product on a
  separate host, add a listener to the `Gateway` (out of scope here).
- **api-key Secret vs APIKey CR**: real auth is via the `Secret` (selected by the
  `AuthPolicy` label). The `APIKey` CR is a governance object (request/approve)
  that lives in parallel — on approval the developer-portal-controller
  materializes its own Secret. This demo uses a fixed-value Secret for
  reproducibility.
