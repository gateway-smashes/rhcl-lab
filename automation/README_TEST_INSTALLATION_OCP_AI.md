# OpenShift AI Test Installation

This guide installs the **OpenShift AI 3.4** lab profile required for model
serving (KServe), **Models as a Service**, **Distributed Inference with llm-d**,
Ray/distributed workloads, Llama Stack, workbenches, pipelines, model registry,
and supporting operators on top of the RHCL lab automation.

## What it installs

| Layer                               | Component                                                                                                                                                                                                                                         | Purpose                                                                                    |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | --- |
| Prerequisites (validated)           | cert-manager, Gateway API, RHCL (Kuadrant)                                                                                                                                                                                                        | Required by kserve / llm-d docs                                                            |
| GPU stack (optional)                | NFD + NVIDIA GPU Operator + `ClusterPolicy`                                                                                                                                                                                                       | Expose `nvidia.com/gpu` on worker nodes                                                    |
| llm-d prerequisite                  | Leader Worker Set Operator                                                                                                                                                                                                                        | Multi-node inference groups                                                                |
| Distributed workloads prerequisites | JobSet Operator, Red Hat build of Kueue, Custom Metrics Autoscaler                                                                                                                                                                                | Queued Ray/training jobs and WVA/KEDA scaling support                                      |
| Models as a Service prerequisites   | `openshift-ingress/maas-default-gateway`, `maas-postgres`, `maas-db-config`, Authorino listener TLS                                                                                                                                               | Required by MaaS platform reconci'liation                                                  |
| OpenShift AI                        | `rhods-operator` + `DataScienceCluster`                                                                                                                                                                                                           | Platform operator and components                                                           | '   |
| Components enabled                  | `dashboard`, `workbenches`, `aipipelines`, `kserve`, `kserve.modelsAsService`, `kserve.wva`, `ray`, `trainingoperator`, `trainer`, `kueue`, `llamastackoperator`, `modelregistry`, `trustyai`, `mlflowoperator`, `sparkoperator`, `feastoperator` | Full lab profile for AI application and model platform testing                             |
| Dashboard UI                        | `OdhDashboardConfig` with `genAiStudio: true`, `modelAsService: true`, `maasAuthPolicies: true`, and `aiAssetCustomEndpoints` / `externalProviders` enabled                                                                                       | Shows **Gen AI studio**, MaaS admin screens, and external custom endpoints                 |
| MaaS dashboard user                 | HTPasswd/LDAP user in `rhods-admins` + Route `maas.apps.<domain>`                                                                                                                                                                                 | **`kubeadmin` / `kube:admin` do not work** for the MaaS tab — see `tests/req024/README.md` |
| GPU hardware profile                | `HardwareProfile/nvidia-gpu-profile` in `redhat-ods-applications`                                                                                                                                                                                 | Exposes `nvidia.com/gpu` for workbenches, model serving, and distributed workloads         |
| Namespace                           | `rhcl-model-serving` (optional, not application-labeled)                                                                                                                                                                                          | Extra namespace for serving workloads                                                      |

The playbook does **not** deploy an `LLMInferenceService` CR — that is a
post-install step once GPUs and object storage are ready.

## Preconditions

Run the RHCL baseline first:

```bash
source automation/scripts/cluster-env.sh
cd automation
ansible-playbook playbooks/install-all.yml
# or at minimum:
# gateway_api-install + cert_manager-install + rhcl-install + apps-install
```

Cluster requirements (from Red Hat OpenShift AI 3.4 docs):

- OpenShift **4.19+** (llm-d documented for **4.20+**)
- Default **StorageClass** with dynamic provisioning
- **No OpenShift Service Mesh v2** when using llm-d
- **GPU worker nodes** when `OCP_AI_GPU_ENABLED=true`
- Pull access to `registry.redhat.io` and `redhat-operators`

## Required environment

```bash
export OCP_AI_ENABLED=true
export OCP_AI_CHANNEL=stable-3.4        # default in group_vars; do not use fast-3.4 (not in catalog)
export OCP_AI_GPU_ENABLED=true          # set false on CPU-only dev clusters
export OCP_AI_LLMD_ENABLED=true         # Leader Worker Set Operator
export OCP_AI_DISTRIBUTED_WORKLOADS_ENABLED=true
export OCP_AI_MODELS_AS_SERVICE_ENABLED=true
export OCP_AI_REQUIRE_GPU_NODES=false   # set true in ocp_ai-test.yml for strict GPU check
```

Optional overrides:

```bash
export OCP_AI_MODEL_SERVING_NAMESPACE=rhcl-model-serving
export OCP_AI_APPLICATIONS_NAMESPACE=redhat-ods-applications
export OCP_AI_LWS_OPERATOR_NAME=lws-operator   # override if OperatorHub package differs
export OCP_AI_AIPIPELINES_ARGO_WORKFLOWS_CONTROLLERS_STATE=Managed
export OCP_AI_KUEUE_STATE=Unmanaged            # Managed is rejected by the RHOAI 3.4 CRD
export OCP_AI_KSERVE_NIM_STATE=Removed         # enable only after NIM credentials/operator planning
export OCP_AI_MAAS_GATEWAY_NAME=maas-default-gateway
export OCP_AI_MAAS_DB_PASSWORD=maas-lab-password
export OCP_AI_MAAS_DB_CONNECTION_URL=postgresql://maas:maas-lab-password@maas-postgres.redhat-ods-applications.svc.cluster.local:5432/maas?sslmode=disable
```

## Run the playbook

```bash
cd automation
ansible-playbook playbooks/ocp_ai-install.yml
```

Validate (does not require `OCP_AI_ENABLED=true` — checks whatever is on the cluster):

```bash
ansible-playbook playbooks/ocp_ai-test.yml
```

Manual checks:

```bash
oc -n redhat-ods-operator get subscription rhods-operator
oc -n redhat-ods-operator get csv
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
oc -n redhat-ods-applications get deploy -l control-plane=kserve-controller-manager
oc -n redhat-ods-applications get deploy kuberay-operator kubeflow-training-operator
oc -n openshift-kueue-operator get deploy openshift-kueue-operator kueue-controller-manager
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
oc -n openshift-ingress get gateway data-science-gateway
```

## Post-install — llm-d

After `DataScienceCluster` is `Ready`:

1. Open the OpenShift AI dashboard (created by the `dashboard` component).
2. In **Settings → Cluster settings → General settings**, enable
   **Use distributed inference with llm-d by default** (optional).
3. Create an `LLMInferenceService` CR — see Red Hat docs
   [Deploy models using Distributed Inference with llm-d](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/deploy_models_using_distributed_inference_with_llm-d/).
4. For RHCL authentication on inference endpoints, configure Connectivity Link
   as described in the llm-d + RHCL integration guide.

## Notes

- The `kueue` component must be `Unmanaged` in the `DataScienceCluster`; the Red
  Hat build of Kueue Operator owns the Kueue operand.
- Models as a Service requires a PostgreSQL connection Secret named
  `maas-db-config` and a TLS-enabled Authorino listener. The role creates a
  lab PostgreSQL deployment by default; override `OCP_AI_MAAS_DB_CONNECTION_URL`
  to use a managed database.
- AI Pipelines uses the embedded Argo Workflows controllers by default. Set
  `OCP_AI_AIPIPELINES_ARGO_WORKFLOWS_CONTROLLERS_STATE=Removed` only when you
  bring your own compatible Argo Workflows installation.
- NIM integration is intentionally left `Removed` by default because it needs
  NVIDIA NGC credentials and a separate operational decision. The playbook keeps
  `OCP_AI_KSERVE_NIM_STATE` overrideable.
- The **Playground** menu item is hidden unless
  `spec.dashboardConfig.genAiStudio: true` in `OdhDashboardConfig` (default is
  `false` per [Dashboard configuration options](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/managing_resources/index)).
  The role sets this automatically; override with `OCP_AI_DASHBOARD_GEN_AI_STUDIO=false`
  to disable. Llama Stack Operator must stay `Managed` in the DSC.
- The **Models as a service** tab in **Gen AI studio → AI asset endpoints** requires
  a Route at `maas.apps.<RHCL_ZONE_ROOT_DOMAIN>` (Ansible template
  `maas-gateway-route.yml.j2` when the gateway Service is `ClusterIP`). The logged-in
  user must belong to `rhods-admins` (or another group listed in the MaaS subscription)
  and authenticate via a normal identity provider (HTPasswd/LDAP). Bootstrap accounts
  **`kubeadmin` and `kube:admin` are not supported** for this UI. Full walkthrough:
  `tests/req024/README.md` § _Dashboard — Models as a service tab_.
- **AI asset custom endpoints** (`aiAssetCustomEndpoints: true`,
  `genAiStudioConfig.aiAssetCustomEndpoints.externalProviders: true`) are enabled
  by default so Gen AI studio accepts external LiteLLM / OpenAI-compatible gateways.
  Override with `OCP_AI_DASHBOARD_AI_ASSET_CUSTOM_ENDPOINTS=false` or
  `OCP_AI_DASHBOARD_AI_ASSET_EXTERNAL_PROVIDERS=false`. Internal Route domains only
  (never broad public TLDs) via comma-separated
  `OCP_AI_DASHBOARD_AI_ASSET_CLUSTER_DOMAINS`.

## Relationship with RHCL PoC

| RHCL PoC item             | OpenShift AI item                                        |
| ------------------------- | -------------------------------------------------------- |
| `rhcl-install` (Kuadrant) | llm-d auth via Connectivity Link                         |
| `gateway_api-install`     | `data-science-gateway` Gateway (created by OpenShift AI) |
| `cert_manager-install`    | kserve + LWS prerequisite                                |
| `banking-api` mock AI     | Complementary — real inference via `LLMInferenceService` |

## Cleanup

Removes the `DataScienceCluster` and operand CRs. Operator Subscriptions are
kept unless `OCP_AI_REMOVE_OPERATORS=true`.

```bash
export OCP_AI_ENABLED=true
ansible-playbook playbooks/ocp_ai-remove.yml
```

To also remove operator Subscriptions:

```bash
export OCP_AI_REMOVE_OPERATORS=true
ansible-playbook playbooks/ocp_ai-remove.yml
```
