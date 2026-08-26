# REQ 72 — IP-based ACL (PoC)

Demo package for item 72 of the RHCL PoC. See
[`../req072.md`](../req072.md) for the full context and architecture map.

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
export RHCL_ZONE_ROOT_DOMAIN=azuredns.rhcl.com.br  # adjust
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
curl -k -i -H "X-Forwarded-For: 203.0.113.10" https://ipfilter.azuredns.rhcl.com.br/

# Any other IP -> 200
curl -k -i -H "X-Forwarded-For: 8.8.8.8" https://ipfilter.azuredns.rhcl.com.br/
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
[`../req072.md`](../req072.md#production-hardening-for-x-forwarded-for).

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
