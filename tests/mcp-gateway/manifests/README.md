# REQ 59 manifests — MCP Gateway operator

All resources live in namespace **`mcp-gateway`**: operator, dedicated Gateway
`rhcl-mcp-gateway`, HTTPRoutes, AuthPolicies, and MCP CRs. Isolated from
`rhcl-apps-gateway` in `openshift-ingress`.

Replace **`${RHCL_ZONE_ROOT_DOMAIN}`** with `envsubst` before `oc apply`.

| Range | Purpose |
| --- | --- |
| `10` | Namespace `mcp-gateway` |
| `11`–`12` | OperatorGroup, Subscription |
| `21` | ReferenceGrant in `rhcl-apps` (HTTPRoute → `banking-api-v1`) |
| `30-rhcl-mcp-gateway.yaml` | Gateway `openshift-default` (AWS / OpenShift native) |
| `30-rhcl-mcp-gateway-istio.yaml` | Gateway `istio` (Sail/OSSM3 / BB lab) |
| `30-gateway-istio-compat-service.yaml` | Internal Service — **openshift-default only** |
| `31-mcp-gateway-deny-all-authpolicy.yaml` | Gateway deny-all (optional; breaks with MCP ext_proc today) |
| `40`–`46` | Extension, routes, registration, AuthPolicies, OpenShift Route |
| `47` | CORS EnvoyFilter (Lua — preflight before auth, headers on all responses) |

No ReferenceGrant for Gateway ↔ HTTPRoute in the same namespace.

Apply order: [../README.md](../README.md). For **GatewayClass `istio`** (BB / Sail): [../scripts/apply-istio.sh](../scripts/apply-istio.sh).

Ansible: `automation/playbooks/mcp_gateway-install.yml`.
