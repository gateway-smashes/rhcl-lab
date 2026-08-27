# REQ 40 manifests — AI token observability (RHCL-native)

All resources are applied with `oc apply -k tests/per-route-token-counting/manifests/`. No
`envsubst` placeholders — hostnames are resolved at runtime from cluster DNS
and Grafana datasource URLs.

Resources span four namespaces:

| Namespace | Resources |
| --- | --- |
| `rhcl-logging` | Namespace, Loki, Alloy collector |
| `kuadrant-system` | ServiceMonitor for Limitador |
| `openshift-ingress` | EnvoyFilter + Telemetry on `rhcl-apps-gateway` |
| `rhcl-grafana` | GrafanaDashboard + GrafanaDatasource CRs |

## Manifest index

| Range | File | Purpose |
| --- | --- | --- |
| `00` | `00-namespace-rhcl-logging.yaml` | Namespace `rhcl-logging` |
| `10` | `10-grafana-dashboard-ai-tokens.yaml` | GrafanaDashboard **RHCL AI Token Usage** (`authorized_hits` / `authorized_calls` / `limited_calls`) |
| `11` | `11-grafana-dashboard-ai-consumer-logs.yaml` | GrafanaDashboard **RHCL AI Consumer Access Logs** (LogQL per `x-consumer-id`) |
| `20` | `20-servicemonitor-limitador.yaml` | ServiceMonitor scraping `limitador-limitador:8080/metrics` (user-workload Prometheus) |
| `30` | `30-envoyfilter-access-log.yaml` | Lua filter + `RHCL_ACCESS` StdoutAccessLog on `rhcl-apps-gateway` |
| `31` | `31-loki.yaml` | Lightweight Loki deployment (filesystem / `emptyDir`, 7-day retention) |
| `32` | `32-alloy-gateway-logs.yaml` | Grafana Alloy: tails gateway istio-proxy logs via Kubernetes API → Loki |
| `33` | `33-grafana-loki-datasource.yaml` | GrafanaDatasource `uid: rhcl-loki` for consumer dashboard panels |
| `34` | `34-telemetry-disable-default-access-log.yaml` | Disables Istio default access log so only `RHCL_ACCESS` lines are emitted |

## Apply order

Kustomize applies resources in the order listed in
[`kustomization.yaml`](kustomization.yaml). The EnvoyFilter (`30`) and
Telemetry CR (`34`) must both be present before generating traffic — otherwise
gateway logs are either missing token metadata or duplicated.

Full runbook: [../README.md](../README.md).

Prerequisites: [REQ 41](../../installation-guide/README.md) (Grafana), [REQ 60](../../token-rate-limiting/README.md) (`TokenRateLimitPolicy`).
