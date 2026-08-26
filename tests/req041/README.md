# Req 041 — Installation Guide

## Prerequisites

1. Cluster with RHCL installed (Kuadrant + Gateway API with Istio gateway controller).
2. **User-workload monitoring** enabled (`MONITORING_ENABLE_USER_WORKLOAD=true` — lab default).
3. Prometheus scraping the Gateway pod metrics (Istio integration with OpenShift monitoring).
4. **Keycloak** deployed in the `keycloak` namespace (req071 installs the RHBK Operator, Postgres, and the Keycloak CR named `rhcl` with hostname `keycloak.poc.rhcl.com.br`).

> The Grafana Operator is installed automatically by
> `01-grafana-operator-subscription.yaml` — no manual OperatorHub step is
> required.

---

## Manifests

| File | Kind | Purpose |
|---|---|---|
| `manifests/kustomization.yaml` | Kustomization | Assembles all manifests |
| `manifests/01-grafana-namespace.yaml` | Namespace | `rhcl-grafana` |
| `manifests/01-grafana-operator-subscription.yaml` | OperatorGroup + Subscription | Grafana Operator (community-operators, channel v5) |
| `manifests/02-keycloak-realm-grafana.yaml` | KeycloakRealmImport | Realm `rhcl-grafana` with OIDC client `grafana` and test users |
| `manifests/02-grafana-httproute.yaml` | HTTPRoute | Exposes Grafana via RHCL Gateway (`grafana.poc.rhcl.com.br`) |
| `manifests/02-grafana-authpolicy.yaml` | AuthPolicy | Allows anonymous access to Grafana HTTPRoute (overrides gateway deny-all) |
| `manifests/02-grafana-instance.yaml` | Grafana | Instance with Keycloak OIDC auth |
| `manifests/03-grafana-sa-clusterrole.yaml` | ClusterRoleBinding | Grants Grafana SA `cluster-monitoring-view` |
| `manifests/04-grafana-sa-token.yaml` | Secret | Long-lived SA token definition (applied in Step 3, outside kustomize) |
| `manifests/05-grafana-datasource-thanos.yaml` | GrafanaDatasource | Thanos Querier (`thanos-querier:9091`), reads bearer token from Secret |
| `manifests/06-grafana-dashboard-api-overview.yaml` | GrafanaDashboard | Throughput, latency, status codes, per-endpoint |
| `manifests/07-grafana-dashboard-api-consumers.yaml` | GrafanaDashboard | Per-consumer traffic and latency |
| `manifests/08-grafana-dashboard-authorino.yaml` | GrafanaDashboard | Authorino auth decisions, latency, per-AuthConfig |
| `manifests/09-grafana-dashboard-limitador.yaml` | GrafanaDashboard | Limitador rate-limiting, Wasm counters, policy health |
| `manifests/10-gateway-api-state-metrics.yaml` | SA + ClusterRole + ClusterRoleBinding + ConfigMap + Deployment + Service + ServiceMonitor | Gateway API state metrics (kube-state-metrics with CustomResourceState) |

---

## Supported configuration

The Kuadrant **App Developer Dashboard** (Grafana ID `21538`) and several
panels in the custom dashboards require `gatewayapi_*` state metrics that are
**not** produced by the default OpenShift kube-state-metrics instance. These
metrics are provided by a dedicated kube-state-metrics deployment configured
with the
[Kuadrant gateway-api-state-metrics](https://github.com/Kuadrant/gateway-api-state-metrics)
`CustomResourceState` configuration.

**Official reference:**
[Red Hat Connectivity Link 1.3 — Observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability)

> *"To scrape additional metrics in OpenShift, you can install a
> kube-state-metrics instance, with a custom resource configuration."*

### What `10-gateway-api-state-metrics.yaml` deploys

| Resource | Purpose |
|---|---|
| `ServiceAccount` | Identity for the dedicated kube-state-metrics pod |
| `ClusterRole` / `ClusterRoleBinding` | RBAC to list/watch Gateway API CRDs (`gateways`, `gatewayclasses`, `httproutes`, `grpcroutes`, `tcproutes`, `tlsroutes`, `udproutes`, `backendtlspolicies`) |
| `ConfigMap` | `CustomResourceState` YAML from upstream [gateway-api-state-metrics](https://github.com/Kuadrant/gateway-api-state-metrics/blob/main/config/default/custom-resource-state.yaml) |
| `Deployment` | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0` with `--custom-resource-state-only=true` |
| `Service` | Exposes ports `8080` (metrics) and `8081` (telemetry) |
| `ServiceMonitor` | Instructs user-workload Prometheus to scrape the metrics endpoint every 30 s |

### Metrics produced

The instance exposes `gatewayapi_*` metrics for all Gateway API route types.
The key metric consumed by the App Developer Dashboard is:

```promql
gatewayapi_httproute_labels{name="<route>", namespace="<ns>", service="<svc>", deployment="<deploy>"}
```

### HTTPRoute label requirement

For dashboard panels that join Istio traffic metrics with HTTPRoute metadata,
each HTTPRoute **must** carry `service` and `deployment` labels matching the
backend workload:

```bash
oc -n <namespace> label httproute <route-name> \
  service=<backend-service-name> \
  deployment=<backend-deployment-name>
```

Example:

```bash
oc -n rhcl-apps label httproute banking-api service=rhcl-backend deployment=rhcl-backend
```

> This requirement is documented in the
> [RHCL 1.3 observability guide](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/observability/rhcl-observability):
> *"HTTPRoutes must include a service and deployment label with a value that
> matches the name of the service and deployment being routed to."*

### Verify

```bash
# Pod running
oc -n rhcl-grafana get pods -l app.kubernetes.io/name=gateway-api-state-metrics

# Metrics being produced
oc -n rhcl-grafana exec deploy/gateway-api-state-metrics -- \
  wget -qO- http://localhost:8080/metrics | grep gatewayapi_httproute_labels

# Visible in Thanos (after ~60 s)
TOKEN=$(oc -n rhcl-grafana get secret rhcl-grafana-sa-token \
  -o jsonpath='{.data.token}' | base64 -d)
oc -n openshift-monitoring exec -c thanos-query deploy/thanos-querier -- \
  curl -sk "https://localhost:9091/api/v1/query?query=gatewayapi_httproute_labels" \
  -H "Authorization: Bearer ${TOKEN}"
```

---

## Install

### Step 1 — Apply all resources

Set the target hostnames and Keycloak namespace (defaults below match the
`poc.rhcl.com.br` lab; override for other environments):

```bash
export GRAFANA_HOSTNAME=${GRAFANA_HOSTNAME:-grafana.poc.rhcl.com.br}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.poc.rhcl.com.br}
export KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-keycloak}
```

Apply with `envsubst` to resolve the placeholders:

```bash
oc kustomize tests/req041/manifests/ \
  | envsubst '$GRAFANA_HOSTNAME $KEYCLOAK_HOSTNAME $KEYCLOAK_NAMESPACE' \
  | oc apply -f -
```

This creates:
- Namespace `rhcl-grafana`
- OperatorGroup + OLM Subscription for the **Grafana Operator** (community-operators, channel v5)
- `KeycloakRealmImport` in the `keycloak` namespace — realm `rhcl-grafana` with OIDC client `grafana`, realm roles (`grafana-admin`, `grafana-editor`, `grafana-viewer`), and two test users
- HTTPRoute + AuthPolicy exposing Grafana via the RHCL Gateway (`grafana.poc.rhcl.com.br`)
- Grafana instance with Keycloak OIDC authentication
- ClusterRoleBinding granting Grafana SA `cluster-monitoring-view`
- GrafanaDatasource pointing to `thanos-querier.openshift-monitoring.svc:9091` (reads bearer token from Secret — created in Step 3)
- Four GrafanaDashboard CRs
- Gateway API state metrics instance (dedicated kube-state-metrics producing `gatewayapi_*` metrics) + ServiceMonitor

### Step 2 — Wait for the Grafana Operator and Keycloak realm

```bash
oc -n rhcl-grafana get csv -l operators.coreos.com/grafana-operator.rhcl-grafana
# NAME                       DISPLAY            VERSION   PHASE
# grafana-operator.v5.x.x    Grafana Operator   5.x.x    Succeeded
```

```bash
oc -n "${KEYCLOAK_NAMESPACE}" get keycloakrealmimport rhcl-grafana-realm \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'
# True
```

### Step 3 — Create the SA token and populate the bearer token

The SA token Secret is created outside kustomize (the `commonLabels`
transformer breaks `kubernetes.io/service-account-token` secrets).
Create it, wait for Kubernetes to populate the token, then build the
bearer-token Secret that the GrafanaDatasource reads via `valuesFrom`:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: rhcl-grafana-sa-token
  namespace: rhcl-grafana
  annotations:
    kubernetes.io/service-account.name: rhcl-grafana-sa
type: kubernetes.io/service-account-token
EOF

# Wait for the token controller to populate the secret
sleep 5

TOKEN=$(oc -n rhcl-grafana get secret rhcl-grafana-sa-token \
  -o jsonpath='{.data.token}' | base64 -d)

oc -n rhcl-grafana create secret generic rhcl-grafana-bearer-token \
  --from-literal=token="Bearer ${TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

# Force the operator to re-read the secret now
oc -n rhcl-grafana annotate grafanadatasource rhcl-prometheus \
  reconcile-trigger="$(date +%s)" --overwrite
```

Verify the datasource reconciled successfully:

```bash
oc -n rhcl-grafana get grafanadatasource rhcl-prometheus \
  -o jsonpath='{.status.conditions[0].reason}'
# ApplySuccessful
```

> **If dashboards still show Unauthorized** after the above, the Grafana
> Operator may have cached the old (empty) secureJsonData. Inject the token
> directly via the Grafana API to force an update:
>
> ```bash
> DS_UID=$(oc -n rhcl-grafana get grafanadatasource rhcl-prometheus \
>   -o jsonpath='{.status.uid}')
>
> curl -sk -u rhcl-admin:rhcl-poc-2026 \
>   -X PUT "https://${GRAFANA_HOSTNAME}/api/datasources/uid/${DS_UID}" \
>   -H "Content-Type: application/json" \
>   -d "{
>     \"name\": \"Prometheus (RHCL)\",
>     \"type\": \"prometheus\",
>     \"access\": \"proxy\",
>     \"url\": \"https://thanos-querier.openshift-monitoring.svc.cluster.local:9091\",
>     \"isDefault\": true,
>     \"jsonData\": {
>       \"httpHeaderName1\": \"Authorization\",
>       \"timeInterval\": \"30s\",
>       \"tlsSkipVerify\": true
>     },
>     \"secureJsonData\": {
>       \"httpHeaderValue1\": \"Bearer ${TOKEN}\"
>     }
>   }"
> ```

---

## Verify

### Grafana instance

```bash
oc -n rhcl-grafana get grafana rhcl-grafana
oc -n rhcl-grafana get pods -l app=rhcl-grafana
oc -n rhcl-grafana get httproute grafana
```

### Datasource

```bash
oc -n rhcl-grafana get grafanadatasource rhcl-prometheus \
  -o jsonpath='{.status.conditions[0].message}'
# Datasource was successfully applied to 1 instances
```

### Dashboards

```bash
oc -n rhcl-grafana get grafanadashboard
# NAME                  AGE
# rhcl-api-overview     ...
# rhcl-api-consumers    ...
# rhcl-authorino        ...
# rhcl-limitador        ...
```

### Keycloak SSO login

```bash
echo "https://${GRAFANA_HOSTNAME}"
```

1. Click **Sign in with Keycloak** on the Grafana login page.
2. Authenticate with one of the test users:

| User | Password | Grafana role |
|---|---|---|
| `grafana-admin` | `admin123` | Admin |
| `grafana-viewer` | `viewer123` | Viewer |

3. `grafana-admin` should see **Server Admin**; `grafana-viewer` gets read-only access.

> **Troubleshooting:** if Grafana returns *"login provider not found"*,
> check the realm import status and Keycloak reachability:
>
> ```bash
> oc -n "${KEYCLOAK_NAMESPACE}" get keycloakrealmimport rhcl-grafana-realm
> oc -n rhcl-grafana logs deploy/rhcl-grafana-deployment | grep -i oauth
> ```

---

## Keycloak OIDC details

| Setting | Value |
|---|---|
| Keycloak hostname | `${KEYCLOAK_HOSTNAME}` (default `keycloak.poc.rhcl.com.br`) |
| Realm | `rhcl-grafana` |
| Client ID | `grafana` |
| Client secret | `grafana-oidc-secret` |
| Scopes | `openid profile email` |
| Realm roles | `grafana-admin`, `grafana-editor`, `grafana-viewer` |
| Role mapping (JMESPath) | `grafana-admin` → Admin, `grafana-editor` → Editor, default → Viewer |

---

## Cleanup

```bash
oc kustomize tests/req041/manifests/ \
  | envsubst '$GRAFANA_HOSTNAME $KEYCLOAK_HOSTNAME $KEYCLOAK_NAMESPACE' \
  | oc delete -f -
```

Individual resource deletion (if needed):

```bash
oc delete -n rhcl-grafana grafanadashboard rhcl-api-overview rhcl-api-consumers rhcl-authorino rhcl-limitador
oc delete -n rhcl-grafana grafanadatasource rhcl-prometheus
oc delete -n rhcl-grafana secret rhcl-grafana-bearer-token
oc delete -n rhcl-grafana grafana rhcl-grafana
oc delete -n rhcl-grafana httproute grafana
oc delete -n rhcl-grafana authpolicy grafana-anonymous
oc delete -n rhcl-grafana subscription grafana-operator
oc delete -n rhcl-grafana operatorgroup grafana-operator
oc delete -n "${KEYCLOAK_NAMESPACE}" keycloakrealmimport rhcl-grafana-realm
oc delete clusterrolebinding rhcl-grafana-cluster-monitoring-view
oc delete clusterrole gateway-api-state-metrics
oc delete clusterrolebinding gateway-api-state-metrics
oc delete namespace rhcl-grafana
```
