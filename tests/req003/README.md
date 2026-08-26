# REQ 03 — Native HPA on the Gateway API data plane (PoC)

Static HTML page that demonstrates the native horizontal Pod autoscaling
primitive (`HorizontalPodAutoscaler` from `autoscaling/v2`). The target
is the **Gateway API data plane** —
`Deployment/rhcl-apps-gateway-istio` in `openshift-ingress`, the
workload that the OpenShift ingress-managed Istio controller provisions
for the connectivity `Gateway rhcl-apps-gateway`. Generating load
against the gateway's public hostname is enough to drive its CPU above
the configured budget and force the HPA to scale.

See `../req003.md` for the requirement context.

## Files

- [index.html](index.html) — single-file PoC console with an in-browser
  load generator and `oc`/`kubectl` blocks ready to copy.
- [manifests/hpa-gateway.yaml](manifests/hpa-gateway.yaml) — the
  `HorizontalPodAutoscaler` itself (CPU `200m` average value + memory
  `384Mi` average value, 2→6 replicas, with `behavior` tuned to scale up
  fast and down slow).

## Why scale the gateway, not the applications

The requirement asks for a native horizontal autoscaler **on the
solution**. In RHCL the solution is the gateway: every API call from a
real client first hits the gateway data plane, so it is also the first
component to saturate. Backends like `banking-api-v1` already get scaled
behind the gateway whenever the platform team needs to — that is a
separate, application-level concern. Putting the HPA on the gateway
proves the native scaling primitive against the component that
materializes the requirement.

## Why CPU as `AverageValue`

The Istio proxy container that runs in the gateway pod may or may not
ship with `resources.requests.cpu` defined, depending on how the cluster
was bootstrapped. An HPA configured with `type: Utilization` divides
`currentUsage / requests.cpu` — if `requests.cpu` is empty, the HPA
sits at `<unknown>/...` and never reacts.

`type: AverageValue` reads the absolute CPU from `metrics.k8s.io` and
triggers when the per-pod average crosses an absolute budget (`200m`
here). It works regardless of whether the gateway pod template carries
requests, which keeps the PoC portable across clusters.

If your cluster does pin `requests.cpu` on the gateway pod and you want
percentage-based targets, switch the metric block to:

```yaml
- type: Resource
  resource:
    name: cpu
    target:
      type: Utilization
      averageUtilization: 60
```

## Prerequisites

1. **OpenShift monitoring stack active** (default since 4.x) — provides
   the `metrics.k8s.io` API the HPA consumes. On vanilla Kubernetes,
   install `metrics-server`.
2. Connectivity `Gateway rhcl-apps-gateway` already reconciled by the
   automation in `automation/roles/apps`, so
   `Deployment/rhcl-apps-gateway-istio` exists in `openshift-ingress`.
3. `oc` authenticated on the cluster with permission to create HPAs in
   `openshift-ingress` (cluster admin or a role that grants
   `autoscaling/horizontalpodautoscalers` on that namespace).

## Apply on the cluster

```bash
# Create the HPA targeting the Gateway data plane Deployment.
oc apply -f tests/req003/manifests/hpa-gateway.yaml

# Initial checks.
oc -n openshift-ingress get hpa rhcl-apps-gateway
oc -n openshift-ingress describe hpa rhcl-apps-gateway
oc -n openshift-ingress get pods \
  -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway
```

The first HPA read may show `<unknown>/200m` for ~30s until
`metrics-server` collects enough samples — this is normal.

## How to run the page

The page only fires `fetch()` against the gateway hostname, so any
local HTTP port works:

```bash
# from the repo root
python3 -m http.server 8080 --directory tests/req003
# open http://localhost:8080
```

When served by the tests container (`tests/Dockerfile`), `env.json`
exposes `RHCL_ZONE_ROOT_DOMAIN` and the page pre-fills the *Via
gateway* preset.

## How to use the page

The page has two sides:

1. **Browser side (load generator).**
   - Pick *Via gateway* (default and the one that exercises the
     gateway data plane). The *Backend direto* preset is kept for
     comparison — it bypasses the gateway and will **not** drive the
     HPA, since the HPA watches the gateway pods.
   - The default path is `/api/v1/accounts/summary` (a cheap idempotent
     endpoint behind the gateway).
   - Set **concurrency** (parallel workers) and **duration** (seconds).
     Typical values to cross `200m` average CPU on the gateway pod:
     100 workers, 180s — the gateway proxy is light per request, so it
     needs more concurrency than an application backend would.
   - Click **Start load**. The log shows RPS, average latency, and
     error counts in 5s windows. **Stop** drains the workers.
2. **Cluster side (authoritative).**
   - The *oc / kubectl* blocks at the bottom of the page are the source
     of truth. Each one has a **Copy** button:
     - `oc -n openshift-ingress get hpa rhcl-apps-gateway -w` — watch
       the `TARGETS` column move and `REPLICAS` climb up to the cap
       (`6`).
     - `oc -n openshift-ingress get pods -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway -w`
       — watch new gateway pods reach `Running`.
     - `oc -n openshift-ingress describe hpa rhcl-apps-gateway` —
       confirms `SuccessfulRescale` events and which metric fired.
     - `oc -n openshift-ingress adm top pods -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway`
       — direct read from `metrics.k8s.io`, useful to correlate with
       what the HPA saw.

## What counts as success

With load running for ~2 minutes:

```text
NAME                REFERENCE                            TARGETS                   MINPODS   MAXPODS   REPLICAS
rhcl-apps-gateway   Deployment/rhcl-apps-gateway-istio   cpu: 280m/200m, mem: …    2         6         6
```

And in the HPA events:

```text
Type    Reason             Age   Message
Normal  SuccessfulRescale  90s   New size: 4; reason: cpu resource above target
Normal  SuccessfulRescale  60s   New size: 6; reason: cpu resource above target
```

After the load stops, `TARGETS` falls back into idle range within ~30s.
Because of `scaleDown.stabilizationWindowSeconds: 300`, `REPLICAS` only
starts shrinking 6→2 (capped at `-1` pod per minute) after 5 minutes
without pressure — intentional, to avoid flapping in production.

## Cleanup

```bash
oc delete -f tests/req003/manifests/hpa-gateway.yaml
```

The gateway controller will keep the data plane Deployment running with
whatever replica count it normally manages.

## Notes

- **Why CPU + memory?** Envoy/Istio proxy memory tends to grow slowly
  and rarely fires the HPA — the practical trigger is CPU. The memory
  metric is kept as a safety net against connection or buffer leaks.
- **Coexistence with the controller.** OpenShift's Gateway API
  controller respects external replica controllers on its provisioned
  Deployments: it sets a baseline at creation but does not fight an HPA
  afterwards. If you see the controller resetting replicas, check the
  installed Sail / OSSM version — versions older than the Gateway API
  GA in OpenShift do not support external scaling reliably.
- **Reusing the manifest.** The same template applies to any other
  `Gateway` published by the solution: change `scaleTargetRef.name` to
  the Deployment that controller produces for that gateway (the naming
  convention is `<gateway-name>-<gatewayClassName>`).
