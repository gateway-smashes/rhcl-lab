---
title: OIDC / JWT authentication
summary: Validate OIDC / JWT bearer tokens at the gateway (Keycloak + Kuadrant).
category: Security & auth
status: done
---

# OIDC / JWT authentication at the gateway

A **real Keycloak (RHBK)** issues JWTs and the **gateway (Authorino / AuthPolicy)**
validates and authorizes them — the application validates nothing. It stands up a
Red Hat build of Keycloak via operator, creates a realm/client/users, and
configures the gateway to validate the JWT (signature, issuer, audience,
expiry) and authorize by **realm role / audience / scope**. `banking-api` has **no
OIDC/JWT dependency** — it only echoes the claims the gateway already verified and
forwarded as `x-jwt-*` headers.

> The deliverable is the **JWT bearer** (the correct pattern for an API). The
> `OIDCPolicy` (gateway-side browser login) was also evaluated — see
> [Scenario E](#scenario-e--oidcpolicy-gateway-login--blocked-by-upstream-bug).

## Architecture

```
   client ── Bearer JWT ──► Gateway / Envoy (Kuadrant)
      ▲                     AuthPolicy → Authorino
      │ 1) token            jwt.issuerUrl → validates signature, iss, aud, exp
   RHBK / Keycloak          authorization (role/scope)
   (realm rhcl,             response.headers x-jwt-*
   RS256 JWT)                        │ forwards verified claims
                              banking-api (no OIDC) — /api/whoami just echoes them
```

- **RHBK (Keycloak)** via `rhbk-operator`; `Keycloak` + `KeycloakRealmImport` CRs,
  PostgreSQL backend, exposed via a passthrough Route with a **Let's Encrypt** cert
  (so Authorino trusts the issuer over TLS with no extra CA).
- **AuthPolicy** (`kuadrant.io/v1`) — `jwt` authentication with `issuerUrl`
  pointing at the realm; `authorization.patternMatching` requiring a role;
  `response.success.headers` forwarding verified claims to the backend.

## Prerequisites

```bash
oc whoami
cd automation
export RHCL_ZONE_ROOT_DOMAIN=example.com          # your zone
ansible-playbook playbooks/rhbk-install.yml
ansible-playbook playbooks/rhbk-test.yml           # confirms issuer + token

export HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
export KC=https://keycloak.example.com; export REALM=rhcl
export CID=banking-api; export CSECRET=banking-api-secret

# helper: fetch a token (password grant)
tok() { curl -s "$KC/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=$CID -d client_secret=$CSECRET \
  -d username="$1" -d password="$2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'; }
ALICE=$(tok alice alice123); BOB=$(tok bob bob123)
```

The token is an RS256 JWT with `iss=$KC/realms/rhcl`, `aud=banking-api`,
`realm_access.roles`, `preferred_username`, `email`, `scope`.

**Realm identities:** `alice`/`alice123` (`banking-customer`) and `bob`/`bob123`
(`banking-customer`, `banking-admin`). Client `banking-api` (confidential, Direct
Access Grants enabled for the demo). Keycloak admin console (realm `master`):
`admin` / `redhat`.

## Run it

Only **one AuthPolicy is Enforced per target**, so the scenarios are variations of
the `authorization` rule (via `oc patch`) on the installed policy, all on
`/api/whoami`.

### Scenario A — authN (token validation at the gateway)

```bash
curl -sk -o /dev/null -w "no token:  %{http_code}\n" "https://$HOST/api/whoami"                                        # 401
curl -sk -o /dev/null -w "garbage:   %{http_code}\n" -H "Authorization: Bearer not.a.jwt" "https://$HOST/api/whoami"   # 401
curl -sk -H "Authorization: Bearer $ALICE" "https://$HOST/api/whoami" | jq '.jwt'                                      # 200 + claims
```

The `200` body carries an `x-jwt-*` object (`x-jwt-aud`, `x-jwt-email`,
`x-jwt-iss`, `x-jwt-preferred-username`, `x-jwt-roles`, `x-jwt-scope`, `x-jwt-sub`)
**injected by the gateway** from the verified claims — the backend does not decode
the token. Token lifespan is 300s; wait for expiry and it becomes `401` (the `exp`
claim), with no app code.

### Scenario B — authZ by realm role (403 vs 200)

The installed default requires `banking-customer` (both users pass). To see a
`403`, require `banking-admin`:

```bash
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"replace","path":"/spec/rules/authorization/jwt-require-role/patternMatching/patterns/0/value","value":"banking-admin"}]'
sleep 6
curl -sk -o /dev/null -w "alice: %{http_code}\n" -H "Authorization: Bearer $ALICE" "https://$HOST/api/whoami"   # 403 (no banking-admin)
curl -sk -o /dev/null -w "bob:   %{http_code}\n" -H "Authorization: Bearer $BOB"   "https://$HOST/api/whoami"   # 200
# revert to banking-customer with the same patch
```

### Scenario C — authZ by audience

Require `aud == banking-api` (any token without that audience is denied):

```bash
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"add","path":"/spec/rules/authorization/jwt-require-aud","value":{
        "when":[{"predicate":"request.path.startsWith(\"/api/whoami\")"}],
        "patternMatching":{"patterns":[{"selector":"auth.identity.aud","operator":"eq","value":"banking-api"}]}}}]'
```

### Scenario D — authZ by scope (optional)

Require an optional client scope (e.g. `accounts`) in the `scope` claim. Request
the token with `-d scope=accounts` and require
`selector: auth.identity.scope, operator: incl, value: accounts` — without the
scope → `403`.

### Regression (nothing broke)

```bash
curl -sk -o /dev/null -w "echo anon:  %{http_code}\n" "https://$HOST/api/echo"                                # 200
KEY=$(oc -n rhcl-apps get secret banking-api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)
curl -sk -o /dev/null -w "apikey v1:  %{http_code}\n" -H "api-key: $KEY" "https://$HOST/api/v1/accounts"      # routes (not 401)
```

## Scenario E — OIDCPolicy (gateway login) — blocked by upstream bug

Beyond the JWT bearer, Kuadrant has an **`OIDCPolicy`**
(`extensions.kuadrant.io/v1alpha1`, **Tech Preview**) implementing the OIDC
Authorization Code Flow **at the gateway** (no session → `302` to Keycloak → login
→ callback → session cookie) — the pattern for protecting **browser apps** (edge
SSO). Evaluated protecting the `mobile-bank` SPA:

- ✅ **Works up to the code exchange** — `GET /` → `302` to Keycloak `authorize`;
  after login the gateway exchanged the code for a real session token. The
  OIDCPolicy self-creates the `/auth/callback` route + AuthPolicies. It requires a
  **public** Keycloak client (the provider CRD has no `clientSecretRef`).
- ❌ **Blocker (bug):** the OIDCPolicy derives the cookie **domain** and the
  post-login redirect from the **gateway listener hostname** instead of the
  concrete HTTPRoute hostname. With a **wildcard listener** (`*.example.com`) it
  emits `set-cookie: jwt=…; Domain=*.example.com` (invalid per RFC 6265 — browsers
  reject it → login loop) and `location: http://*.example.com` (broken redirect).
  Pinning a specific-hostname listener with `sectionName` did **not** fix it.

Tracked upstream as
[kuadrant-operator#1504](https://github.com/Kuadrant/kuadrant-operator/issues/1504).
**Conclusion:** until it is fixed, the OIDCPolicy needs a gateway with a
**specific-hostname listener**; the wildcard `*.example.com` is required here for
banking-api. For this item, the deliverable is the **JWT bearer (AuthPolicy)** —
immune to all of this, since it derives no redirect or cookie and only validates
the Bearer the client brings.

## CRs applied

| Resource | File |
|---------|---------|
| RHBK operator (Subscription/OperatorGroup) | [`manifests/00-keycloak-operator.yaml`](manifests/00-keycloak-operator.yaml) |
| PostgreSQL (Keycloak DB) | [`manifests/01-postgres.yaml`](manifests/01-postgres.yaml) |
| Let's Encrypt Certificate | [`manifests/02-keycloak-cert.yaml`](manifests/02-keycloak-cert.yaml) |
| DNSRecord override (host → router) | [`manifests/03-keycloak-dnsrecord.yaml`](manifests/03-keycloak-dnsrecord.yaml) |
| Keycloak CR | [`manifests/04-keycloak.yaml`](manifests/04-keycloak.yaml) |
| Realm import (client/roles/users) | [`manifests/05-realm-import.yaml`](manifests/05-realm-import.yaml) |
| **AuthPolicy JWT (gateway)** | [`manifests/06-authpolicy-jwt.yaml`](manifests/06-authpolicy-jwt.yaml) |

> **Supported path:** all of the above is encoded in the `automation/roles/rhbk`
> role + `rhbk-install.yml` playbook (also inside `install-all.yml`). The JWT
> AuthPolicy is generated by the `apps` role when `APPS_CONNECTIVITY_JWT_ENABLED=true`.

## What to look for — verifying the Kuadrant components

An `AuthPolicy` is not executed directly — Kuadrant translates it into an Authorino
`AuthConfig`, and the gateway Envoy calls Authorino via `ext_authz` (gRPC),
wired by a `WasmPlugin` + `EnvoyFilter`.

```
AuthPolicy (rhcl-apps) → [kuadrant-operator] → AuthConfig (kuadrant-system)
                                                    │ Authorino fetches JWKS, evaluates
                                                    ▼
                        Envoy (Gateway) ── ext_authz gRPC ──► Authorino
```

**1. Is the AuthPolicy accepted and enforced?**

```bash
oc -n rhcl-apps get authpolicy banking-api-connectivity-apikey \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
# Accepted=True and Enforced=True. Enforced=False → another AuthPolicy targets the
# same target (only one is Enforced per target; the other is "Overridden").
```

**2. The generated AuthConfig** — one per protected route, named/hosted by **hash**
in `kuadrant-system`. Find yours by content:

```bash
oc -n kuadrant-system get authconfig          # READY must be true
```

> **`READY=true` is the key OIDC/JWT signal**: Authorino fetched the issuer's
> `.well-known/openid-configuration` + JWKS. If the issuer is unreachable, has an
> untrusted cert, or a mismatched `iss`, the AuthConfig is `ready:false` and a
> **valid token becomes 401**. Check here first.

**3. Authorino** — the decision engine (per-request logs):

```bash
oc -n kuadrant-system logs deploy/authorino -f
# raise verbosity: oc -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"logLevel":"debug"}}'
# look for: JWKS fetch, "authenticated" / "authorization rejected"
```

**4. Data plane** — the gateway Envoy calling Authorino:

```bash
oc -n openshift-ingress get wasmplugin,envoyfilter    # kuadrant-auth-* = ext_authz → Authorino
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default
```

### Symptom → where to look

| Symptom | Component |
|---------|--------------------------|
| Valid token → **401** | AuthConfig `READY` (JWKS fetch); `authorino` logs; token `iss` == `issuerUrl` |
| Valid token → **403** | authZ rule in the AuthConfig; `authorino` debug "authorization rejected"; is the claim in the token? |
| CORS preflight fails | the `cors-preflight` (OPTIONS) rule + authZ excluding OPTIONS |
| Policy not **Enforced** | AuthPolicy conflict on the same target; `kuadrant-operator` logs |
| Claims **don't reach** the backend | `response.success.headers` in the AuthConfig; a null selector = missing claim (header omitted) |

## Cleanup

```bash
oc delete namespace keycloak
oc -n openshift-ingress delete dnsrecord.kuadrant.io keycloak-rhcl --ignore-not-found
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"remove","path":"/spec/rules/authentication/jwt-keycloak"}]'
# or via automation:
cd automation && ansible-playbook playbooks/rhbk-remove.yml
```
