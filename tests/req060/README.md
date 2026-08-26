# REQ 60 — TokenRateLimitPolicy with a mock OpenAI endpoint

This requirement validates RHCL token-based rate limiting without requiring a
real vLLM/KServe deployment. The primary test path uses the existing app
connectivity route:

```text
POST https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}/api/v1/chat/completions
```

The backend mock returns OpenAI-compatible `usage.total_tokens`, so Kuadrant can
enforce a `TokenRateLimitPolicy` in the same shape used by a real vLLM service.

## Prerequisites

Cluster and apps baseline:

```bash
oc whoami
oc -n rhcl-apps get deploy/banking-api-v1
oc -n openshift-ingress get gateway rhcl-apps-gateway
oc get crd tokenratelimitpolicies.kuadrant.io
```

Set the public DNS zone used by the RHCL lab:

```bash
export RHCL_ZONE_ROOT_DOMAIN=sandbox1364.opentlc.com
```

The shared Gateway and `HTTPRoute/banking-api-connectivity` (`PathPrefix /api/v1`)
must already exist from the apps install.

### AuthPolicy (required before token rate limit)

`TokenRateLimitPolicy` only applies after traffic passes gateway auth. Chat
completions must be **anonymous** (no `api-key`) for the PoC curl and **AI**
tab probes. That is configured by
[`manifests/10-authpolicy-connectivity-openai-access.yaml`](manifests/10-authpolicy-connectivity-openai-access.yaml)
(same shape as [req 33](../req033/manifests/20-authpolicy-connectivity-openai-access.yaml)).

Apply it **before** the token policy (included in the install steps below).

## Install

1. Apply the connectivity AuthPolicy (anonymous `/api/v1/chat/completions` and
   `/api/v1/models`):

   ```bash
   oc apply -f tests/req060/manifests/10-authpolicy-connectivity-openai-access.yaml
   ```

2. Apply the token policy. It targets `HTTPRoute/banking-api-connectivity` and
   filters to chat completions paths:

   ```bash
   oc apply -f tests/req060/manifests/30-tokenratelimitpolicy.yaml
   ```

3. Wait for the route, auth policy, and token policy:

   ```bash
   oc -n rhcl-apps wait httproute/banking-api-connectivity \
     --for=condition=Accepted=True --timeout=2m
   oc -n rhcl-apps wait authpolicy/banking-api-connectivity-apikey \
     --for=condition=Enforced=True --timeout=2m
   oc -n rhcl-apps wait tokenratelimitpolicy/banking-api-chat-completions-token-limit \
     --for=condition=Enforced=True --timeout=2m
   ```

## Validate with curl

The policy uses a small demo budget: `300 tokens / 1m`. The mock payload below
returns `157` total tokens, so the third request should return `429`.

```bash
export LLM_URL="https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}/api/v1/chat/completions"

for i in 1 2 3; do
  echo "request ${i}"
  curl -sk -i -X POST "${LLM_URL}" \
    -H 'content-type: application/json' \
    -H 'accept: application/json' \
    -H 'x-consumer-id: token-demo' \
    -d '{
      "model": "banking-mock-gpt",
      "mock_usage": {
        "prompt_tokens": 75,
        "completion_tokens": 82
      },
      "messages": [
        {
          "role": "user",
          "content": "Return a short account summary."
        }
      ]
    }' | sed -n '1,24p'
done
```

Expected result:

- request 1: `200`
- request 2: `200`
- request 3: `429 Too Many Requests`

## Validate with the frontend

Open `mobile-bank` -> **PoC Console** -> **AI**.

Use this endpoint:

```text
https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}/api/v1/chat/completions
```

Keep **Mock usage** enabled with:

- `prompt_tokens`: `75`
- `completion_tokens`: `82`

Click **Probe x3**. The first two calls should succeed and the third should
show `429` once the policy is enforced.

The generated apps route already has a broad `/api/v1` rule. The HTTPRoute
does not need a separate `/api/v1/chat/completions` rule for this requirement.
The `TokenRateLimitPolicy` filters by `request.path`, so it applies only to the
mock AI endpoint even though the route also serves the rest of `/api/v1`.

## Cleanup

```bash
oc -n rhcl-apps delete tokenratelimitpolicy/banking-api-chat-completions-token-limit --ignore-not-found
```

Re-run `apps-install` to restore the default `AuthPolicy` from Ansible, or keep
the req 60/33 auth manifest if you still need anonymous AI paths.
