---
title: IP allowlist (ACL)
summary: Restrict access by client IP with an allowlist / denylist at the gateway.
category: Security & auth
status: done
---

# REQ 72 — IP-based ACL (PoC)

Demo package for item 72 of the Example Bank PoC. See
[`../ip-allowlist-acl/README.md`](../ip-allowlist-acl/README.md) for the full context and architecture map.

This package documents a **single, validated engine**: source-IP **blocking**
(deny-list) via an OPA/Rego `AuthPolicy` evaluated by Authorino over
`x-forwarded-for`. Two variants are shipped — block a single IP, and block a
CIDR range.

> Other approaches (OPA allow-list, CEL `AuthPolicy`, native Envoy RBAC via
> `EnvoyFilter`) can produce the same outcome but are intentionally not included
> here — only the proven deny-list path is kept.

## Files

| File | Engine | Mode | What it shows |
|------|--------|------|---------------|
| [`manifests/00-httproute-ipfilter.yaml`](manifests/00-httproute-ipfilter.yaml) | — | — | HTTPRoute `ipfilter` → service `ipfilter-php:8080`, host `ipfilter.${RHCL_ZONE_ROOT_DOMAIN}`. Idempotent with the playbook route. |
| [`manifests/01-block-ip-opa.yaml`](manifests/01-block-ip-opa.yaml) | OPA/Rego (AuthPolicy → Authorino) | Deny-list | Blocks a single literal source IP (`contains` on XFF); everything else passes. |
| [`manifests/02-block-range-opa.yaml`](manifests/02-block-range-opa.yaml) | OPA/Rego (AuthPolicy → Authorino) | Deny-list | Blocks a CIDR range (`net.cidr_contains_matches` on XFF); everything else passes. |
| [`index.html`](index.html) | — | — | Standalone cross-origin console (optional — see note under **Validate**). |

## Target service

The demo points at the **`ipfilter-php`** probe
([`../../apps/backend/ipfilter-php`](../../apps/backend/ipfilter-php)), exposed
by the HTTPRoute `ipfilter` on host `ipfilter.${RHCL_ZONE_ROOT_DOMAIN}`.
Endpoints: `GET /` (HTML console that forges XFF), `GET /api/ip` (JSON snapshot
of the IP seen) and `GET /healthz`. The route is fully anonymous — the only
variable in the demo is the source IP.

## Prerequisites

```bash
oc whoami

# ipfilter-php + route installed (via apps-install with APPS_IPFILTER_ENABLED=true)
oc get deploy ipfilter-php -n rhcl-apps
oc get httproute ipfilter -n rhcl-apps
oc get gateway rhcl-apps-gateway -n openshift-ingress
oc get authorino authorino -n kuadrant-system

# Standalone (no playbook): apply this package's route
export RHCL_ZONE_ROOT_DOMAIN=example.com  # adjust
envsubst < manifests/00-httproute-ipfilter.yaml | oc apply -f -
```

## Apply

The playbook (`apps-install`) creates a default `AuthPolicy` named
`ipfilter-ip-acl` on the `ipfilter` route. These manifests use a **different**
name (`ipfilter-block-xff`), so they are a separate CR. Only one `AuthPolicy` is
Enforced per target — remove the playbook policy first to avoid a conflict:

```bash
oc -n rhcl-apps delete authpolicy ipfilter-ip-acl --ignore-not-found

# Block a single IP:
oc apply -f manifests/01-block-ip-opa.yaml
# ...or block a CIDR range (same name — replaces the one above):
# oc apply -f manifests/02-block-range-opa.yaml

oc -n rhcl-apps wait authpolicy/ipfilter-block-xff \
  --for=condition=Enforced=True --timeout=120s
```

## Validate

`curl` is the proven path. These are the exact commands run in the lab:

```bash
# Blocked IP -> 403
curl -k -i -H "X-Forwarded-For: 203.0.113.10" https://ipfilter.example.com/

# Any other IP -> 200
curl -k -i -H "X-Forwarded-For: 8.8.8.8" https://ipfilter.example.com/
```

For variant 02 (CIDR range), `203.0.113.10` is inside `203.0.113.0/24` → `403`,
and any IP outside the range → `200`.

### Interactive console

Open `https://ipfilter.${RHCL_ZONE_ROOT_DOMAIN}/` in a browser. The
`ipfilter-php` probe serves a console from `GET /` that forges `X-Forwarded-For`
and calls `GET /api/ip` **same-origin** — no CORS is involved, so it works with
these minimal manifests as-is.

> The standalone [`index.html`](index.html) is the **cross-origin** console.
> Reading `200`/`403` from another origin would require CORS response headers,
> which these deny-list manifests intentionally omit. Prefer the app's own
> same-origin page above, or `curl`.

### Note on `X-Forwarded-For`

The demo trusts the client-supplied `X-Forwarded-For` so we can forge source
IPs. In production this is unsafe — harden with `xff_num_trusted_hops`, PROXY
protocol, or `internal_address_config` + `use_remote_address`. See
[`../ip-allowlist-acl/README.md`](../ip-allowlist-acl/README.md#production-hardening-for-x-forwarded-for).

## Inspect the decision

```bash
oc -n rhcl-apps get authpolicy ipfilter-block-xff \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'

oc -n kuadrant-system logs deploy/authorino -f | grep -E "rhcl-apps|block-xff"

oc -n rhcl-apps get authconfig -l app.kubernetes.io/part-of=rhcl-ipfilter-poc -o yaml
```

## Cleanup

```bash
oc -n rhcl-apps delete authpolicy ipfilter-block-xff --ignore-not-found
```

## Troubleshooting

| Symptom | Diagnosis |
|---------|-----------|
| Every request returns `200`, nothing blocked | Policy not Enforced yet, or the playbook `ipfilter-ip-acl` is still winning the target. Check `status.conditions` for `Enforced=True`; delete `ipfilter-ip-acl` if present. |
| Every request returns `403` | XFF not reaching Authorino, or block list too broad. Check the generated AuthConfig and the Authorino logs. |
| `503` instead of `403` | Authorino down — Envoy fails closed. `oc get pods -n kuadrant-system -l app=authorino` should be Ready. |
| `unknown field "spec.response"` on apply | In `kuadrant.io/v1` the response block lives under `spec.rules.response`, and each success header needs `plain: { value: … }`. These manifests omit `response` entirely, so it does not arise. |
| Browser console (cross-origin `index.html`) blocked by CORS | Expected — these manifests carry no CORS headers. Use the app's same-origin page at `https://ipfilter.<domain>/`, or `curl`. |

## Requirement context

## Requirement demonstrated

| Item | Requirement |
|------|-------------|
| **72** | Ability to apply **source-IP based ACLs (deny-list)** to a request, at the Gateway/API level. |

This package demonstrates **source-IP blocking** with a single, validated engine:
an **OPA/Rego `AuthPolicy`** evaluated by Authorino over the request's
`x-forwarded-for` header. Two variants are shipped, both proven in the lab:

| Variant | What it blocks | Manifest |
|---------|----------------|----------|
| **Single IP** | one literal source IP (`contains`) | [`ip-allowlist-acl/manifests/01-block-ip-opa.yaml`](ip-allowlist-acl/manifests/01-block-ip-opa.yaml) |
| **CIDR range** | a whole CIDR block (`net.cidr_contains_matches`) | [`ip-allowlist-acl/manifests/02-block-range-opa.yaml`](ip-allowlist-acl/manifests/02-block-range-opa.yaml) |

Both are **deny-list**: the listed IP/range gets `403`; everything else passes
with `200`.

> **Other approaches exist** — the same outcome can also be built as an OPA
> allow-list, as a CEL `AuthPolicy`, or natively in Envoy via an `EnvoyFilter`
> RBAC filter (no ext_authz hop). They are intentionally **not** documented here:
> this package keeps only the OPA deny-list path that was validated end to end.
> See the Kuadrant [CEL introduction](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/cel/introduction/)
> and the [Envoy RBAC filter](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/rbac/v3/rbac.proto)
> docs if you want to explore them.

---

## Target service: the `ipfilter-php` probe

The demo points at a dedicated app — the PHP probe **`ipfilter-php`**
([`apps/backend/ipfilter-php`](../apps/backend/ipfilter-php)) — exposed by its
own **HTTPRoute** (`ipfilter`) on the host `ipfilter.${RHCL_ZONE_ROOT_DOMAIN}`.
This isolates the IP-ACL from the banking-api: the route is fully anonymous (no
APIKey/JWT in the path), so the **only variable** in the demo is the source IP.

The app exposes:

| Endpoint | Use |
|----------|-----|
| `GET /` | HTML console that forges `x-forwarded-for` and shows the IP the app sees |
| `GET /api/ip` | JSON snapshot: `REMOTE_ADDR`, the `x-forwarded-for` chain, `x-real-ip`, etc. |
| `GET /healthz` | Health check |

The `Deployment`/`Service` `ipfilter-php` and the `ipfilter` HTTPRoute are
provisioned by the `apps-install` playbook (`APPS_IPFILTER_ENABLED=true`). The
test bundle also ships a self-contained copy of the route in
[`ip-allowlist-acl/manifests/00-httproute-ipfilter.yaml`](ip-allowlist-acl/manifests/00-httproute-ipfilter.yaml)
for standalone runs.

> **TLS at the edge, gateway on HTTP**: the gateway publishes `ipfilter` on the
> HTTP:80 listener only. TLS terminates **before** the gateway (OCP Route with
> `edge`, external ingress, or similar) and the internal hop to Envoy is HTTP.
> Clients always use `https://` (what they actually see).

---

## Architecture overview

```
                 ┌──────────────┐
   client ──TLS──►  HAProxy /   │
   (IP X)          │  ingress   │  adds X-Forwarded-For: X, …
                   └──────┬─────┘
                          │
                  ┌───────▼────────┐
                  │ Gateway/Envoy  │  calls Authorino via ext_authz (gRPC)
                  │  (Kuadrant)    │
                  └───────┬────────┘
                          │
                ┌─────────▼──────────┐
                │     Authorino       │  evaluates the OPA/Rego of the
                │   (AuthPolicy)      │  AuthPolicy over:
                │ rules.authorization │   • request.headers['x-forwarded-for']
                └─────────┬──────────┘
                          │ allow / deny
                  ┌───────▼────────┐
                  │  ipfilter-php  │  GET /api/ip → shows the IP it sees
                  └────────────────┘
```

**Components**

- **Envoy** (the `Gateway` node): for each request, makes a gRPC call to
  **Authorino** via the `ext_authz` filter, carrying headers, `source.address`,
  path, method, etc.
- **Authorino** (`authorino.kuadrant.io`): external authz service. It evaluates
  the `rules.authorization` of every `AuthPolicy` bound to the target. Here that
  rule is inline OPA/Rego.
- **AuthPolicy** (`kuadrant.io/v1`): the high-level CR that Kuadrant translates
  into an `AuthConfig` for Authorino and binds to Envoy.
- **ipfilter-php**: probe that echoes the source IP the app sees — makes it easy
  to show the gateway blocked (`403`) or allowed (`200`) the request before it
  ever reached the app.

> **About the source IP**: inside OpenShift the gateway usually sits behind the
> HAProxy ingress router. For Envoy, `source.address` is the router's IP
> (cluster-internal), not the real client's. The real client IP arrives as the
> **first entry of `X-Forwarded-For`**. This demo reads XFF as the source of
> truth. In production, restrict `X-Forwarded-For` to trusted hops (PROXY
> protocol or `xff_num_trusted_hops`).

---

## How the policy works

The `AuthPolicy` carries a single `rules.authorization` rule with inline Rego.
Authorino runs it on every request. The Rego sets `allow` to `true` only for
non-blocked traffic; when the request matches the block list, `allow` stays
**undefined**, which Authorino treats as a deny (`403`). No `default allow`
declaration is needed.

### Variant 1 — block a single IP

[`ip-allowlist-acl/manifests/01-block-ip-opa.yaml`](ip-allowlist-acl/manifests/01-block-ip-opa.yaml):

```rego
xff := object.get(input.context.request.http.headers, "x-forwarded-for", "")

allow {
  not contains(xff, "203.0.113.10")
}
```

| Source IP (XFF) | Blocked literal `203.0.113.10` | Response |
|-----------------|--------------------------------|----------|
| `203.0.113.10`  | match | `403` |
| `8.8.8.8`       | no match | `200` |

### Variant 2 — block a CIDR range

[`ip-allowlist-acl/manifests/02-block-range-opa.yaml`](ip-allowlist-acl/manifests/02-block-range-opa.yaml):

```rego
blocked_ranges := [
  "203.0.113.0/24",
]

xff := object.get(input.context.request.http.headers, "x-forwarded-for", "")

xff_ips := [trim(ip, " ") | ip := split(xff, ",")[_]]

blocked {
  ip := xff_ips[_]
  count(net.cidr_contains_matches(blocked_ranges, [ip])) > 0
}

allow {
  not blocked
}
```

| Source IP (XFF) | Blocked range `203.0.113.0/24` | Response |
|-----------------|--------------------------------|----------|
| `203.0.113.10`  | in range | `403` |
| `8.8.8.8`       | out of range | `200` |

Add more CIDRs to `blocked_ranges` to drop additional feeds. Both manifests use
`metadata.name: ipfilter-block-xff`, so applying one **replaces** the other —
only one `AuthPolicy` is Enforced per target.

---

## Apply

```bash
export ROOT=tests/ip-allowlist-acl/manifests
export RHCL_ZONE_ROOT_DOMAIN=example.com  # adjust for the lab

# Route + ipfilter-php service. Already present if apps-install ran with
# APPS_IPFILTER_ENABLED=true; apply it here to run standalone.
envsubst < $ROOT/00-httproute-ipfilter.yaml | oc apply -f -

# The playbook creates a default AuthPolicy `ipfilter-ip-acl` on the same route.
# Only one AuthPolicy is Enforced per target, so remove it first to avoid a
# two-policies-one-target conflict.
oc -n rhcl-apps delete authpolicy ipfilter-ip-acl --ignore-not-found

# Block a single IP:
oc apply -f $ROOT/01-block-ip-opa.yaml
# ...or block a CIDR range (same name — replaces the one above):
# oc apply -f $ROOT/02-block-range-opa.yaml

oc -n rhcl-apps wait authpolicy/ipfilter-block-xff \
  --for=condition=Enforced=True --timeout=120s
```

## Validate

`curl` is the proven validation path. The exact commands run in the lab:

```bash
# Blocked IP -> 403
curl -k -i -H "X-Forwarded-For: 203.0.113.10" https://ipfilter.example.com/

# Any other IP -> 200
curl -k -i -H "X-Forwarded-For: 8.8.8.8" https://ipfilter.example.com/
```

For an interactive view, open `https://ipfilter.${RHCL_ZONE_ROOT_DOMAIN}/` in a
browser. The `ipfilter-php` probe serves a console from `GET /` that forges
`X-Forwarded-For` and calls `GET /api/ip` **same-origin** — no CORS setup is
needed, which is why these manifests stay minimal.

> The standalone console in [`ip-allowlist-acl/index.html`](ip-allowlist-acl/index.html) is the
> **cross-origin** variant; reading `403`/`200` from another origin would need
> CORS response headers, which these deny-list manifests deliberately omit. Use
> the app's own same-origin page, or `curl`.

## Inspect the decision

```bash
# Policy status
oc -n rhcl-apps get authpolicy ipfilter-block-xff \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'

# Authorino logs
oc -n kuadrant-system logs deploy/authorino -f | grep -E "rhcl-apps|block-xff"

# AuthConfig generated by Kuadrant
oc -n rhcl-apps get authconfig -l app.kubernetes.io/part-of=rhcl-ipfilter-poc -o yaml
```

## Cleanup

```bash
oc -n rhcl-apps delete authpolicy ipfilter-block-xff --ignore-not-found
# The ipfilter route is playbook-managed — only remove if applied standalone:
# oc -n rhcl-apps delete httproute ipfilter --ignore-not-found
```

## Relationship with the playbook policy

`apps-install` (`APPS_IPFILTER_ENABLED=true`) creates an `AuthPolicy` named
`ipfilter-ip-acl` on the `ipfilter` route (OPA deny-list by default). The test
manifests here use a **different** name (`ipfilter-block-xff`), so they are a
**separate CR**, not an in-place override. Because only one `AuthPolicy` is
Enforced per target:

- Delete the playbook policy before applying these (shown in **Apply** above),
  or disable it with `APPS_IPFILTER_AUTH_POLICY_ENABLED=false`.
- Re-running the playbook recreates `ipfilter-ip-acl` and may win the conflict —
  remove it again, or keep these out of clusters where the playbook policy is
  the source of truth.

## Production hardening for `X-Forwarded-For`

The demo trusts the `X-Forwarded-For` sent by the client, which is fine for the
lab (we want to forge XFF to simulate source IPs) but unsafe in production —
any caller can spoof the header. For production, consider:

- `xff_num_trusted_hops` on the gateway Envoy (drop the first N trusted hops and
  use the rest).
- PROXY protocol between the router and the gateway (carries the source IP
  outside the HTTP payload — immune to client spoofing).
- `internal_address_config` marking the router range as `internal`, combined
  with `use_remote_address: true` on Envoy.

## Troubleshooting

| Symptom | Diagnosis |
|---------|-----------|
| Every request returns `200`, nothing is blocked | Policy not Enforced yet, or the playbook `ipfilter-ip-acl` is winning the target. Check `oc -n rhcl-apps get authpolicy ipfilter-block-xff -o yaml` → `status.conditions` for `Enforced=True`. Delete `ipfilter-ip-acl` if present. |
| Every request returns `403` | XFF is not reaching Authorino, or the block list is too broad. Check the generated AuthConfig and the Authorino logs. |
| `503` instead of `403` | Authorino unavailable — Envoy fails closed. `oc get pods -n kuadrant-system -l app=authorino` should be Ready. |
| `unknown field "spec.response"` on apply | Old mistake: in `kuadrant.io/v1`, response shaping lives under `spec.rules.response`, and each success header needs a `plain: { value: … }` wrapper. These manifests omit `response` entirely, so it does not arise. |
