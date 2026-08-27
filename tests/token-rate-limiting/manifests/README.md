# REQ 60 manifests

Apply in order: AuthPolicy first (gateway auth for chat completions), then
TokenRateLimitPolicy.

| File | Purpose |
| --- | --- |
| `10-authpolicy-connectivity-openai-access.yaml` | **Prerequisite.** Anonymous access to `/api/v1/chat/completions` (and `/api/v1/models`) on `HTTPRoute/banking-api-connectivity`. Required so req 60 probes are not blocked by API key auth before rate limiting runs. |
| `30-tokenratelimitpolicy.yaml` | `300 tokens / 1m` limit on chat completions paths for `HTTPRoute/banking-api-connectivity`. |

```bash
oc apply -f tests/token-rate-limiting/manifests/10-authpolicy-connectivity-openai-access.yaml
oc apply -f tests/token-rate-limiting/manifests/30-tokenratelimitpolicy.yaml
```

The auth manifest matches
[`tests/openai-compatible-surface/manifests/20-authpolicy-connectivity-openai-access.yaml`](../../openai-compatible-surface/manifests/20-authpolicy-connectivity-openai-access.yaml)
(req 33 OpenAI surface). Apply one copy only.

See [`../README.md`](../README.md).
