# MCP Gateway Test Installation

Dedicated Istio Gateway **`rhcl-mcp-gateway`** and **all MCP Gateway resources**
in namespace **`mcp-gateway`**, isolated from `rhcl-apps-gateway`.

https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html-single/installing_the_mcp_gateway/index

## Architecture

| Component | Namespace | Purpose |
| --------- | --------- | ------- |
| MCP Gateway operator | `mcp-gateway` | OLM Subscription, broker Deployment |
| `Gateway rhcl-mcp-gateway` | `mcp-gateway` | Istio (`openshift-default`), listeners `mcp` + `mcps` |
| `MCPGatewayExtension`, HTTPRoutes, AuthPolicies | `mcp-gateway` | Broker, browser route, backend discovery |
| `AuthPolicy rhcl-mcp-gateway-deny-all` | `mcp-gateway` | Gateway-wide deny; HTTPRoute policies override with `allow = true` |
| `ReferenceGrant` (backend only) | `rhcl-apps` | Allows route in `mcp-gateway` to reach `banking-api-v1` |
| `Route mcp-gateway-browser` | `mcp-gateway` | TLS edge to gateway Service :8080 |

## Preconditions

- Gateway API and RHCL installed
- `banking-api-v1` serves `/mcp` in `rhcl-apps`
- MCP Gateway operator in OperatorHub (RHCL 1.3 Tech Preview)

## Run the playbook

```bash
cd automation
source scripts/cluster-env.sh

export MCP_GATEWAY_NAMESPACE=mcp-gateway
export MCP_GATEWAY_GATEWAY_NAMESPACE=mcp-gateway

ansible-playbook playbooks/mcp_gateway-install.yml
ansible-playbook playbooks/mcp_gateway-test.yml
```

### Defaults

| Variable | Default |
| -------- | ------- |
| `MCP_GATEWAY_NAMESPACE` | `mcp-gateway` |
| `MCP_GATEWAY_GATEWAY_NAMESPACE` | `mcp-gateway` |
| `MCP_GATEWAY_GATEWAY_NAME` | `rhcl-mcp-gateway` |
| `MCP_GATEWAY_MANAGE_GATEWAY` | `true` |
| `MCP_GATEWAY_GATEWAY_DENY_ALL_ENABLED` | `true` |

Kuadrant `AuthPolicy` objects for the MCP gateway must live in **`mcp-gateway`**
(same namespace as `rhcl-mcp-gateway` and the MCP HTTPRoutes). Do not point them
at `openshift-ingress` or `rhcl-apps`.

## Verify

```bash
oc get gateway -n mcp-gateway rhcl-mcp-gateway
oc get mcpgatewayextension -n mcp-gateway mcp-gateway
oc wait --for=condition=Ready mcpgatewayextension/mcp-gateway -n mcp-gateway --timeout=300s
oc get httproute -n mcp-gateway
oc get authpolicy -n mcp-gateway
```

Browser URL: `http://mcp-gateway.<zone>:8080/mcp`

## Cleanup

```bash
ansible-playbook playbooks/mcp_gateway-remove.yml
```
