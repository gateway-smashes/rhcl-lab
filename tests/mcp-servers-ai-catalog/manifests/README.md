# REQ 017 manifests — RHCL lab MCP servers for OpenShift AI catalog

All MCP workloads live in namespace **`rhcl-mcp-lab`**. Catalog metadata is
patched into **`redhat-ods-applications/model-catalog-sources`**.

## Lab (`manifests/`)

In-cluster build via OpenShift `ImageStream` + `BuildConfig`.

| Range | Purpose |
| --- | --- |
| `00` | Namespace `rhcl-mcp-lab` |
| `10`–`11` | ImageStreams + BuildConfigs (binary builds) |
| `20`–`21` | Deployments + Services |
| `30` | OpenShift Routes (`${RHCL_ZONE_ROOT_DOMAIN}`) |
| `40` | `MCPServer` CRs (MCP Lifecycle Operator) |
| `catalog/` | `rhcl-mcp-servers.yaml` + `rhcl-sources.yaml` for AI hub |
| `60` | `gen-ai-aa-mcp-servers` ConfigMap (playground) |

Apply order: [`../scripts/apply.sh`](../scripts/apply.sh).

## Production (`manifests/prod/`)

Pre-built images from Quay — **no** `ImageStream` / `BuildConfig`. Same
namespace, Services, Routes, catalog, and playground ConfigMap; Deployments and
`MCPServer` CRs reference `${MCP_QUAY_REPO}:rhcl-*-mcp-${MCP_IMAGE_TAG}`.

Apply order: [`../scripts/apply-prod.sh`](../scripts/apply-prod.sh).  
Build images: [`../scripts/build-push-quay.sh`](../scripts/build-push-quay.sh).
