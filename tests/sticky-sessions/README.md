---
title: Sticky sessions
summary: Session affinity for banking-api through the Gateway API (consistent-hash / cookie stickiness).
category: Traffic & routing
status: done
---

# Sticky sessions (banking-api via Gateway API)

Session affinity across replicas of the `banking-api-v1` backend, configured by
an HTTP cookie at the gateway level (Istio `DestinationRule` with
`consistentHash.httpCookie`).

## What it demonstrates

- Baseline round-robin **without** a cookie spreads traffic across both pods.
- Envoy sets a `CUSTOM_COOKIE_SESSION` cookie on the first response.
- With that cookie, each session sticks to a **single** pod (hash-based, so
  different cookies may land on different pods, but each one stays stable).

## Files

| File | What it is |
|---|---|
| [`index.html`](index.html) | Standalone console: baseline (round-robin), the Envoy `Set-Cookie`, and a 5-cookies × N-requests test showing the per-pod distribution. Pre-fills the host from `apiHost` in `/env.json`. |
| [`destination-rule-mobile-bank-sticky-session.yaml`](destination-rule-mobile-bank-sticky-session.yaml) | Legacy manifest, kept for compatibility. **Do not use** — it points at the `mobile-bank` Service exposed via an OpenShift Route, which bypasses Istio. |

## How it works

Affinity is applied by **Istio**, through a `DestinationRule` with
`consistentHash.httpCookie` targeting the backend **Service**
(`banking-api-v1.rhcl-apps.svc.cluster.local`). Validation uses the public
`/api/echo` endpoint, which returns the pod name in the `instance` field.

| Layer | Role |
|---|---|
| `Gateway` + `HTTPRoute` | Expose banking-api via `rhcl-apps-gateway` |
| `DestinationRule` | Apply cookie affinity across the Service replicas |
| `banking-api-v1` (2+ replicas) | Backend that reports its pod in `/api/echo` |

> **Why NOT the OpenShift Route path (`*.apps.<cluster>`)** — the native
> OpenShift Router goes straight from HAProxy to the Kubernetes Service and
> **bypasses Istio**. The `DestinationRule` is silently ignored on that path,
> and any "stickiness" observed there comes from HAProxy's default cookie, not
> Envoy's `CUSTOM_COOKIE_SESSION`. Validation **must** go through the
> `rhcl-apps-gateway` hostname (Gateway API), never the OpenShift Route.

## Prerequisites

```bash
# Logged in to the cluster
oc whoami

# Backend installed, with at least 2 replicas
oc get deploy banking-api-v1 -n rhcl-apps

# banking-api Gateway and HTTPRoute working
oc get gateway rhcl-apps-gateway -n openshift-ingress
oc get httproute banking-api-connectivity -n rhcl-apps

# Base DestinationRule already present (sticky session is a patch on it)
oc get destinationrule banking-api-v1-http1 -n rhcl-apps
```

`/api/echo` must be public (no API key) and return JSON with `instance` = pod
name:

```bash
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
curl -sk "https://$HOST/api/echo" 2>/dev/null | python3 -c '
import json, sys
try:
    print("instance =", json.load(sys.stdin).get("instance"))
except Exception:
    print("instance = (no JSON — backend errored, retry)")
'
# instance = banking-api-v1-5575b4dd47-h29gc
```

## Run it

### Setup (once per cluster)

**1. Scale the backend to 2+ replicas.** Sticky session with **1 replica** is a
false positive: every request hits the same pod regardless of the DR.

```bash
oc scale deploy/banking-api-v1 -n rhcl-apps --replicas=2
oc rollout status deploy/banking-api-v1 -n rhcl-apps
```

**2. Make the backend report its pod name in `/api/echo`.** The banking-api
Quarkus app reads `APP_INSTANCE_NAME` and returns it in the `instance` field.
It defaults to a fixed `banking-api-v1`, which makes replicas
indistinguishable. Switching it to `valueFrom.fieldRef: metadata.name` makes
each pod report its own name.

```bash
# Remove the fixed value
oc set env deploy/banking-api-v1 -n rhcl-apps APP_INSTANCE_NAME-

# Add it as a fieldRef (pod name)
oc patch deploy/banking-api-v1 -n rhcl-apps --type=json -p '[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/0",
    "value": {
      "name": "APP_INSTANCE_NAME",
      "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}
    }
  }
]'

oc rollout status deploy/banking-api-v1 -n rhcl-apps
```

> **Side effect**: the `instance` label on the Prometheus metrics gains
> cardinality (one label per pod instead of one fixed value). That is fine for
> this demo; in production you would expose a second `APP_POD_NAME` env via
> `fieldRef` and have the backend use it in `/api/echo`.

**3. Patch the existing `DestinationRule` with the sticky cookie.** The
`DestinationRule banking-api-v1-http1` already exists (part of the banking-api
install) and manages the connection pool. We only **add** the sticky cookie to
its `loadBalancer`.

```bash
oc patch destinationrule banking-api-v1-http1 -n rhcl-apps --type=json -p '[
  {
    "op": "add",
    "path": "/spec/trafficPolicy/loadBalancer",
    "value": {
      "consistentHash": {
        "httpCookie": {
          "name": "CUSTOM_COOKIE_SESSION",
          "path": "/",
          "ttl": "1800s"
        }
      }
    }
  }
]'
```

Confirm:

```bash
oc get destinationrule banking-api-v1-http1 -n rhcl-apps -o jsonpath='{.spec.trafficPolicy.loadBalancer}'; echo
# {"consistentHash":{"httpCookie":{"name":"CUSTOM_COOKIE_SESSION","path":"/","ttl":"1800s"}}}
```

### Validation via `curl`

**1. Round-robin without a cookie (baseline).** Before validating stickiness,
show that **without a cookie** traffic reaches **both pods** — confirming the
`DestinationRule` is active but has not pinned anything.

```bash
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

for i in $(seq 1 10); do
  curl -sk "https://$HOST/api/echo" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("instance", ""))
except Exception:
    pass
' 2>/dev/null
done | grep -v '^$' | sort | uniq -c
# Expected (counts vary, but TWO distinct pods MUST appear):
#   4 banking-api-v1-5575b4dd47-h29gc
#   6 banking-api-v1-5575b4dd47-wkfmj
```

**2. Envoy Set-Cookie on the first request.**

```bash
curl -sk -i "https://$HOST/api/echo" | grep -i 'set-cookie'
# set-cookie: CUSTOM_COOKIE_SESSION="37c5519780cbe86f"; Max-Age=1800; Path=/; HttpOnly
```

> `Max-Age=1800` matches the DR's `ttl: 1800s`. **If the Set-Cookie comes with
> another name** (e.g. a hex MD5 hash without `CUSTOM_COOKIE_SESSION`), traffic
> is going through the OpenShift Route (HAProxy), not the Gateway. Check the
> hostname.

**3. Stickiness with 5 distinct cookies.** Each cookie must stick to **one**
pod; distinct cookies may land on different pods (distribution is hash-based).

```bash
for cookieval in aaa111 bbb222 ccc333 ddd444 eee555; do
  pods=$(for i in $(seq 1 8); do
    curl -sk -H "Cookie: CUSTOM_COOKIE_SESSION=$cookieval" \
         "https://$HOST/api/echo" 2>/dev/null \
      | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("instance", ""))
except Exception:
    pass
' 2>/dev/null
  done | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
  echo "cookie=$cookieval -> pods: $pods"
done
# Expected (each line shows a SINGLE pod in "pods"):
# cookie=aaa111 -> pods: banking-api-v1-5575b4dd47-wkfmj
# cookie=bbb222 -> pods: banking-api-v1-5575b4dd47-h29gc
# ...
# If a cookie returns an empty "pods:", all 8 requests for it failed (503/timeout).
# Confirm with: curl -sk -w '%{http_code}\n' -o /dev/null "https://$HOST/api/echo"
# and check logs: oc logs -n rhcl-apps -l app=banking-api-v1 --tail=50
```

## Troubleshooting

| Symptom | Diagnosis |
|---|---|
| Set-Cookie has an `<md5hash>` name instead of `CUSTOM_COOKIE_SESSION` | Traffic entered via the OpenShift Route, not the Gateway API. Confirm the hostname matches `spec.hostnames` of `HTTPRoute banking-api-connectivity`. |
| Round-robin happens even with a cookie | The DR was not applied, or its `host` does not match the Service. Check `oc get destinationrule banking-api-v1-http1 -n rhcl-apps -o yaml`. |
| 401 / 403 on `/api/echo` | A gateway-level deny-all AuthPolicy is catching it. The `/api/echo` route is `anonymous` in the `banking-api-connectivity-apikey` AuthPolicy — confirm that policy is `Enforced=True`. |
| `instance` is always the same but there are 2 replicas | `APP_INSTANCE_NAME` is still fixed. Re-run setup step 2 (`fieldRef metadata.name`). |
| Only 1 replica responds | One replica's health check is failing. `oc describe pod` on the one that does not answer. |
| Stickiness degrades after `oc rollout restart` | Expected — new pods have new names, so the cookie hash maps to a new bucket. Sessions opened before the restart "jump" to a random pod (stable from then on). |

## Cleanup (rollback)

```bash
# Revert the DR to its original state (no stickiness)
oc patch destinationrule banking-api-v1-http1 -n rhcl-apps --type=json -p '[
  {"op": "remove", "path": "/spec/trafficPolicy/loadBalancer"}
]'

# Revert APP_INSTANCE_NAME to a fixed value
oc patch deploy/banking-api-v1 -n rhcl-apps --type=json -p '[
  {"op": "remove", "path": "/spec/template/spec/containers/0/env/0"}
]'
oc set env deploy/banking-api-v1 -n rhcl-apps APP_INSTANCE_NAME=banking-api-v1
oc rollout status deploy/banking-api-v1 -n rhcl-apps

# (Optional) back to 1 replica
oc scale deploy/banking-api-v1 -n rhcl-apps --replicas=1
```
