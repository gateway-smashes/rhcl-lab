# REQ 024 — ExternalModel LiteLLM on OpenShift AI MaaS

This runbook registers the LiteLLM endpoint (`maas-rhdp.apps.maas.redhatworkshops.io`)
as an **ExternalModel** in OpenShift AI Models as a Service (MaaS), with provider
`openai` and three models.

Automation baseline: `automation/playbooks/ocp_ai-install.yml` (see
[`automation/README_TEST_INSTALLATION_OCP_AI.md`](../../automation/README_TEST_INSTALLATION_OCP_AI.md)).

## Target flow

```text
Client / app
    |  Authorization: Bearer sk-oai-...   (MaaS API key from dashboard)
    v
Route maas.apps.<domain>  →  Gateway maas-default-gateway
    |  Kuadrant Authorino validates MaaS key on /external-models/qwen3-14b-external/...
    |  HTTPRoute rewrites path prefix → /v1/...
    |  HTTPRoute sets Authorization → Bearer <LiteLLM key from Secret>   (PoC workaround)
    v
maas-rhdp.apps.maas.redhatworkshops.io/v1/chat/completions
    |  model: qwen3-14b
    v
qwen3-14b (LiteLLM upstream)
```

All three LiteLLM models share the same upstream endpoint and Secret
(`litellm-api-key`); only `targetModel` differs:

| MaaS resource name         | `targetModel` (JSON `"model"` field) |
| -------------------------- | ------------------------------------ |
| `qwen3-14b-external`       | `qwen3-14b`                          |
| `llama-31-70b-external`    | `llama-31-70b-cpu`                   |
| `llama-scout-17b-external` | `llama-scout-17b`                    |

On upstream OpenShift clusters the BBR `payload-processing` ext_proc filter does
**not** reliably inject the provider credential (wrong EnvoyFilter anchor and
filter order vs Kuadrant wasm). The PoC uses
`scripts/patch-httproute-upstream-auth.sh` to set the upstream `Authorization`
header on the ExternalModel `HTTPRoute` **after** Kuadrant has validated the
client MaaS key.

## Two credential types

| Key                 | Purpose                                          | Where it lives                                |
| ------------------- | ------------------------------------------------ | --------------------------------------------- |
| LiteLLM (`sk-...`)  | Upstream provider credential (cluster → LiteLLM) | Secret `litellm-api-key` in `external-models` |
| MaaS (`sk-oai-...`) | Client credential (apps / users)                 | Generated in the MaaS dashboard               |

Never commit the LiteLLM key to Git. Rotate any key that was exposed in chat or
logs before applying.

## Prerequisites

- OpenShift AI 3.4 with `DataScienceCluster` phase `Ready`
- `kserve.modelsAsService` component **Managed**
- CRDs `ExternalModel` and `MaaSModelRef` installed
- MaaS gateway `maas-default-gateway` in `openshift-ingress`
- Route `maas.apps.<cluster-domain>` (required for the dashboard MaaS tab)

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"

oc get datasciencecluster default-dsc -o jsonpath='phase={.status.phase}{"\n"}'
oc api-resources | grep -i externalmodel
oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}{"\n"}'
```

## Files

| File                                                                                                   | Purpose                                                      |
| ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| [`manifests/00-namespace.yaml`](manifests/00-namespace.yaml)                                           | Namespace `external-models`                                  |
| [`manifests/01-qwen3-14b-external-model.yaml`](manifests/01-qwen3-14b-external-model.yaml)             | `ExternalModel` + `MaaSModelRef` (`qwen3-14b`)               |
| [`manifests/02-llama-31-70b-external-model.yaml`](manifests/02-llama-31-70b-external-model.yaml)       | `ExternalModel` + `MaaSModelRef` (`llama-31-70b-cpu`)        |
| [`manifests/03-llama-scout-17b-external-model.yaml`](manifests/03-llama-scout-17b-external-model.yaml) | `ExternalModel` + `MaaSModelRef` (`llama-scout-17b`)         |
| [`scripts/models.sh`](scripts/models.sh)                                                               | Shared list of MaaS resource names → `targetModel` values    |
| [`scripts/create-secret.sh`](scripts/create-secret.sh)                                                 | Create upstream Secret without echoing the key               |
| [`scripts/patch-maas-gateway.sh`](scripts/patch-maas-gateway.sh)                                       | Allow `external-models` HTTPRoutes on the MaaS gateway       |
| [`scripts/patch-httproute-rewrite.sh`](scripts/patch-httproute-rewrite.sh)                             | Fix LiteLLM 404 — rewrite `/external-models/<name>` → `/`   |
| [`scripts/patch-httproute-upstream-auth.sh`](scripts/patch-httproute-upstream-auth.sh)                 | **PoC fix** — inject LiteLLM `Authorization` on the HTTPRoute |
| [`scripts/patch-payload-processing-envoyfilter.sh`](scripts/patch-payload-processing-envoyfilter.sh)   | Optional BBR ext_proc anchor fix (operator may revert)       |
| [`scripts/apply.sh`](scripts/apply.sh)                                                                 | Namespace, Secret check, manifests, and all patches          |
| [`scripts/validate.sh`](scripts/validate.sh)                                                           | Resource checks and optional inference smoke test            |
| [`scripts/expose-maas-gateway-lb.sh`](scripts/expose-maas-gateway-lb.sh)                               | Optional LoadBalancer exposure (see caveats below)           |
| [`scripts/patch-ai-asset-custom-endpoints.sh`](scripts/patch-ai-asset-custom-endpoints.sh)             | Enable external provider custom endpoints in the dashboard |

## External endpoint scope

Before changing the cluster, decide how each endpoint type is treated in Gen AI
studio:

| Type | Example | Treatment |
| --- | --- | --- |
| Internal, same namespace | KServe/vLLM model in the project | Supported normally |
| Internal, other namespace | Service `*.svc.cluster.local` | Custom Endpoint |
| Internal, exposed by Route | LiteLLM, MaaS, or vLLM via Route | Custom Endpoint + optional `clusterDomains` |
| External to cluster | OpenAI, Azure, Anthropic, AWS | External Provider |
| Intermediate gateway | LiteLLM, RHCL, OpenAI-compatible gateway | External Provider or internal domain |

For this PoC, `https://maas-rhdp.apps.maas.redhatworkshops.io/v1` is treated as
**external** unless its domain is listed in `clusterDomains`. Do **not** add broad
public TLDs (for example `.com`) to `clusterDomains` — only internal domains
controlled by your organization.

Ansible enables this automatically via `OdhDashboardConfig` (see
`automation/roles/ocp_ai/templates/odh-dashboard-config.yml.j2`). To apply
manually without replacing other dashboard settings:

```bash
bash tests/req024/scripts/patch-ai-asset-custom-endpoints.sh
```

Equivalent `oc patch` (merge — preserves `genAiStudio`, `modelAsService`, etc.):

```bash
oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications \
  --type=merge \
  -p '{
    "spec": {
      "dashboardConfig": {
        "aiAssetCustomEndpoints": true
      },
      "genAiStudioConfig": {
        "aiAssetCustomEndpoints": {
          "externalProviders": true,
          "clusterDomains": []
        }
      }
    }
  }'
```

Optional internal Route domains (comma-separated):

```bash
export OCP_AI_DASHBOARD_AI_ASSET_CLUSTER_DOMAINS="apps.maas.example.com"
bash tests/req024/scripts/patch-ai-asset-custom-endpoints.sh
```

Hard-refresh the dashboard (`Ctrl+Shift+R`) after applying.

## Installation

### 1. Create the upstream Secret

```bash

# Option A — interactive prompt
bash tests/req024/scripts/create-secret.sh

# Option B — environment variable (avoid shell history)
read -s LITELLM_API_KEY && echo
export LITELLM_API_KEY
bash tests/req024/scripts/create-secret.sh
unset LITELLM_API_KEY
```

The Secret **must** use data key `api-key` and label
`inference.networking.k8s.io/bbr-managed=true`.

### 2. Apply manifests and patches

`apply.sh` runs, in order:

1. Namespace manifest
2. `patch-maas-gateway.sh` — gateway namespace selector for `external-models`
3. All `ExternalModel` + `MaaSModelRef` manifests (`01`–`03`)
4. For each model: `patch-httproute-rewrite.sh` — path rewrite for LiteLLM
5. For each model: `patch-httproute-upstream-auth.sh` — upstream credential inject (**required on OpenShift**)
6. `patch-payload-processing-envoyfilter.sh` — best-effort BBR fix (may be reverted by `maas-api`)

```bash
bash tests/req024/scripts/apply.sh
```

Manual equivalent:

```bash
oc apply -f tests/req024/manifests/00-namespace.yaml
bash tests/req024/scripts/create-secret.sh   # if not done yet
bash tests/req024/scripts/patch-maas-gateway.sh
oc apply -f tests/req024/manifests/01-qwen3-14b-external-model.yaml
oc apply -f tests/req024/manifests/02-llama-31-70b-external-model.yaml
oc apply -f tests/req024/manifests/03-llama-scout-17b-external-model.yaml
for m in qwen3-14b-external llama-31-70b-external llama-scout-17b-external; do
  EXTERNAL_MODEL_NAME="$m" bash tests/req024/scripts/patch-httproute-rewrite.sh
  EXTERNAL_MODEL_NAME="$m" bash tests/req024/scripts/patch-httproute-upstream-auth.sh
done
```

### 3. Validate

```bash
bash tests/req024/scripts/validate.sh
```

Expected:

```bash
oc get maasmodelref qwen3-14b-external -n external-models \
  -o jsonpath='{.status.phase}{"\n"}'
# Ready

oc get service,httproute,serviceentry,destinationrule -n external-models
```

## MaaS gateway URLs

Three different hostnames appear in this PoC — do not confuse them:

| URL                                                                                           | Role                                                            | Works externally?                                     |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| `https://maas.apps.<domain>`                                                                  | OpenShift **Route** to `maas-default-gateway` (lab default)     | **Yes** — use for `curl`, dashboard, external clients |
| `https://maas-api.apps.<domain>`                                                              | Gateway **listener hostname** (optional LB / `expose-maas-gateway-lb.sh`) | Often **503** when no Route exists for that host |
| `https://maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local` | In-cluster Service (pods)                                       | **Yes** — from inside the cluster only                |

The dashboard discovers the MaaS API at `https://maas.apps.<domain>/maas-api/...`
(path `/maas-api` on the `maas.apps` host — **not** the `maas-api.apps` subdomain).

`validate.sh` prefers the `maas.apps` Route hostname. Override manually:

```bash
export MAAS_URL="https://maas.apps.${RHCL_ZONE_ROOT_DOMAIN}"
export MAAS_API_KEY="sk-oai-..."
bash tests/req024/scripts/validate.sh
```

## Dashboard — **Models as a service** tab

The **Models as a service** tab under **Gen AI studio → AI asset endpoints** is
separate from the **Models** tab. ExternalModel resources do **not** appear under
**Models**; they are listed only under **Models as a service** (or via **View** to
generate an API key).

### Cluster checks

```bash
oc get datasciencecluster default-dsc \
  -o jsonpath='modelsAsService={.spec.components.kserve.modelsAsService.managementState}{"\n"}'

oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='genAiStudio={.spec.dashboardConfig.genAiStudio} modelAsService={.spec.dashboardConfig.modelAsService} maasAuthPolicies={.spec.dashboardConfig.maasAuthPolicies}{"\n"}'
# genAiStudio=true modelAsService=true maasAuthPolicies=true

oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}{"\n"}'
# maas.apps.<cluster-domain>

oc get maasmodelref qwen3-14b-external -n external-models -o jsonpath='phase={.status.phase}{"\n"}'
oc get maassubscription default-subscription -n models-as-a-service -o jsonpath='phase={.status.phase}{"\n"}'
```

Quick MaaS API reachability (no token → **401** is OK; **503/500** is a problem):

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  "https://maas.apps.${RHCL_ZONE_ROOT_DOMAIN}/v1/models"
```

> **Warning:** `expose-maas-gateway-lb.sh` (LoadBalancer + `maas-api.apps...`) breaks
> the dashboard if Route `maas.apps.<domain>` is missing. For the MaaS tab, keep the
> gateway on **ClusterIP** + Route `maas.apps` (Ansible default).

### User permissions (required)

The MaaS tab loads only when the logged-in user:

1. Belongs to a **group in the MaaS subscription** (e.g. `rhods-admins` in
   `default-subscription`), and
2. Authenticates via a normal OpenShift identity provider (HTPasswd, LDAP, etc.) —
   **not** installer bootstrap accounts.

| User                                 | MaaS tab works? | Reason                                                 |
| ------------------------------------ | --------------- | ------------------------------------------------------ |
| `kubeadmin`                          | **No**          | Bootstrap account; session does not work with MaaS API |
| `kube:admin`                         | **No**          | Built-in account with `:` in the name                  |
| HTPasswd/LDAP user in `rhods-admins` | **Yes**         | Normal OpenShift identity + subscription group         |

```bash
oc get maassubscription default-subscription -n models-as-a-service \
  -o jsonpath='groups={.spec.owner.groups[*].name}{"\n"}'
oc get group rhods-admins -o jsonpath='users={.users}{"\n"}'
```

Example test user (`aiadmin` in `rhods-admins`):

```bash
htpasswd -cbB /tmp/htpasswd aiadmin 'YOUR_SECURE_PASSWORD'
oc create secret generic htpasswd-aiadmin \
  --from-file=htpasswd=/tmp/htpasswd -n openshift-config --dry-run=client -o yaml | oc apply -f -
oc adm groups add-users rhods-admins aiadmin
rm -f /tmp/htpasswd
```

Log in to the dashboard with **htpasswd** (not `kubeadmin`), hard-refresh, then open
**Gen AI studio → AI asset endpoints → Models as a service**.

### Dashboard troubleshooting

| Symptom                                | Cause                                    | Fix                                                              |
| -------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------- |
| _"MaaS could not be loaded"_           | `maas.apps` returns 503                  | Create Route → `maas-default-gateway-data-science-gateway-class` |
| Only **Models** / **MCP servers** tabs | User not in subscription group           | Add user to `rhods-admins`, re-login                             |
| Logged in as `kubeadmin`, no MaaS tab  | Bootstrap account unsupported            | Use HTPasswd/LDAP user in `rhods-admins`                         |
| HTTP 500 on `maas.apps`                | Missing Authorino annotations on Gateway | See `automation/roles/ocp_ai/templates/maas-gateway.yml.j2`      |
| **Settings → Subscriptions** missing   | `maasAuthPolicies: false`                | Patch `OdhDashboardConfig` (`maasAuthPolicies: true`)            |

Reference: [Deploy and manage MaaS — Red Hat OpenShift AI 3.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas).

## Subscription and MaaS API key

**Settings → Subscriptions** configures groups, models, and limits — it does **not**
generate API keys.

1. **Settings → Subscriptions** → `default-subscription` → **Models** → add each
   MaaS resource name you want to expose:
   - `qwen3-14b-external`
   - `llama-31-70b-external`
   - `llama-scout-17b-external`
2. Ensure the subscription group includes the user who will create keys

API keys are created by the end user:

| Where                                                                                  | Use                                  |
| -------------------------------------------------------------------------------------- | ------------------------------------ |
| **Gen AI studio → AI asset endpoints → Models as a service → View → Generate API key** | Short-lived key (1 h)                |
| **Gen AI studio → API keys → Create API key**                                          | Persistent key (1–365 days or Never) |

Keys are shown **once** with prefix `sk-oai-`. Copy before closing the dialog.

CLI alternative (OpenShift token of a user in the subscription group):

```bash
curl -sk -X POST "https://maas.apps.${RHCL_ZONE_ROOT_DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-key","subscription":"default-subscription"}'
```

## Gateway access

| Resource                       | Role                                                            |
| ------------------------------ | --------------------------------------------------------------- |
| `Gateway/maas-default-gateway` | MaaS data plane (HTTPS :443)                                    |
| `HTTPRoute/qwen3-14b-external` | Path `/external-models/qwen3-14b-external` → LiteLLM upstream   |
| `HTTPRoute/maas-api-route`     | Paths `/v1/models`, `/maas-api` → `maas-api`                    |
| `Route/maas-default-gateway`   | Exposes `maas.apps.<domain>` for dashboard + external inference |

**External inference URL** (from outside the cluster):

```text
https://maas.apps.<RHCL_ZONE_ROOT_DOMAIN>/external-models/qwen3-14b-external/v1/chat/completions
```

**In-cluster URL** (apps inside the cluster):

```text
https://maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local/external-models/qwen3-14b-external/v1/chat/completions
```

> `rh-ai.apps...` is the **data-science-gateway** (dashboard OAuth), not the MaaS API
> gateway. Do not use it for inference `curl` tests.

### Optional — LoadBalancer exposure

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.example.com
bash tests/req024/scripts/expose-maas-gateway-lb.sh
```

Prefer Route `maas.apps` for dashboard compatibility. See Ansible variables
`OCP_AI_MAAS_GATEWAY_SERVICE_TYPE` and `OCP_AI_MAAS_ROUTE_HOSTNAME` in
`automation/inventories/example/group_vars/all.yml`.

## Inference test

### External `curl` (recommended)

```bash
export MAAS_EXTERNAL="https://maas.apps.${RHCL_ZONE_ROOT_DOMAIN}"
export TOKEN="sk-oai-..."   # MaaS key from dashboard — NOT the LiteLLM Secret

curl -sk -X POST "${MAAS_EXTERNAL}/external-models/qwen3-14b-external/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-14b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

The JSON `"model"` field must be the **`targetModel`** from the ExternalModel
(`qwen3-14b`), not the MaaS resource name (`qwen3-14b-external`).

**Expected:** HTTP 200 and a `chat.completion` JSON body from LiteLLM.

### In-cluster or port-forward

```bash
export MAAS_URL="https://maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local"
export MAAS_API_KEY="sk-oai-..."

curl -sk -X POST \
  "${MAAS_URL}/external-models/qwen3-14b-external/v1/chat/completions" \
  -H "Authorization: Bearer ${MAAS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

Port-forward from your workstation:

```bash
oc -n openshift-ingress port-forward svc/maas-default-gateway-data-science-gateway-class 8443:443
export MAAS_URL="https://127.0.0.1:8443"
# same curl as above against ${MAAS_URL}/external-models/...
```

### Direct LiteLLM (bypass MaaS)

Validate only the upstream Secret:

```bash
curl -sk -X POST https://maas-rhdp.apps.maas.redhatworkshops.io/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-14b","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

## Common errors

| Symptom                                                    | Cause                                                             | Fix                                                              |
| ---------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------- |
| `curl: (60) SSL certificate problem`                       | OpenShift self-signed cert                                        | Use `curl -k` / `curl -sk`                                      |
| HTTP 302 / no response                                     | `rh-ai.apps...` is dashboard OAuth                                | Use `maas.apps...`                                               |
| `{"detail":"Not Found"}`                                   | HTTPRoute missing path rewrite                                    | `bash tests/req024/scripts/patch-httproute-rewrite.sh`           |
| `Malformed API Key passed in` (401, LiteLLM JSON body)     | MaaS key forwarded to LiteLLM                                     | `bash tests/req024/scripts/patch-httproute-upstream-auth.sh`     |
| Empty 401, `x-ext-auth-reason: Authentication required`    | BBR ext_proc before Kuadrant auth, or wrong key on rewritten path | Use HTTPRoute upstream-auth patch; ensure `model` is `qwen3-14b` |
| HTTP 403 `x-ext-auth-reason: Unauthorized`                 | Revoked/expired MaaS key or user not in subscription              | Create a new key in the dashboard                                |
| `AUTH_FAILURE` / empty body                                | LiteLLM key (`sk-...`) sent instead of MaaS key (`sk-oai-...`)    | Use dashboard MaaS key in `Authorization`                        |
| HTTP 503 on `maas-api.apps...`                             | Listener hostname without OpenShift Route                         | Use `maas.apps.<domain>` instead                                 |

Re-apply patches after `maas-api` reconciles the `payload-processing` EnvoyFilter:

```bash
bash tests/req024/scripts/patch-httproute-upstream-auth.sh
bash tests/req024/scripts/patch-payload-processing-envoyfilter.sh || true
oc rollout restart deploy/maas-default-gateway-data-science-gateway-class -n openshift-ingress
```

## RHOAI Assistant integration

After the model is `Ready` and a MaaS API key exists:

```bash
export APPS_RHOAI_ENABLED=true
export APPS_RHOAI_MAAS_BASE_URL="https://maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local/external-models/qwen3-14b-external/v1"
export APPS_RHOAI_MAAS_MODEL="qwen3-14b"
export APPS_RHOAI_MAAS_API_KEY="sk-oai-..."

cd automation
ansible-playbook playbooks/apps-install.yml
```

## Notes

- `MaaSModelRef` uses `apiVersion: maas.opendatahub.io/v1alpha1` (not `models.opendatahub.io`).
- `ExternalModel.spec.endpoint` is **hostname only** — no `https://`, path, or `/v1`.
- The dashboard modal may show an internal `*.svc.cluster.local` URL; use
  `maas.apps.<domain>/external-models/...` for external clients.
- Upstream credential injection via BBR is Technology Preview; the HTTPRoute patch
  is a deliberate PoC workaround documented until the OpenShift gateway filter
  order is fixed upstream.
