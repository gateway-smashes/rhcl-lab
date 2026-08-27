---
title: Weighted load balancing
summary: Split traffic across backends by weight using the Gateway API / DNSPolicy.
category: Traffic & routing
status: done
---

# Weighted load balancing

Demonstrates the two weighted load-balancing axes RHCL supports — and how they
compose:

| Axis | Where it happens | Mechanism |
|------|----------------|-----------|
| **Backend (intra-cluster)** | Inside the cluster, in Envoy | `HTTPRoute.spec.rules[].backendRefs[].weight` |
| **DNS (inter-cluster)** | Before reaching the cluster, at hostname resolution | `DNSPolicy.spec.loadBalancing.weight` on external providers (Route 53, Azure DNS, Cloud DNS) |

Both use the `banking-api-v1` and `banking-api-v2` backends, which run the **same
image** with a different `APP_INSTANCE_NAME` env — the backend returns that env
in the `instance` field, the source of truth for which Service the gateway
chose per call.

## What it demonstrates

- An `HTTPRoute` splitting `/api/whoami` across two weighted `backendRefs`
  (90/10 by default), each with a `RequestHeaderModifier` filter injecting
  `x-route-version: v1|v2`.
- Two orthogonal signals per request confirm the routing decision:

  | Signal | Source | What it confirms |
  | --- | --- | --- |
  | `data.instance` | Backend (Deployment env) | Which pod actually answered |
  | `data.allHeaders["x-route-version"]` | Gateway (`RequestHeaderModifier`) | The gateway's decision, independent of the backend |

- Adjusting weights recalculates the split in real time — the next burst
  reflects the new ratio without restarting pods.

> **Why `RequestHeaderModifier`, not `URLRewrite`, per backendRef?** The
> OpenShift Gateway API controller (Istio) supports `URLRewrite` only at the
> **rule** level (`HTTPRouteRule.filters`), not per `backendRef`
> (`HTTPBackendRef.filters`) — a per-backendRef `URLRewrite` is rejected with
> `unsupported filter type "URLRewrite"` (`InvalidFilter`).
> `RequestHeaderModifier` is core at both points, hence the header-injection
> approach.

## Files

- [index.html](index.html) — single-file console with an in-browser burst
  generator, tabulation by `instance` (and the `x-route-version` echo), and
  `oc`/`curl`/`yq` blocks ready to copy.
- [manifests/httproute-weighted.yaml](manifests/httproute-weighted.yaml) — the
  `HTTPRoute`: dedicated hostname (`weighted.${RHCL_ZONE_ROOT_DOMAIN}`), an
  `Exact` rule on `/api/whoami` with two weighted `backendRefs` (90/10 default)
  plus two unweighted shortcuts (`/api/v1`, `/api/v2`) for a sanity check.
- [manifests/dnspolicy-weighted.yaml](manifests/dnspolicy-weighted.yaml) — the
  `DNSPolicy` for the inter-cluster axis.

## Prerequisites

1. Gateway API + RHCL/Kuadrant active — the lab provisions the wildcard
   `rhcl-apps-gateway` in `openshift-ingress`; `weighted.${RHCL_ZONE_ROOT_DOMAIN}`
   matches the `*.${RHCL_ZONE_ROOT_DOMAIN}` listener.
2. Deployments `banking-api-v1` and `banking-api-v2` created by
   `automation/roles/apps` (namespace `rhcl-apps`), both Ready.
3. `oc` authenticated, able to create `HTTPRoute` in `rhcl-apps`.
4. `envsubst` available (ships with `gettext`).

## Run it

### Scenario 1 — intra-cluster (backend weights)

Apply the standalone dedicated-host route:

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.example.com   # your lab domain

envsubst < tests/weighted-load-balancing/manifests/httproute-weighted.yaml | oc apply -f -

# Accepted=True AND ResolvedRefs=True
oc -n rhcl-apps get httproute banking-api-weighted \
  -o jsonpath='{.status.parents[0].conditions}' | jq

# Effective accepted weights
oc -n rhcl-apps get httproute banking-api-weighted -o yaml \
  | yq '.spec.rules[0].backendRefs[] | {name: .name, weight: .weight, filters: .filters}'
```

Adjust the weights without recreating:

```bash
# 50 / 50
oc -n rhcl-apps patch httproute banking-api-weighted --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}
]'

# 0 / 100 (full promotion to v2)
oc -n rhcl-apps patch httproute banking-api-weighted --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":0},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":100}
]'
```

> There is also an **integrated** path: the main `banking-api-connectivity`
> route ships a public `/api/lb-test` rule (rendered by the `apps` role when
> `APPS_CONNECTIVITY_LB_TEST_ENABLED=true`, the default), which uses a
> **rule-level** `URLRewrite` (`/api/lb-test` → `/api/echo`). Patch its weights
> directly, or set `APPS_CONNECTIVITY_LB_V1_WEIGHT` / `..._V2_WEIGHT` via the
> role.

Then serve the page (any local port works — it only fires `fetch()`):

```bash
# from the repo root
python3 -m http.server 8080 --directory tests/weighted-load-balancing
# open http://localhost:8080
```

Set the expected weights (they only drive the verdict comparison; they do not
change the cluster), set N and concurrency, and click **Send sample** — the page
calls `GET /api/whoami` N times, tabulates `instance` and the `x-route-version`
echo, and shows the observed distribution, verdict, and per-`instance` table.

### Scenario 2 — inter-cluster (DNS weights)

> Requires a **second cluster** with its own gateway publishing the same
> hostname. `DNSPolicy.loadBalancing.weight` makes the DNS provider
> (Route 53 / Azure / GCP) return resolutions proportional to the weight.

```bash
# Cluster A (weight 80)
export WEIGHT=80 && envsubst < tests/weighted-load-balancing/manifests/dnspolicy-weighted.yaml | oc apply -f -
# Cluster B (weight 20)
export WEIGHT=20 && envsubst < tests/weighted-load-balancing/manifests/dnspolicy-weighted.yaml | oc apply -f -

# Or patch a managed DNSPolicy:
oc -n openshift-ingress patch dnspolicy rhcl-apps-gateway --type=merge \
  -p '{"spec":{"loadBalancing":{"weight":80}}}'
```

Both clusters must point at the same `RHCL_ZONE_ROOT_DOMAIN` and use the same
`RHCL_DNS_PROVIDER` with credentials scoped to the shared hosted zone.

**The two axes compose**: DNS picks the cluster, the HTTPRoute picks the
backend — e.g. Cluster A (80% via DNS, backend v1=70/v2=30) + Cluster B (20% via
DNS, backend v1=0/v2=100) yields an effective v1=56%, v2=44%.

## What to look for

With `N=100` and weights `v1=90, v2=10`, a typical sample:

```text
v1   88  88.0%   expected 90.0%   deviation  −2.0 pp
v2   12  12.0%   expected 10.0%   deviation  +2.0 pp
```

Verdict: **consistent with the weights** (tolerance at N=100 is
`max(5, 30/√100) = 5 pp`). By shell:

```bash
N=200
URL="https://weighted.${RHCL_ZONE_ROOT_DOMAIN}/api/whoami"
for i in $(seq 1 $N); do curl -s "$URL" | jq -r '.instance'; done \
  | sort | uniq -c | awk '{printf "%-4s %s (%s%%)\n", $1, $2, ($1*100)/'"$N"'}'
# 180  banking-api-v1 (90%)
#  20  banking-api-v2 (10%)
```

For the DNS axis, resolve the hostname repeatedly and observe distinct cluster
IPs proportional to the weights (use `dig +nocache` or different resolvers to
avoid caching).

## How it works — notes

- **Weights need not sum to 100.** The Gateway API normalizes at evaluation time
  (`9` + `1` ≡ `90` + `10`). Base 100 just reads more naturally as a canary.
- **Weight `0` zeroes a backend** — the idiomatic way to drain v1 (or v2) without
  deleting it from the resource, useful before a full promotion.
- **Not `mirroring`** — `RequestMirror` is fire-and-forget and discards the
  mirrored response; `weight` is the right primitive to split *real* traffic.
- **`instance` reflects the Deployment, not the pod** (fixed `APP_INSTANCE_NAME`).
  Fine for v1 vs v2 here; to distinguish replicas, switch the env to
  `valueFrom.fieldRef: metadata.name`.
- **DNS geo:** the `geo` field in `loadBalancing` enables a geographic strategy
  (`GEO-NA`, `GEO-EU`, …); without it, weight is evaluated globally.

## Cleanup

```bash
oc -n rhcl-apps delete httproute banking-api-weighted
```

The `banking-api-v1` / `banking-api-v2` Services and Deployments remain available
through the lab's other HTTPRoutes.
