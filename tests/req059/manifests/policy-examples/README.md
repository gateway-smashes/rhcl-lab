# REQ 59 policy examples

Optional policies for the browser-facing MCP `HTTPRoute`.

Apply one at a time:

```bash
oc apply -f require-client-app-authpolicy.yaml
oc apply -f mcp-ratelimitpolicy.yaml
```

Then rerun the MCP curl tests from [../../README.md](../../README.md).

Remove them with:

```bash
oc delete -f require-client-app-authpolicy.yaml --ignore-not-found
oc delete -f mcp-ratelimitpolicy.yaml --ignore-not-found
```

