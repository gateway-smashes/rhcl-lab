# REQ 017 — production manifests (Quay images)

Cluster-facing manifests for environments that pull pre-built MCP images from
**Quay** instead of building inside OpenShift (`ImageStream` / `BuildConfig`).

| File | Purpose |
| --- | --- |
| `00-namespace.yaml` | Namespace `rhcl-mcp-lab` |
| `01-image-pull-secret.yaml.example` | Optional pull secret for private Quay repos |
| `20-deployments.yaml` | Deployments (`${MCP_QUAY_REPO}:rhcl-*-mcp-${MCP_IMAGE_TAG}`) |
| `21-services.yaml` | ClusterIP Services on port 8080 |
| `30-routes.yaml` | Edge Routes (`${RHCL_ZONE_ROOT_DOMAIN}`) |
| `40-mcpservers.yaml` | `MCPServer` CRs (MCP Lifecycle Operator) |
| `catalog/` | OpenShift AI MCP catalog YAML (Quay OCI artifact URIs) |
| `60-gen-ai-aa-mcp-servers.yaml` | Playground tool picker (in-cluster HTTP URLs) |

Apply end-to-end: [`../../scripts/apply-prod.sh`](../../scripts/apply-prod.sh).

Build and push images first: [`../../scripts/build-push-quay.sh`](../../scripts/build-push-quay.sh).

Default image repository:

```text
quay.io/rh_ee_tavelino/mcp:rhcl-lab-info-mcp-latest
quay.io/rh_ee_tavelino/mcp:rhcl-text-tools-mcp-latest
quay.io/rh_ee_tavelino/mcp:rhcl-time-tools-mcp-latest
```

Override with `MCP_QUAY_REPO` and `MCP_IMAGE_TAG` (for example `0.1.0`).
