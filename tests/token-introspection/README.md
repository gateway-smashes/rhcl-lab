---
title: OAuth token introspection
summary: Authenticate requests via OAuth 2.0 token introspection, and return the introspection payload on errors.
category: Security & auth
status: done
---

# OAuth token introspection

Authenticate requests via OAuth 2.0 token introspection, and return the introspection payload on errors.

## Requirement context

### Token introspection via AuthPolicy

**Requirement:** "OAuth 2.0 token introspection to validate access tokens in
real time against the Authorization Server."

**Goal:** demonstrate that the RHCL AuthPolicy can intercept an incoming
request, extract the Bearer token, call an external OAuth introspection
endpoint (RFC 7662), evaluate the response (`active`, `scope`), and either
allow or deny the request — all at the gateway level, without any change to
the backend application.

---

## Scenario

```
                 ┌──────────┐
                 │  Client  │
                 └────┬─────┘
                      │  GET $ITEM_67_PATH
                      │  Authorization: Bearer <token>
                      v
         ┌────────────────────────────┐
         │   RHCL Gateway (Istio)     │
         │   HTTPRoute: item-67-route │
         └────────────┬───────────────┘
                      │
         ┌────────────v───────────────┐
         │  Authorino (AuthPolicy)    │
         │                            │
         │  1. metadata/introspection  │
         │     POST token to OAuth    │  ──────►  OAuth Server
         │     introspection endpoint │  ◄──────  { active, scope, ... }
         │     (cached 60 s)          │
         │                            │
         │  2. authorization/         │
         │     introspection-check    │
         │     Assert active == true  │
         │     Assert scope contains  │
         │     "my-scope"             │
         └────────────┬───────────────┘
                      │  ✅ Allow / ❌ Deny
                      v
         ┌────────────────────────────┐
         │  item-67-mock-api          │
         │  (backend in rhcl-apps)    │
         └────────────────────────────┘
```

---

## Files

| File | Purpose |
|---|---|
| `token-introspection/manifests/req067-bundle.yaml` | All-in-one: ConfigMap, Deployment, Service, HTTPRoute, and AuthPolicy |
| `req067/authpolicy-introspection.yaml` | Standalone AuthPolicy reference (included in the bundle) |

---

## Prerequisites

1. Cluster with RHCL installed (Kuadrant + Istio + Authorino).
2. A `Gateway` named `rhcl-apps-gateway` in `openshift-ingress` (the standard
   lab gateway).
3. An OAuth 2.0 Authorization Server that exposes an RFC 7662 introspection
   endpoint (set via `$ITEM_67_INTROSPECTION_URL`).

```bash
NS=rhcl-apps
export ITEM_67_HOSTNAME=api.example.com                                          # API hostname
export ITEM_67_PATH=/my/api/v1                                                   # API path prefix
export ITEM_67_INTROSPECTION_URL=https://oauth.example.com/oauth/introspect      # RFC 7662 endpoint
export ITEM_67_INTROSPECTION_BASIC=$(echo -n 'client_id:client_secret' | base64) # base64(client_id:client_secret)
```

---

## Deploy the backend

The mock-api acts as the upstream API. It returns a static JSON response so
we can focus on the AuthPolicy behavior.

```bash
envsubst < tests/token-introspection/manifests/req067-bundle.yaml | oc apply -f -
```

Verify:

```bash
oc -n $NS get deploy item-67-mock-api

oc -n $NS get svc item-67-mock-api
# PORT 80 → 8080

oc -n $NS get httproute item-67-route
# HOSTNAMES: $ITEM_67_HOSTNAME
```

Verify the AuthPolicy is accepted:

```bash
oc -n $NS get authpolicy item-67-token-introspection -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# True
```

---

## Token Introspection flow — step by step

The AuthPolicy executes two ordered phases (controlled by `priority`):

### Phase 0 — Token Introspection metadata (`introspection`)

Authorino extracts the `Authorization: Bearer <token>` header, builds a
`POST application/x-www-form-urlencoded` request to the OAuth introspection
endpoint with:

- `token=<access_token>` (stripped of the `Bearer ` prefix)
- `token_type_hint=access_token`
- `Authorization: Basic $ITEM_67_INTROSPECTION_BASIC` (client credentials for
  the resource server)
- `x-request-id` forwarded from the original request

The OAuth server responds with an RFC 7662 JSON payload:

```json
{
  "active": true,
  "scope": "my-scope other-scope",
  "client_id": "my-client",
  "exp": 1716076800
}
```

Authorino caches this response for **60 seconds** (keyed on the
`Authorization` header value) to avoid hitting the OAuth server on every
request.

### Phase 1 — Authorization decision (`introspection-check`)

Authorino evaluates two pattern-matching rules against the cached
introspection response:

1. `auth.metadata.introspection.active == "true"` — the token must be active.
2. `auth.metadata.introspection.scope` must contain `"my-scope"` — the token
   must carry the required scope.

If **both** conditions pass the request is forwarded to the backend. If either
fails the request is denied with **401** and the `Bad Credentials` JSON body.

### Exclusions (`when` predicates)

Requests to health/readiness endpoints and specific path patterns bypass the
policy entirely:

- `/health`
- `/ready`
- `/public/**`
- `/static/**`
- `/my/path/<segment>/like/this`

---

## Test procedure

### 1. Health endpoint — bypasses AuthPolicy

```bash
curl -sk "https://$ITEM_67_HOSTNAME/health"
```

**Expected:** `200 OK` — no authentication required.

### 2. No Bearer token — rejected

```bash
curl -sk "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `401` with:

```json
{ "statusCode": 401, "error": "Unauthorized", "message": "Bad Credentials" }
```

### 3. Valid token — full introspection pass

```bash
TOKEN=$(curl -sk -X POST https://oauth.example.com/oauth/token \
  -d 'grant_type=client_credentials&scope=my-scope' \
  -u 'client_id:client_secret' | jq -r .access_token)

curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `200 OK` with the mock-api response:

```json
{"status":"ok","version":"1.0.0"}
```

### 4. Expired/revoked token — rejected at Phase 1

```bash
curl -sk -H "Authorization: Bearer expired_or_revoked_token" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `401 Unauthorized` — the introspection endpoint returns
`active: false`, which fails the authorization check.

### 5. Token without required scope — rejected at Phase 1

```bash
TOKEN_NO_SCOPE=$(curl -sk -X POST https://oauth.example.com/oauth/token \
  -d 'grant_type=client_credentials&scope=other-scope' \
  -u 'client_id:client_secret' | jq -r .access_token)

curl -sk -H "Authorization: Bearer $TOKEN_NO_SCOPE" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `401 Unauthorized` — the token is active but does not carry
`my-scope`.

---

## Verifying the introspection cache

The AuthPolicy caches introspection responses for 60 seconds. To confirm:

```bash
# First request — Authorino calls the OAuth server
curl -sk -w "\ntime_total: %{time_total}s\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"

# Immediate second request — served from cache (faster)
curl -sk -w "\ntime_total: %{time_total}s\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

The second call should show a noticeably lower `time_total` since Authorino
skips the external HTTP call.

---

## Observing Authorino logs

Authorino emits detailed logs for each evaluation step. To watch the
introspection flow in real time:

```bash
oc -n kuadrant-system logs -l app=authorino -f --tail=50 | grep -E 'introspection|item-67'
```

Look for log entries showing:
- `metadata/introspection` — the POST to the OAuth endpoint and the response.
- `authorization/introspection-check` — the pattern evaluation result.
- `cache hit` / `cache miss` — whether the cached response was used.

---

## Cleanup

```bash
oc delete -n $NS authpolicy item-67-token-introspection
oc delete -n $NS httproute item-67-route
oc delete -n $NS deploy item-67-mock-api
oc delete -n $NS svc item-67-mock-api
oc delete -n $NS cm item-67-mock-api-config
```

## Returning the introspection payload on errors

**Requirement:** "Return introspection-defined payloads during introspection
errors."

**Goal:** demonstrate that when the OAuth introspection endpoint returns an
error (a non-standard response without the `active` field), the AuthPolicy
forwards the raw introspection payload back to the client instead of a generic
"Bad Credentials" message. This gives API consumers actionable error details
from the Authorization Server itself.

---

## Scenario

```
                 ┌──────────┐
                 │  Client  │
                 └────┬─────┘
                      │  GET $ITEM_67_PATH
                      │  Authorization: Bearer <token>
                      v
         ┌────────────────────────────┐
         │   RHCL Gateway (Istio)     │
         │   HTTPRoute: item-67-route │
         └────────────┬───────────────┘
                      │
         ┌────────────v───────────────┐
         │  Authorino (AuthPolicy)    │
         │                            │
         │  metadata/introspection    │
         │  POST token to OAuth       │  ──────►  OAuth Server
         │  introspection endpoint    │  ◄──────  response (see below)
         └────────────┬───────────────┘
                      │
              ┌───────┴────────┐
              │  Three paths:  │
              └───────┬────────┘
                      │
    ┌─────────────────┼──────────────────────┐
    │                 │                      │
    v                 v                      v
 ✅ 200            ❌ 401                  ❌ 401
 active:true       active:false            no "active" field
 + scope ok        or missing scope        (introspection error)
 → forward to      → "Bad Credentials"    → raw introspection
   backend           (standard body)        payload returned
```

---

## Files

| File | Purpose |
|---|---|
| `authpolicy-introspection.yaml` | AuthPolicy with the response CEL logic that returns introspection error payloads |

> This is the same AuthPolicy resource used for token introspection above; this
> section documents the **error-response behavior** specifically.

---

## Prerequisites

Same environment as req067. The AuthPolicy and backend must already be deployed.

```bash
NS=rhcl-apps
export ITEM_67_HOSTNAME=api.example.com
export ITEM_67_PATH=/my/api/v1
export ITEM_67_INTROSPECTION_URL=https://oauth.example.com/oauth/introspect
export ITEM_67_INTROSPECTION_BASIC=$(echo -n 'client_id:client_secret' | base64)
```

If not already deployed:

```bash
envsubst < tests/token-introspection/manifests/req067-bundle.yaml | oc apply -f -
```

---

## How the response logic works

The AuthPolicy `response.unauthorized` block uses a CEL expression with three
branches to decide what body and headers to return when authorization fails:

```yaml
unauthorized:
  body:
    expression: >-
      has(auth.metadata.introspection)
      ? (has(auth.metadata.introspection.active)
        ? '{"statusCode":401,...,"message":"Bad Credentials",...}'
        : auth.metadata.introspection)
      : '{"statusCode":401,...,"message":"Bad Credentials",...}'
```

| Branch | Condition | Body returned | `x-auth-error` header |
|---|---|---|---|
| **A — Normal auth failure** | Introspection returned `active` field (token valid but wrong scope, or `active: false`) | Standard `Bad Credentials` JSON | Standard `Bad Credentials` JSON |
| **B — Introspection error** | Introspection returned a response **without** the `active` field (OAuth server error, malformed response) | Raw introspection payload (`auth.metadata.introspection`) | `{"error":"IntrospectionError","message":"Introspection endpoint returned an error"}` |
| **C — No metadata** | Introspection metadata is absent entirely (e.g. no Bearer token provided) | Standard `Bad Credentials` JSON | Standard `Bad Credentials` JSON |

Branch **B** is the key behavior for this requirement: the client receives the
actual error payload from the OAuth introspection endpoint, enabling
troubleshooting without access to Authorino logs.

---

## Test procedure

### 1. Valid token — 200 (baseline)

```bash
TOKEN=$(curl -sk -X POST https://oauth.example.com/oauth/token \
  -d 'grant_type=client_credentials&scope=my-scope' \
  -u 'client_id:client_secret' | jq -r .access_token)

curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `200 OK` with the mock-api response `{"status":"ok","version":"1.0.0"}`.

### 2. Invalid/revoked token — standard 401

```bash
curl -sk -H "Authorization: Bearer expired_or_revoked_token" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `401` with standard body:

```json
{"statusCode":401,"error":"Unauthorized","message":"Bad Credentials","attributes":{"error":"Bad Credentials"}}
```

The introspection endpoint returned `active: false`, so Branch **A** fires.

### 3. Introspection endpoint error — raw payload returned

Simulate an introspection error by pointing the AuthPolicy at a broken or
unavailable endpoint, or by sending a token that causes the OAuth server to
return an error response (e.g. an HTML error page or a JSON error object
without the `active` field):

```bash
curl -sk -D - -H "Authorization: Bearer trigger_introspection_error" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH"
```

**Expected:** `401` with:

- **Body:** the raw payload returned by the introspection endpoint (Branch **B**).
- **`x-auth-error` header:**

```json
{"error":"IntrospectionError","message":"Introspection endpoint returned an error"}
```

Inspect the response headers to confirm the `x-auth-error` header carries the
`IntrospectionError` indicator:

```bash
curl -sk -D - -H "Authorization: Bearer trigger_introspection_error" \
  "https://$ITEM_67_HOSTNAME$ITEM_67_PATH" 2>&1 | grep -i x-auth-error
```

---

## Observing Authorino logs

```bash
oc -n kuadrant-system logs -l app=authorino -f --tail=50 | grep -E 'introspection|item-67'
```

Look for:
- `metadata/introspection` — the POST to the OAuth endpoint and the response
  (including error payloads).
- `authorization/introspection-valid` — whether the `active` field was present.
- `response/unauthorized` — the body and headers returned to the client.

---

## Cleanup

This requirement shares resources with req067. See [req067 cleanup](token-introspection/README.md#cleanup).
