---
title: MCP servers in the OpenShift AI catalog
summary: Register the lab's MCP servers so they surface in the OpenShift AI model catalog.
category: MCP
status: done
---

# REQ 017 — RHCL lab MCP servers for OpenShift AI catalog

Deploy **three lightweight MCP servers** into namespace `rhcl-mcp-lab` and register
them in the **OpenShift AI MCP catalog** so they appear under **AI hub → MCP
catalog**. See [`../mcp-servers-ai-catalog/README.md`](../mcp-servers-ai-catalog/README.md) for a short overview and
[`index.html`](index.html) for the interactive page.

Ansible baseline: `automation/playbooks/ocp_ai-install.yml` (see
[`automation/README_TEST_INSTALLATION_OCP_AI.md`](../../automation/README_TEST_INSTALLATION_OCP_AI.md)).

## MCP servers

| Catalog name | Tools | Image |
| --- | --- | --- |
| `rhcl-lab-info` | `get_lab_name`, `list_target_zones`, `ping` | `rhcl-lab-info-mcp:latest` |
| `rhcl-text-tools` | `uppercase`, `word_count`, `reverse_text` | `rhcl-text-tools-mcp:latest` |
| `rhcl-time-tools` | `now_utc`, `format_timestamp`, `add_minutes` | `rhcl-time-tools-mcp:latest` |

Source code: [`servers/`](servers/) (Python + `mcp` FastMCP, Streamable HTTP on
port `8080`, path `/mcp`).

## Prerequisites

- OpenShift **4.19+** with OpenShift AI **3.4** (`DataScienceCluster` phase `Ready`)
- `spec.dashboardConfig.genAiStudio: true` in `OdhDashboardConfig`
- MCP catalog ConfigMap **`mcp-catalog-sources`** in namespace **`rhoai-model-registries`**
  (not `model-catalog-sources` in `redhat-ods-applications`)
- `oc` logged in; cluster can build UBI9 Python images
- `envsubst` from `gettext`; optional `PyYAML` for `patch-catalog.sh`

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"

oc get datasciencecluster default-dsc -o jsonpath='phase={.status.phase}{"\n"}'
oc api-resources | grep -i mcpserver
```

## Files

| Path | Purpose |
| --- | --- |
| [`servers/`](servers/) | Python MCP servers + `Containerfile` per server |
| [`manifests/`](manifests/) | Lab manifests: ImageStreams, BuildConfigs, Deployments, Services, Routes, `MCPServer` CRs, catalog YAML, playground ConfigMap |
| [`manifests/prod/`](manifests/prod/) | **Production** manifests: Quay images only (no in-cluster build) |
| [`scripts/apply.sh`](scripts/apply.sh) | End-to-end install (in-cluster build) |
| [`scripts/apply-prod.sh`](scripts/apply-prod.sh) | End-to-end install from Quay |
| [`scripts/build-images.sh`](scripts/build-images.sh) | `oc start-build --from-dir` |
| [`scripts/build-push-quay.sh`](scripts/build-push-quay.sh) | `podman build` + `podman push` to Quay |
| [`scripts/patch-catalog.sh`](scripts/patch-catalog.sh) | Patch `rhoai-model-registries/mcp-catalog-sources` |
| [`scripts/validate.sh`](scripts/validate.sh) | Smoke checks |

## Apply on the cluster (lab — in-cluster build)

```bash
export KUBECONFIG=/path/to/active/kubeconfig
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"

bash tests/mcp-servers-ai-catalog/scripts/apply.sh
```

Flags:

- `--skip-build` — images already built
- `--skip-catalog` — skip `mcp-catalog-sources` patch
- `--skip-mcpserver` — skip `MCPServer` CRs when the lifecycle operator is absent
- `--skip-playground` — skip `gen-ai-aa-mcp-servers` ConfigMap

Build images only: `bash tests/mcp-servers-ai-catalog/scripts/build-images.sh`

Register catalog only: `bash tests/mcp-servers-ai-catalog/scripts/patch-catalog.sh`

## Apply on the cluster (production — Quay images)

Pre-built images (default repository `quay.io/rh_ee_tavelino/mcp`):

| Server | Image tag |
| --- | --- |
| `rhcl-lab-info` | `rhcl-lab-info-mcp-latest` (or `-0.1.0`) |
| `rhcl-text-tools` | `rhcl-text-tools-mcp-latest` |
| `rhcl-time-tools` | `rhcl-time-tools-mcp-latest` |

Build and push (from a workstation with `podman`):

```bash
podman login quay.io
bash tests/mcp-servers-ai-catalog/scripts/build-push-quay.sh
```

Apply manifests under [`manifests/prod/`](manifests/prod/) — no `ImageStream` / `BuildConfig`:

```bash
export KUBECONFIG=/path/to/active/kubeconfig
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"
export MCP_QUAY_REPO=quay.io/rh_ee_tavelino/mcp
export MCP_IMAGE_TAG=latest

bash tests/mcp-servers-ai-catalog/scripts/apply-prod.sh
```

For a **private** Quay repo, copy
[`manifests/prod/01-image-pull-secret.yaml.example`](manifests/prod/01-image-pull-secret.yaml.example)
to `01-image-pull-secret.yaml`, fill credentials, then re-run `apply-prod.sh`.

Manual apply (without the script):

```bash
oc apply -f tests/mcp-servers-ai-catalog/manifests/prod/00-namespace.yaml
envsubst < tests/mcp-servers-ai-catalog/manifests/prod/20-deployments.yaml | oc apply -f -
oc apply -f tests/mcp-servers-ai-catalog/manifests/prod/21-services.yaml
envsubst < tests/mcp-servers-ai-catalog/manifests/prod/30-routes.yaml | oc apply -f -
envsubst < tests/mcp-servers-ai-catalog/manifests/prod/40-mcpservers.yaml | oc apply -f -
oc apply -f tests/mcp-servers-ai-catalog/manifests/prod/60-gen-ai-aa-mcp-servers.yaml
```

## How to verify

1. Hard-refresh the dashboard (`Ctrl+Shift+R`).
2. Open **AI hub → MCP catalog** and filter by **RHCL Lab** — three servers
   with tool metadata.
3. Optional: **Deploy MCP server** on a catalog entry (needs `MCPServer` CRD).
4. CLI: `bash tests/mcp-servers-ai-catalog/scripts/validate.sh`

External Route (curl from your laptop):

```bash
curl -sS -D - \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  "https://rhcl-lab-info-mcp.${RHCL_ZONE_ROOT_DOMAIN}/mcp"
```

**Gen AI Playground:** ConfigMap `gen-ai-aa-mcp-servers` must use **in-cluster
HTTP** URLs (`http://rhcl-*-mcp.rhcl-mcp-lab.svc.cluster.local:8080/mcp`). The
dashboard validates MCP status from inside the cluster and rejects Route TLS
certificates (self-signed edge termination).

## Cleanup

```bash
oc delete ns rhcl-mcp-lab --wait=false
oc -n redhat-ods-applications delete configmap gen-ai-aa-mcp-servers --ignore-not-found
# Remove rhcl_lab_mcp_servers from mcp-catalog-sources manually or re-run patch after editing sources.yaml
```

## Requirement context

Deploy three simple MCP servers and register them in the **OpenShift AI MCP
catalog** for discovery, deployment, and Gen AI Playground tool calling.

- Runbook: [`tests/mcp-servers-ai-catalog/README.md`](mcp-servers-ai-catalog/README.md)
- Interactive page: [`tests/mcp-servers-ai-catalog/index.html`](mcp-servers-ai-catalog/index.html)

## Servers

| Name | Tools |
| --- | --- |
| `rhcl-lab-info` | `get_lab_name`, `list_target_zones`, `ping` |
| `rhcl-text-tools` | `uppercase`, `word_count`, `reverse_text` |
| `rhcl-time-tools` | `now_utc`, `format_timestamp`, `add_minutes` |

## Quick start

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"
bash tests/mcp-servers-ai-catalog/scripts/apply.sh
```

Then open **OpenShift AI → AI hub → MCP catalog** and look for **RHCL Lab MCP
Servers**.
