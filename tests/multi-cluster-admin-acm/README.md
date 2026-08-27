---
title: Unified gateway administration (ACM)
summary: Administer gateways across clusters from a single pane with Red Hat Advanced Cluster Management.
category: Platform & lifecycle
status: in-progress
---

# REQ 8 — Unified gateway administration console (ACM)

Demonstrates **Item 8**: one administration console for RHCL/Kuadrant gateways
across **multiple sites and public clouds**, using **Red Hat Advanced Cluster
Management (ACM)** on the hub cluster.

Full write-up: [`../multi-cluster-admin-acm/README.md`](../multi-cluster-admin-acm/README.md). Interactive walkthrough:
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
| [`../multi-cluster-admin-acm/README.md`](../multi-cluster-admin-acm/README.md) | Requirement mapping and architecture |
| [`manifests/screenshots/`](manifests/screenshots/) | Evidence images (add PNGs here) |

## Requirement context

## Requirement

| Item | Requirement |
|------|-------------|
| **8** | Provide a **single administration console** for gateways deployed across **multiple sites** and **public cloud providers**. |

This item is **control-plane / platform** scope — it is not implemented inside the sample banking apps. The PoC satisfies it with **Red Hat Advanced Cluster Management (ACM)** on a **hub cluster**, managing RHCL/Kuadrant objects on **spoke clusters** (`CCT1`, `CCT2`, Azure, Google Cloud) from one UI.

---

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │  Hub — ACM / multicluster engine      │
                    │  OpenShift console (All clusters)     │
                    │  Search · Policies · GitOps (opt.)    │
                    └──────────────┬────────────────────────┘
                                   │ klusterlet / ManagedCluster
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
   ┌───────────┐           ┌───────────┐           ┌───────────┐
   │ CCT1      │           │ CCT2      │           │ Azure     │
   │ on-prem   │           │ on-prem   │           │ public    │
   │ Gateway   │           │ Gateway   │           │ Gateway   │
   │ HTTPRoute │           │ HTTPRoute │           │ HTTPRoute │
   │ AuthPolicy│           │ AuthPolicy│           │ AuthPolicy│
   └───────────┘           └───────────┘           └───────────┘
                                   │
                                   ▼
                           ┌───────────┐
                           │ GCP       │
                           │ public    │
                           │ Gateway … │
                           └───────────┘
```

**What the operator sees in one place**

| Object (per spoke) | Why it matters |
|--------------------|----------------|
| `Gateway` | Edge listener / TLS termination |
| `HTTPRoute` | Hostname + path → backend |
| `AuthPolicy` / `RateLimitPolicy` / `DNSPolicy` | Kuadrant governance |
| `ManagedCluster` | Fleet health and version |

Reference topology: [`labs/README.md`](../labs/README.md) (*Full BB Lab* / *Full RH Lab*).

---

## How ACM satisfies the requirement

| Capability | PoC usage |
|------------|-----------|
| **Fleet inventory** | All managed clusters listed with status (Available / Unavailable) |
| **Console cluster switcher** | Browse `Gateway`, `HTTPRoute`, `AuthPolicy` on any spoke without separate logins |
| **Global search** | Find the same `HTTPRoute` name across namespaces/clusters |
| **Policy / GitOps (optional)** | Propagate baseline Kuadrant policies to every site from the hub |

ACM is the **single pane of glass**. Each spoke still runs its own RHCL data plane; the hub does not terminate customer traffic.

---

## Evidence pack (screenshots)

Save captures under [`multi-cluster-admin-acm/manifests/screenshots/`](multi-cluster-admin-acm/manifests/screenshots/README.md). The interactive page [`multi-cluster-admin-acm/index.html`](multi-cluster-admin-acm/index.html) embeds the same filenames.

| File | What to capture |
|------|-----------------|
| `01-acm-fleet-overview.png` | ACM **Infrastructure → Clusters** (or **Fleet → Clusters**) with all spokes |
| `02-console-cluster-switcher.png` | OpenShift console top bar — cluster dropdown showing hub + spokes |
| `03-gateway-all-clusters-search.png` | **Search** (or **Observe → Search**) for `kind:Gateway` across clusters |
| `04-httproute-spoke-example.png` | `HTTPRoute banking-api-connectivity` on one spoke (YAML or list view) |
| `05-authpolicy-spoke-example.png` | `AuthPolicy` on the same spoke |
| `06-multicloud-topology.png` | Optional — diagram or lab slide tying sites to cloud providers |

Paste screenshots in the chat and ask for captions — filenames and alt text will be aligned to this table.

---

## Related PoC material

| Topic | Location |
|-------|----------|
| Multi-cluster lab target | [`labs/README.md`](../labs/README.md) |
| DNS across clouds (Req 9) | [`multi-cloud-dns/README.md`](multi-cloud-dns/README.md) |
| Per-cluster RHCL console plugin (single cluster) | [`custom-rhcl-console/SPECIFICATION.md`](../custom-rhcl-console/SPECIFICATION.md) |
| Sprint 3 multicloud validation | [`sprint3/README.md`](../sprint3/README.md) |

---

## Out of scope for this item

- Replacing ACM with a custom multi-cluster UI (see `custom-rhcl-console` non-goal: multi-cluster aggregation in v1).
- Centralized metrics/logging federation (separate observability requirements).
