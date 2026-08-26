# REQ 33 — OpenAI-compatible API surface (`/api/v1` only)

All mock OpenAI endpoints live under **`/api/v1`** so the existing
`HTTPRoute/banking-api-connectivity` rule (`PathPrefix /api/v1`) is enough.
No separate `llm.*` host or extra HTTPRoute rules are required.

## Backend paths (banking-api)

| Method | Path |
| --- | --- |
| `GET` | `/api/v1/models` |
| `POST` | `/api/v1/chat/completions` (JSON or SSE via `Accept: text/event-stream`) |

## Gateway URL

```text
https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}/api/v1/models
https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}/api/v1/chat/completions
```

Token rate limiting ([req 60](../req060/)) still applies **only** to
`/api/v1/chat/completions`, not to `/api/v1/models`.

## Prerequisites

```bash
oc whoami
oc -n rhcl-apps get httproute/banking-api-connectivity
export RHCL_ZONE_ROOT_DOMAIN=your.lab.domain
```

## Install

Allow anonymous access to `/api/v1/models` on the connectivity route (in addition
to chat completions). Apply the patched AuthPolicy:

```bash
oc apply -f tests/req033/manifests/20-authpolicy-connectivity-openai-access.yaml
# same file for req 60: tests/req060/manifests/10-authpolicy-connectivity-openai-access.yaml

oc -n rhcl-apps wait authpolicy/banking-api-connectivity-apikey \
  --for=condition=Enforced=True --timeout=2m
```

Fresh clusters installed with updated Ansible (`connectivity-authpolicy-apikey.yml.j2`)
already include this predicate.

## Validate with curl

```bash
export GW="https://banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN}"

curl -sk "${GW}/api/v1/models" | jq .
curl -sk -X POST "${GW}/api/v1/chat/completions" \
  -H 'content-type: application/json' \
  -H 'x-consumer-id: alice' \
  -d '{"model":"banking-mock-gpt","messages":[{"role":"user","content":"hello"}]}' | jq .
```

Expected: HTTP `200` for both.

## Validate with the frontend

PoC console → **AI** → **Settings** → **RHCL gateway** with connectivity host.

- Preset **GET /api/v1/models** → **Send**
- Preset **POST /api/v1/chat/completions** → **Send** (toggle SSE as needed)
- **Test all (3)** runs every OpenAI endpoint

## Cleanup

Re-run `apps-install` to restore the previous AuthPolicy from Ansible, or edit
`banking-api-connectivity-apikey` manually. No HTTPRoute resources are created
by this requirement.
