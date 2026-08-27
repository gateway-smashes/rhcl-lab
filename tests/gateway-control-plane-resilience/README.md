---
title: Gateway resilience to a control-plane outage
summary: The gateway data plane keeps serving traffic while the RHCL / Istio control plane is unavailable.
category: Traffic & scaling
status: done
---

# Gateway resilience to a control-plane outage

Demonstrates that the data plane (Istio ingress gateway) keeps routing traffic
normally even when the entire RHCL / Kuadrant control plane is down. Routes,
policies and configuration already applied stay active because they are
materialized in the Envoy/Istio config — the operators are needed only to
**reconcile changes**, not to keep traffic flowing.

> **Requirement:** the gateways must survive a "manager" outage without
> interrupting any functionality. RHCL has no centralized "API Manager" (unlike
> 3scale) — the control plane is a set of Kubernetes operators, the data plane is
> the Istio gateway. Here the "manager" is the operator set in `kuadrant-system`.

## What it demonstrates

Scale the four Kuadrant operators to zero and confirm the gateway keeps serving —
REST returns 200, WebSocket stays connected — then restore them and they resume
reconciling with no manual action.

| Component | Deployment |
|---|---|
| Kuadrant Operator | `kuadrant-operator-controller-manager` |
| Authorino Operator | `authorino-operator` |
| Limitador Operator | `limitador-operator-controller-manager` |
| DNS Operator | `dns-operator-controller-manager` |

## Files

- [index.html](index.html) — standalone console with the demo script (scale the
  operators down, probe traffic, restore). Pre-fills the host from `apiHost` in
  `/env.json`. Every step is also a copy-paste CLI command.

## Prerequisites

- OpenShift with RHCL installed and the banking-api answering through the gateway.
- `cluster-admin` (to `oc scale deploy/... -n kuadrant-system`).
- The page uses CORS against the gateway — the banking-api `HTTPRoute` already
  carries the headers (from the `cors-policy` item).

## Run it

**1. Verify the initial state** — all operators `READY 1/1`:

```bash
oc get deploy -n kuadrant-system
```

**2. Confirm the app works** before the test:

```bash
curl -s https://<GATEWAY_HOST>/api/v1/accounts/summary | jq .
```

**3. Scale the control-plane operators to zero:**

```bash
oc scale deploy/kuadrant-operator-controller-manager -n kuadrant-system --replicas=0
oc scale deploy/authorino-operator -n kuadrant-system --replicas=0
oc scale deploy/limitador-operator-controller-manager -n kuadrant-system --replicas=0
oc scale deploy/dns-operator-controller-manager -n kuadrant-system --replicas=0
```

The four operators go `READY 0/0`. Note: `authorino`, `limitador-limitador` and
the console plugin are **runtime** workloads (data plane / UI), not reconcile
operators — they stay up.

**4. Validate the gateway still works:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<GATEWAY_HOST>/api/v1/accounts/summary   # → 200
curl -s -X POST https://<GATEWAY_HOST>/api/v1/transfers \
  -H 'content-type: application/json' \
  -d '{"fromBank":"Example Bank","toBank":"EXTERNAL","amount":500}' | jq .status          # → "SENT_EXTERNAL"
```

In the Red Bank frontend, Refresh and Transfer still work, and the WebSocket
transfer-status card still advances PENDING → PROCESSING → COMPLETED.

**5. Restore the operators:**

```bash
for d in kuadrant-operator-controller-manager authorino-operator \
         limitador-operator-controller-manager dns-operator-controller-manager; do
  oc scale deploy/$d -n kuadrant-system --replicas=1
done
```

## What to look for

| Step | Result |
|---|---|
| Before scale-down | App works normally via the gateway |
| After scaling the 4 operators down | App **keeps working** — no interruption |
| REST (GET/POST) | HTTP 200 as before |
| WebSocket | Stays connected, receiving real-time events |
| After restoring operators | They resume reconciling; no manual action needed |

## How it works

RHCL separates **control plane** and **data plane**:

```
Control Plane (kuadrant-system)              Data Plane (openshift-ingress)
┌──────────────────────────────┐  reconciles ┌──────────────────────────────┐
│  Kuadrant / Authorino /       │ ──────────> │  Istio Ingress Gateway        │
│  Limitador / DNS operators    │ (configures │  (Envoy proxy)                │
└──────────────────────────────┘  Envoy)     └──────────────────────────────┘
   Needed only to apply CHANGES                Serves the real traffic
```

The operators **only reconcile changes** — once an `HTTPRoute`, `AuthPolicy`,
`RateLimitPolicy` or `TLSPolicy` is applied, the config persists in the data
plane **independent** of the operators. So existing routes, rate-limit and auth
enforcement, and issued TLS certs all keep working; only **new changes** wait
until the operators return.

### The control plane is not one thing

Full resilience means separating every component classifiable as CP — each fails
differently:

| Component | Layer | Sole owner of… |
|---|---|---|
| `istiod` | Istio CP | applying HTTPRoute/Gateway/AuthPolicy changes (Envoys hold an xDS cache) |
| `kuadrant`/`authorino`/`limitador`/`dns` operators | Kuadrant CP | propagating new config for their CRs |
| `Authorino` (service) | **Data plane** | per-request allow/deny (ext_authz) |
| `Limitador` (service) | **Data plane** | counters and the 429 decision |
| Gateway Envoy | **Data plane** | serving the traffic itself |
| `kube-apiserver` | OCP CP | anything that creates/changes resources |
| `cert-manager` | OCP CP | issuing/renewing TLS |

### What degrades

- **Immediate (seconds):** changes stop propagating (new policies pend in etcd);
  HPA auto-scaling stops (needs `kube-apiserver`); a pod restart during a
  `kube-apiserver` outage cannot be rescheduled.
- **Time-based:** cert-manager not renewing → TLS eventually expires (but it
  renews ~30 days before `notAfter`, a long tolerance); Authorino JWKS cache TTL
  expires if the OAuth server is also down.
- **Rate limit / Redis (decide explicitly per API):** `redis-cached` over-admits
  across sites when Redis is down; pure `redis` uses `failure_mode` — fail-open
  (admit all, lose protection) vs fail-closed (deny all, preserve the limit).
- **Authorino failure mode:** the Kuadrant default is `failureModeAllow: false`
  (fail-closed) — if Authorino is fully down, auth-protected APIs become
  unavailable. The opposite (fail-open) would serve authenticated APIs **without
  auth** during the outage — usually unacceptable for a bank.

## Production recommendations

- **HA the operators** — most run `replicas: 1` by default; run
  kuadrant/authorino/limitador operators at `replicas: 2` with leader election.
  `istiod` is already `replicas: 2` in OSSM 3 production.
- **HA the data plane** — Limitador and Authorino scale horizontally
  (`replicas: 3+`); replace the lab `emptyDir` Redis with a managed/HA Redis;
  HA the OAuth server.
- **Monitor the operators** — all expose Prometheus metrics;
  `kuadrant_operator_reconcile_errors_total` is a direct "CP healthy" proxy.
- **Policies as GitOps (Argo CD)** — if etcd comes back empty, restore is minutes.
- **Decide the failure mode per API** — critical endpoints (payments, transfers)
  fail-closed; read endpoints (balance) can be fail-open for SLA.
- **Runbooks + CR backups** (Velero) for a fast RTO.
