---
title: Rate limiting
summary: Per-plan and per-consumer request rate limiting with Kuadrant RateLimitPolicy.
category: Rate limiting
status: done
---

# Rate limiting

Demonstrates the full range of Kuadrant `RateLimitPolicy` — global (same-site and
multi-site), custom per-field counters, API-level vs Gateway-level, and
delegation to an external counter store (Redis).

| Facet | What it shows | Manifest |
|------|-----------------|----------|
| Global, same site | Simple RLP; counters shared across Gateway replicas | `manifests/01-global-same-site.yaml` |
| Global, distinct sites | Limitador pointed at a shared Redis — externalized counters | `manifests/02-limitador-redis.yaml` + `06-redis-shared-store.yaml` |
| Custom counters | Per-header (`x-customer-id`) and per-source-IP limits | `manifests/03-custom-counters.yaml` |
| API vs Gateway | Gateway-level `defaults` (and commented `overrides`) | `manifests/04-api-vs-gateway.yaml` |
| External delegation | The Envoy → external rate-limit-service architecture | `manifests/05-external-architecture.md` |

## How it works

```
   client ── HTTPS ──► Envoy ─gRPC─►  Limitador (Kuadrant)
                        │             Storage:
                        │              • in-memory   (default — same-site only)
                        │              • disk (PVC)
                        │              • redis         ◄── multi-site / external state
                        │              • redis-cached
                        ▼
                     backend
```

- **Envoy** (on the Gateway) is the enforcement point: per request it consults the
  external rate-limit service over gRPC and blocks/passes based on the response.
- **Limitador** (`limitador.kuadrant.io/v1alpha1`) is that external service,
  implementing the `envoy.service.ratelimit.v3.RateLimitService` contract.
- **Kuadrant Operator** compiles a high-level `RateLimitPolicy` into Envoy config
  + entries on the `Limitador` CR.
- The **storage backend** defines the scope of "global": single-site (in-memory)
  vs multi-site (shared Redis).

The five facets map to the classic requirement set: global same-site, global
multi-site, custom fields, API-and/or-Gateway level, and delegation to an
external service.

## Prerequisites

```bash
oc whoami
oc get httproute banking-api-connectivity -n rhcl-apps
oc get gateway rhcl-apps-gateway -n openshift-ingress
oc get limitador limitador -n kuadrant-system
```

`/api/echo` is public (no API key) — used for demos that don't need auth. For
scenarios that exercise `auth.identity.userid`, use `/api/v1/...` with a
gold/silver/bronze API key (see `demo-environment/README.md`).

## Run it

### Global, same site

```bash
oc apply -f manifests/01-global-same-site.yaml
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

# 60 requests IN PARALLEL (sequential curl spreads over time via the TLS
# handshake and never violates the 10s window — use `&` + `wait`).
{ for i in $(seq 1 60); do curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/api/echo" & done; wait; } | sort | uniq -c
# With policy 20/10s: 20× 200 + 40× 429
```

To prove the limit is shared across Gateway replicas, `oc scale` the Gateway
Deployment to 3 and repeat — it still caps at 20/10s, because all three Envoys
talk to the same Limitador.

### Custom counters

```bash
oc apply -f manifests/03-custom-counters.yaml
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

# Two customers, independent counters (limit 5/min each)
{ for i in $(seq 1 10); do curl -sk -o /dev/null -w "alpha=%{http_code}\n" -H "x-customer-id: alpha" "https://$HOST/api/echo" & done; wait; } | sort | uniq -c
{ for i in $(seq 1 10); do curl -sk -o /dev/null -w "beta=%{http_code}\n"  -H "x-customer-id: beta"  "https://$HOST/api/echo" & done; wait; } | sort | uniq -c
# alpha 5/5, beta 5/5 — counters separated by header value
```

Per-authenticated-user counters are already wired via the `PlanPolicy
banking-api-plans`, which generates an RLP keyed on the plan-id annotation
(gold=unlimited, silver=50/min, bronze=10/min):

```bash
{ for i in $(seq 1 15); do curl -sk -o /dev/null -w "bronze=%{http_code}\n" -H "api-key: carol-bronze-secret" "https://$HOST/api/v1/accounts/summary" & done; wait; } | sort | uniq -c
# 10× 200 + 5× 429
```

> **Composition note:** an RLP and the `PlanPolicy` on the same target make one
> `Overridden`. Only **one RLP per target** is enforced — for composition use
> distinct targets (HTTPRoute + Gateway with `overrides`) or `sectionName`.

### API-level vs Gateway-level

```bash
oc apply -f manifests/01-global-same-site.yaml   # API-level (HTTPRoute)
oc apply -f manifests/04-api-vs-gateway.yaml      # Gateway-level
```

A request must pass both limits; the more restrictive wins. To make the
Gateway-level limit **non-negotiable**, change `defaults:` to `overrides:` in
`04-api-vs-gateway.yaml` — then even an API team setting `100000/s` cannot exceed
the ceiling.

### Multi-site with shared Redis (external state)

By default Limitador keeps counters **in memory** in its own pod. For true global
(and multi-site) rate limiting, the state must move to an external store. Here we
use a **Redis in a dedicated `shared-store` namespace**.

```bash
# 1. Bring up Redis
oc apply -f manifests/06-redis-shared-store.yaml
oc -n shared-store rollout status deploy/redis

# 2. Point Limitador at Redis
oc apply -f manifests/02-limitador-redis.yaml
oc -n kuadrant-system rollout status deploy/limitador-limitador
oc -n kuadrant-system get limitador limitador -o jsonpath='{.spec.storage}'; echo

# 3. Validate — burst, then PROVE the state is in Redis (not pod memory)
oc apply -f manifests/01-global-same-site.yaml
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
{ for i in $(seq 1 60); do curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/api/echo" & done; wait; } | sort | uniq -c
POD=$(oc -n shared-store get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')
oc -n shared-store exec $POD -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --scan' | grep -i counter
```

**Multi-site** (validated across two independent AWS clusters, both `us-east-2`):
each cluster runs its own Limitador but **all point at the same Redis**. Cluster A
hosts the Redis and exposes it via a `LoadBalancer` Service (TCP 6379) restricted
with `loadBalancerSourceRanges` to cluster B's egress IP (the demo Redis has no
TLS/ACL, so the source-range is the network lock). Cluster B's `limitador-redis`
Secret URL points at cluster A's LB.

**The limit comes from the RateLimitPolicy**, which must be **identical on both
clusters** (same `spec.limits` against the same-named HTTPRoute) so both derive
the same counter key → one shared counter in Redis → `20/10s` applies to the
*pair* of sites, not per site:

```bash
# On EACH cluster — must print exactly the same thing:
oc get ratelimitpolicy req061-global-same-site -n rhcl-apps -o jsonpath='{.spec.limits}{"\n"}'
#   {"global-burst":{"rates":[{"limit":20,"window":"10s"}]}}
oc get ratelimitpolicy req061-global-same-site -n rhcl-apps \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
#   Accepted=True Enforced=True
```

> **⚠️ `redis` vs `redis-cached`** decides the multi-site guarantee.
> `redis-cached` keeps a **local counter cache per site** and syncs to Redis in
> batches — good for latency, but it **over-admits** (a cold-cache site admits
> before seeing others' usage). Pure `redis` checks Redis on every request →
> **strict** global limit. For a strict cross-site limit, set `storage` to `redis`
> on **both** clusters:
>
> ```bash
> oc -n kuadrant-system patch limitador limitador --type=json \
>   -p '[{"op":"replace","path":"/spec/storage","value":{"redis":{"configSecretRef":{"name":"limitador-redis"}}}}]'
> ```
>
> Small overages (23 instead of 20) are normal under concurrency — check-then-
> increment is not atomic on a burst.

> **Production**: `06-redis-shared-store.yaml` uses `emptyDir` (volatile) and no
> TLS. For production use a PVC + replication/Sentinel or a managed Redis, and
> `rediss://` (TLS) in the URL.

### External delegation (item detail)

The architecture is **already delegated by design** — Envoy does not compute the
limit; it calls the external `RateLimitService` over gRPC. Limitador is one
implementation of that contract; others (Lyft `ratelimit`, commercial services)
are compatible. See [`manifests/05-external-architecture.md`](manifests/05-external-architecture.md).

## What to look for

Open the `mobile-bank` frontend → **PoC Console → Rate Limiting**: pick a
scenario, click **Run**, and watch the 200-vs-429 histogram over time, average
latency, and the per-bucket distribution (alpha/beta/…). The standalone
[`index.html`](index.html) has the same functionality.

## Troubleshooting

| Symptom | Diagnosis |
|---------|-------------|
| No 429 even after many sequential requests | Sequential `curl` adds ~200ms between requests (TLS handshake), so the 10s window may not be exceeded. Use **parallel**: `{ for i in ...; do curl … & done; wait; }` |
| Limitador CrashLoops after an RLP with `request.headers["..."]` | Quoting bug — double quotes inside the CEL nest into the descriptor key unescaped. Use **single quotes**: `request.headers['x-customer-id']`. |
| An RLP with 3+ `limits` entries applies nothing | Observed when one entry uses `auth.identity` and another uses only `request.*`. Limit to **2 entries** per RLP, or compose separate RLPs with distinct `sectionName`. |
| Limits differ across clusters despite Redis | Check Limitador → Redis connectivity (`oc logs deploy/limitador-limitador -n kuadrant-system \| grep -i redis`). Latency > timeout falls back to the local cache and diverges counters. |
| Gateway RLP has no effect | When Gateway-level `defaults` and API-level coexist, API-level wins. For an absolute ceiling use `overrides:` at the Gateway level. |
| Multiple RLPs `Enforced=False`/`Overridden` | Only **one RLP per target** is enforced — use distinct targets or `sectionName`. |

## Cleanup

```bash
oc delete -f manifests/01-global-same-site.yaml -f manifests/03-custom-counters.yaml \
          -f manifests/04-api-vs-gateway.yaml --ignore-not-found

# Revert Limitador to in-memory and drop Redis
oc -n kuadrant-system patch limitador limitador --type=merge -p '{"spec":{"storage":null}}'
oc -n kuadrant-system delete secret limitador-redis --ignore-not-found
oc delete -f manifests/06-redis-shared-store.yaml --ignore-not-found
```

> Don't `oc delete -f manifests/` with a glob: it includes
> `05-external-architecture.md` (not a manifest) and errors. List the YAMLs
> explicitly.
