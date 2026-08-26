# REQ 33 manifests

OpenAI mock traffic uses the existing `HTTPRoute/banking-api-connectivity`
(`PathPrefix /api/v1`). These manifests only adjust gateway auth — no new route.

| File | Purpose |
| --- | --- |
| `20-authpolicy-connectivity-openai-access.yaml` | Replaces `AuthPolicy/banking-api-connectivity-apikey` so `/api/v1/models` and `/api/v1/chat/completions` are anonymous (no API key). |

Same policy for req 60:
[`tests/req060/manifests/10-authpolicy-connectivity-openai-access.yaml`](../../req060/manifests/10-authpolicy-connectivity-openai-access.yaml).
Apply one copy only.

Apply:

```bash
oc apply -f tests/req033/manifests/20-authpolicy-connectivity-openai-access.yaml
```

See [`../README.md`](../README.md).
