# REQ 8 — Unified gateway administration console (ACM)

Demonstrates **Item 8**: one administration console for RHCL/Kuadrant gateways
across **multiple sites and public clouds**, using **Red Hat Advanced Cluster
Management (ACM)** on the hub cluster.

Full write-up: [`../req008.md`](../req008.md). Interactive walkthrough:
[`index.html`](index.html).

---

## Prerequisites

- Hub cluster with **ACM** installed (`MultiClusterHub` / `multicluster engine` Available).
- Spoke clusters imported (`ManagedCluster` → `Available`), e.g. `CCT1`, `CCT2`, Azure, GCP.
- RHCL/Kuadrant installed on each spoke (same pattern as single-lab `apps-install`).
- Your user can open the **hub** OpenShift console and switch cluster context.

```bash
# Hub — fleet health
oc get multiclusterhub -A
oc get managedcluster

# Example spoke (after switching context or from hub search)
oc get gateway,httproute,authpolicy -A
```

---

## Step-by-step — ACM / OpenShift console (hub)

1. Open the **hub** OpenShift console URL.
2. Go to **Infrastructure → Clusters** (ACM) and confirm all spokes are **Available**.
3. Use the **cluster switcher** (top bar) and select a spoke (e.g. `CCT1`).
4. Navigate **Networking → Gateways** (Gateway API) and locate `rhcl-apps-gateway`.
5. Open **HTTPRoutes** in the app namespace (e.g. `rhcl-apps`) — e.g. `banking-api-connectivity`.
6. Switch cluster context and repeat for other sites (`CCT2`, Azure, GCP) — **one console, many clusters**.
7. (Optional) **Search** → filter `kind:HTTPRoute` or `kind:AuthPolicy` → **All clusters** for a fleet-wide view.

**Expected result:** a single hub login; gateway objects visible on each site without separate cloud consoles.

Screenshots: [`manifests/screenshots/`](manifests/screenshots/README.md).

---

## Step-by-step — Terminal (hub)

1. List managed clusters:

   ```bash
   oc get managedcluster -o custom-columns=NAME:.metadata.name,AVAILABLE:.status.conditions[-1].status
   ```

2. (Optional) With `clusteradm` on the hub:

   ```bash
   clusteradm get managedclusters
   ```

3. With kubecontext on a spoke:

   ```bash
   oc get gateway rhcl-apps-gateway -n openshift-ingress
   oc get httproute banking-api-connectivity -n rhcl-apps
   oc get authpolicy -n rhcl-apps
   ```

4. Repeat step 3 on **each** site — same CR types, environment-specific hostnames.

**Expected result:** identical governance surface (`Gateway`, `HTTPRoute`, `AuthPolicy`) on every cluster; ACM proves hub visibility of the fleet.

---

## Step-by-step — Quick validation (curl, optional)

Confirm each spoke serves traffic (hostname per site):

```bash
curl -sk -o /dev/null -w "site=%{http_code}\n" \
  "https://banking-api-connectivity.<site-domain>/api/echo"
```

Expected: `200` where the route is published. The unified console administers the CRs that define those endpoints; it does not merge hostnames.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Spoke missing in console | `oc get managedcluster <name> -o yaml` → conditions; klusterlet pods on spoke |
| Cannot switch cluster in UI | RBAC on hub; `ClusterRoleBinding` for multicluster admin |
| Gateway exists on one site only | Run `apps-install` (or equivalent) on that spoke |
| Search returns no Gateway | CRD installed on spoke; user has `list` on target namespace |

---

## Files

| Path | Purpose |
|------|---------|
| [`index.html`](index.html) | PoC catalog page — step-by-step + screenshot slots |
| [`../req008.md`](../req008.md) | Requirement mapping and architecture |
| [`manifests/screenshots/`](manifests/screenshots/) | Evidence images (add PNGs here) |
