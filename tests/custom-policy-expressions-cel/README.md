---
title: Custom policy expressions (CEL)
summary: Author custom authorization / routing logic with CEL predicates in Kuadrant policies.
category: Security & auth
status: done
---

# Custom policy expressions (CEL)

Demonstrates **CEL (Common Expression Language)** as the custom-expression engine
in Kuadrant / RHCL, for contextual access control and rate limiting.

## What CEL is in Kuadrant

Kuadrant uses CEL as the native expression language in its policies. CEL writes
complex conditions over request attributes evaluated in real time:

- **`when.predicate`** — expressions that decide WHEN a rule applies (AuthPolicy,
  RateLimitPolicy).
- **`counters.expression`** — expressions that define dynamic counter keys
  (RateLimitPolicy).

Reference: https://docs.kuadrant.io/dev/kuadrant-operator/doc/cel/introduction/

## What it demonstrates

CEL features exercised: logical operators (`&&`, `||`, `!`), string functions
(`startsWith()`, `contains()`), direct header comparison
(`request.headers['x'] == 'value'`), grouped/negated predicates, and header
extraction as a counter key.

The authorization rules are integrated directly into the main AuthPolicy
`banking-api-connectivity-apikey` (created by Ansible), doing an in-place update
that keeps authentication intact and adds CEL **authorization** rules:

| Rule | CEL `when` | Effect | Impact on other tests |
|-------|---------------------|--------|---------------------------|
| `cel-transfer-idempotency` | `request.method == 'POST' && request.path.startsWith('/api/v1/transfers')` **and** `request.headers['x-cel-strict'] == 'true'` | Requires `x-idempotency-key` | **None** — only fires when `x-cel-strict: true` is present |
| `cel-bot-blocking` | `request.headers['user-agent'].contains('bot')` **and** `request.method != 'OPTIONS'` **and** `!request.path.startsWith('/api/echo')` | Blocks with 403 | **None** — no existing test uses 'bot' as user-agent |

```
Authorino pipeline:
  Request → Authentication (API key / anonymous)   ← unchanged
          → Authorization  (CEL expressions)       ← new
          → Response       (userid, plan-id)       ← unchanged
```

## Files

| File | What it demonstrates |
|---------|-----------------|
| [`manifests/01-cel-custom-expressions.yaml`](manifests/01-cel-custom-expressions.yaml) | Integrated `AuthPolicy`: keeps API-key auth + adds CEL authorization rules |
| [`manifests/02-cel-ratelimit-expressions.yaml`](manifests/02-cel-ratelimit-expressions.yaml) | `RateLimitPolicy` with CEL in `when` and `counters` for contextual rate limiting |
| [`index.html`](index.html) | Standalone interactive console to test the expressions |

## Prerequisites

```bash
oc whoami
oc get httproute banking-api-connectivity -n rhcl-apps
oc get authpolicy banking-api-connectivity-apikey -n rhcl-apps
oc get authorino authorino -n kuadrant-system
oc get limitador limitador-limitador -n kuadrant-system
```

## Run it

### Scenario A — AuthPolicy with CEL (access control)

The AuthPolicy already ships the CEL rules via Ansible — just confirm it is
Enforced (`oc get authpolicy banking-api-connectivity-apikey -n rhcl-apps
-o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}'` → `True`). No
manual apply needed; `manifests/01-cel-custom-expressions.yaml` is the reference.

```bash
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
KEY=<YOUR_API_KEY>

# 1. Normal GET with API key — preserved
curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" "https://$HOST/api/v1/accounts/summary"                       # 200

# 2. POST transfer without x-cel-strict — preserved (rule not activated)
curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/api/v1/transfers" -H "api-key: $KEY" \
  -H "content-type: application/json" -d '{"fromBank":"EXAMPLE","toBank":"EXTERNAL","amount":100}'                          # 200

# 3. bot-blocking — user-agent contains 'bot' → denied
curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" -H "user-agent: my-bot-scraper/1.0" \
  "https://$HOST/api/v1/accounts/summary"                                                                                   # 403

# 4. Normal user-agent → allowed
curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" -H "user-agent: Mozilla/5.0 BankApp/2.1" \
  "https://$HOST/api/v1/accounts/summary"                                                                                   # 200

# 5. idempotency (strict) WITHOUT x-idempotency-key → denied
curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/api/v1/transfers" -H "api-key: $KEY" \
  -H "x-cel-strict: true" -H "content-type: application/json" -d '{"fromBank":"EXAMPLE","toBank":"EXTERNAL","amount":100}'  # 403

# 6. idempotency (strict) WITH x-idempotency-key → allowed
curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/api/v1/transfers" -H "api-key: $KEY" \
  -H "x-cel-strict: true" -H "x-idempotency-key: txn-$(date +%s)-001" \
  -H "content-type: application/json" -d '{"fromBank":"EXAMPLE","toBank":"EXTERNAL","amount":100}'                          # 200

# 7. Public paths stay free (excluded from bot-blocking by the predicate)
curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/api/echo" \
  -H "content-type: application/json" -H "user-agent: bot-test/1.0" -d '{"test": true}'                                     # 200
```

### Scenario B — RateLimitPolicy with CEL (contextual rate limiting)

```bash
oc apply -f manifests/02-cel-ratelimit-expressions.yaml
oc get ratelimitpolicy req019-cel-ratelimit -n rhcl-apps -o yaml | yq '.status.conditions'
```

| Limit | CEL | Effect |
|-------|---------------|--------|
| `financial-writes` | when: POST to `/api/v1/transfers` · counter: `request.headers['x-idempotency-key']` | 5 req/min per idempotency key |
| `reads-per-consumer` | when: GET `/api/v1/...` · counter: `request.headers['x-consumer-id']` | 60 req/min per consumer |

```bash
# 8. Rate limit per idempotency-key (same key → ~5×200 + ~3×429)
for i in $(seq 1 8); do curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://$HOST/api/v1/transfers" \
  -H "api-key: $KEY" -H "content-type: application/json" -H "x-idempotency-key: same-key-burst-test" \
  -d '{"fromBank":"EXAMPLE","toBank":"EXT","amount":10}'; done | sort | uniq -c

# 9. Distinct keys have independent buckets (all 200)
for key in alpha beta gamma; do for i in $(seq 1 3); do curl -sk -o /dev/null -w "%{http_code} " \
  -X POST "https://$HOST/api/v1/transfers" -H "api-key: $KEY" -H "content-type: application/json" \
  -H "x-idempotency-key: $key" -d '{"fromBank":"EXAMPLE","toBank":"EXT","amount":10}'; done; echo; done

# 10. Rate limit per consumer-id on reads (~60×200 + ~5×429)
for i in $(seq 1 65); do curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" \
  -H "x-consumer-id: consumer-alpha" "https://$HOST/api/v1/accounts/summary"; done | sort | uniq -c
```

## What to look for

```bash
oc -n kuadrant-system logs deploy/authorino -f | grep -E "rhcl-apps|cel|bot|idempotency"
oc -n rhcl-apps get authpolicy banking-api-connectivity-apikey -o yaml | yq '.status'
oc -n rhcl-apps get ratelimitpolicy req019-cel-ratelimit -o yaml | yq '.status'
```

Expected from the smoke sequence: `normal=200`, `bot=403`, `no-key=403`,
`with-key=200`.

## Troubleshooting

| Symptom | Diagnosis |
|---------|-------------|
| Policy stays "Accepted (Not Enforced)" | Another AuthPolicy targets the same HTTPRoute. `oc get authpolicy -n rhcl-apps`; delete a stale one. |
| "Not Enforced" + `invalid argument to has() macro` | Authorino does not support `has()` with map-index access. Use direct comparison: `request.headers['x'] == 'value'` (a missing header returns an empty string). |
| AuthConfigs stuck at `false` (0/1) | AuthConfigs created with invalid logic stay errored; `oc delete authconfig -n kuadrant-system --all` to force recreation. |
| Idempotency test never blocks (always 200) | Confirm `x-cel-strict: true` is sent — without it the rule is not activated (by design). |
| Rate limit never returns 429 | Check Limitador health and that the RLP is `Enforced`. |
| Limitador CrashLoops | Double quotes in a counter expression break the parser. ALWAYS use single quotes: `request.headers['x-foo']`. |

## Cleanup

The CEL AuthPolicy is a permanent part of the environment (Ansible-managed); only
the Scenario-B RateLimitPolicy needs removal:

```bash
oc delete ratelimitpolicy req019-cel-ratelimit -n rhcl-apps --ignore-not-found
```

## References

- [Kuadrant CEL Introduction](https://docs.kuadrant.io/dev/kuadrant-operator/doc/cel/introduction/)
- [Kuadrant AuthPolicy API](https://docs.kuadrant.io/dev/kuadrant-operator/doc/reference/authpolicy/)
- [Kuadrant RateLimitPolicy API](https://docs.kuadrant.io/dev/kuadrant-operator/doc/reference/ratelimitpolicy/)
