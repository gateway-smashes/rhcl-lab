---
title: OpenAI-compatible API surface
summary: Expose an OpenAI-compatible /api/v1 surface for AI clients.
category: AI gateway
status: done
---

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
oc apply -f tests/openai-compatible-surface/manifests/20-authpolicy-connectivity-openai-access.yaml
# same file for req 60: tests/token-rate-limiting/manifests/10-authpolicy-connectivity-openai-access.yaml

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

## Requirement context

REQ 33 validates that the banking-api exposes an OpenAI-compatible mock AI
surface through Red Hat Connectivity Link using **Gateway API + Kuadrant**
resources, without depending on a real LLM provider.

All endpoints live under `/api/v1` so the existing
`HTTPRoute/banking-api-connectivity` (`PathPrefix /api/v1`) is enough — no
separate host or extra HTTPRoute rules are required.

## Endpoints

| Method | Path                       | Response shape                                                    |
| ------ | -------------------------- | ----------------------------------------------------------------- |
| `GET`  | `/api/v1/models`           | `{ "object": "list", "data": [...] }`                             |
| `POST` | `/api/v1/chat/completions` | `{ "object": "chat.completion", "choices": [...] }` — JSON or SSE |
| `POST` | `/api/v1/completions`      | `{ "object": "text_completion", "choices": [...] }`               |
| `POST` | `/api/v1/embeddings`       | `{ "object": "list", "data": [{ "embedding": [...] }] }`          |
| `POST` | `/api/v1/responses`        | `{ "object": "response", "output": [...] }`                       |

## Manifests

AuthPolicy that allows anonymous access to all `/api/v1` AI paths lives in
[`tests/openai-compatible-surface/manifests/`](openai-compatible-surface/manifests/). The same policy is used as a
prerequisite by [req 60](token-rate-limiting/manifests/) (token rate limiting).

Full runbook: [`tests/openai-compatible-surface/README.md`](openai-compatible-surface/README.md).

## Relationship with other requirements

- **Req 60** — `TokenRateLimitPolicy` on `POST /api/v1/chat/completions`; requires
  this AuthPolicy to be applied first so chat completions are anonymous before
  rate limiting runs. See [`tests/token-rate-limiting/`](req060/).
- **Req 40** — the mock `usage` blocks returned by the AI endpoints are read
  by Kuadrant Limitador via the REQ 60 `TokenRateLimitPolicy`, which feeds the
  RHCL-native token counter (`authorized_hits`) — the banking-api itself
  emits no token Micrometer counter.

## PoC console

The **AI** tab in the PoC console covers all five endpoints above with
individual presets and a **Test all** batch that exercises the full surface
against `HTTPRoute/banking-api-connectivity`.
