---
title: A real model behind the AI gateway
summary: Put a real LLM behind the RHCL AI gateway (MaaS stand-in).
category: AI gateway
status: done
---

# REQ 76 — A real model behind the RHCL AI Gateway (MaaS stand-in)

The AI-gateway demos so far ran against the **banking-api mock**
(`banking-mock-gpt`) — perfect for proving the *governance* layer (auth, token
rate limits, cost) without a GPU. This package swaps that mock for a **real
model**, so you can show the AI story end-to-end: real completions, real token
usage, real throttling — all governed by RHCL.

> **What this is / isn't.** There is **no GPU and no OpenShift AI / KServe** on
> this sandbox, so we can't run the production MaaS stack. Instead we serve a
> small model on **CPU via Ollama** — same OpenAI-compatible contract
> (`/v1/chat/completions` with a real `usage.total_tokens`). **The RHCL front is
> identical** to fronting a real MaaS: the HTTPRoute + AuthPolicy +
> TokenRateLimitPolicy don't change. In production, swap the backend for a vLLM
> model served by RHOAI on GPU — nothing else moves.

```
   client ──(api-key)──▶  RHCL Gateway  ──▶  model server (/v1/*)
                          AuthPolicy            Ollama · llama3.2:1b   ← swap for
                          TokenRateLimitPolicy  (a MaaS backend)         vLLM/RHOAI
```

## What it wires

| Piece | What it does |
|-------|--------------|
| `manifests/10-ollama.yaml` | Ollama on CPU (OpenAI-compatible model server), Service `:11434` |
| `manifests/20-route-and-policies.yaml` | HTTPRoute `/v1/*` → Ollama, on the banking host (reuses its TLS/DNS) |
| — AuthPolicy `maas-model-apikey` | requires `api-key` (the same authorino keys as banking) |
| — TokenRateLimitPolicy `maas-model-tokens` | meters `usage.total_tokens` → **500 tokens / 1m** |

The banking app stays under `/api/*`; the model lives under `/v1/*` on the same
host — one gateway fronting both an app API and a model API.

## Deploy

```bash
oc login ...            # cluster-admin on the RHCL cluster
./deploy.sh             # host auto-detected; downloads the model on first run
```

## Demo

```bash
H=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
KEY=$(oc get secret banking-api-key-alice -n rhcl-apps -o jsonpath='{.data.api_key}' | base64 -d)

# 1) No key → the gateway blocks it (AuthPolicy)
curl -sk -o /dev/null -w '%{http_code}\n' "https://$H/v1/models"                 # 401

# 2) Real model, governed by RHCL — real answer + real token usage
curl -sk "https://$H/v1/chat/completions" -H "api-key: $KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"What is an API gateway? One sentence."}]}'

# 3) Keep firing → the token budget (500/min) trips → 429
for i in $(seq 1 10); do
  curl -sk -o /dev/null -w "%{http_code} " "https://$H/v1/chat/completions" -H "api-key: $KEY" \
    -H 'content-type: application/json' \
    -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"tell me a fun fact"}]}'
done; echo
```

The model runs on CPU — expect a few seconds per completion. Tune the budget:

```bash
oc patch tokenratelimitpolicy maas-model-tokens -n rhcl-apps --type=json \
  -p '[{"op":"replace","path":"/spec/limits/model-tokens/rates/0/limit","value":1000}]'
```

## Cleanup

```bash
oc delete -f manifests/20-route-and-policies.yaml --ignore-not-found
oc delete -f manifests/10-ollama.yaml --ignore-not-found
oc adm policy remove-scc-from-user anyuid -z ollama -n rhcl-apps || true
```
