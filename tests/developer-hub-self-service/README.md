---
title: Developer Hub self-service
summary: Self-service API onboarding through Red Hat Developer Hub (Backstage).
category: Platform & lifecycle
status: done
---

# Developer Hub self-service

Self-service API onboarding is satisfied by **Red Hat Developer Hub (RHDH)** wired to the
**Keycloak/RHBK** realm and carrying the **Kuadrant Backstage plugin**, so
developers discover APIs, request keys and get them approved entirely
self-service, governed by their corporate identity.

## Contents

| Path | What |
|------|------|
| [`manifests/00-operator-subscription.yaml`](manifests/00-operator-subscription.yaml) | RHDH Operator (1.6) Subscription + OperatorGroup |
| [`manifests/01-rbac-cluster.yaml`](manifests/01-rbac-cluster.yaml) | `rhdh-kuadrant` ClusterRole + Binding (SA → Kuadrant CRs) |
| [`manifests/02-dynamic-plugins.yaml`](manifests/02-dynamic-plugins.yaml) | `dynamic-plugins-rhdh` ConfigMap (Kuadrant frontend + backend plugins) |
| [`manifests/03-app-config.yaml`](manifests/03-app-config.yaml) | `rhdh-app-config` ConfigMap (OIDC + permissions + catalog + k8s) |
| [`manifests/04-rbac-policy.yaml`](manifests/04-rbac-policy.yaml) | `rbac-policies` ConfigMap — group→role→permission map |
| [`manifests/05-backstage.yaml`](manifests/05-backstage.yaml) | `Backstage` CR assembling all of the above |
| [`scripts/validate.sh`](scripts/validate.sh) | Automated validation |

## Quick start

```bash
# Reproducible (recommended):
cd ../../automation
DEVELOPER_HUB_ENABLED=true ansible-playbook playbooks/developer_hub-install.yml

# Then validate:
cd ../tests && ./developer-hub-self-service/scripts/validate.sh
```

The manual, manifest-by-manifest path (mirrors the upstream Kuadrant install
guide, including the `npm view … dist.integrity` hash substitution) is in
[`../developer-hub-self-service/README.md`](../developer-hub-self-service/README.md#apply).

> **Version pin:** Kuadrant Backstage plugin **v0.1.0** ↔ **RHDH 1.6**
> (Backstage 1.45.3). Bump both together.

## Requirement context

## Requirement demonstrated

| Item | Requirement |
|------|-------------|
| **29** | **Self-service through the IDP** — developers discover, subscribe to and obtain credentials for APIs on their own, authenticated by the corporate Identity Provider, with no ticket to the platform team. |

The requirement is satisfied by standing up **Red Hat Developer Hub (RHDH)** —
Red Hat's supported build of Backstage — as the internal developer portal, wired
to the **Keycloak/RHBK realm** for authentication and carrying the **Kuadrant
Backstage plugin** so the API catalog, subscriptions and API-key lifecycle are
self-service inside the same portal that already hosts the org's software
catalog, golden-path templates and TechDocs.

> **"IDP" here means Identity Provider AND Internal Developer Portal — the two
> meanings converge.** A developer signs in to RHDH with their corporate
> identity (Keycloak → OIDC), and their Keycloak **group** (`api-consumers`,
> `api-owners`, `api-admins`) maps to an RHDH RBAC role that governs what they
> can do: browse products, request keys, publish products, approve requests.
> No platform-team involvement in the request path.

---

## Why RHDH (and not only the standalone Developer Portal from req0XX)

The PoC provides a purpose-built **Developer Portal** (its own repo,
`hodrigohamalho/rhcl-developer-portal`, Quarkus + React) that covers the same consumer flow. RHDH is the answer to a
**different** customer question: banks that have *already standardised on an
Internal Developer Platform* want API self-service to live **inside that
platform**, next to their services, CI, docs and scorecards — not in a separate
API-only portal.

| | Standalone Developer Portal (`rhcl-developer-portal` repo) | Red Hat Developer Hub (this item) |
|---|---|---|
| Scope | APIs only | Whole IDP: software catalog, templates, TechDocs, plugins |
| Auth | Keycloak (OIDC) | Keycloak (OIDC) — same realm |
| API management | Native (bespoke UI) | Kuadrant Backstage plugin |
| Best when | Customer wants a focused API portal | Customer already runs / wants Backstage |

Both are valid answers; RHDH is the one that satisfies **"self-service through
the customer's IDP"** when the customer's IDP *is* Backstage.

---

## Architecture

```
   Corporate user
        │  OIDC (groups: api-consumers / api-owners / api-admins)
        ▼
   Keycloak / RHBK  ──────────────┐
        │ realm: rhcl             │ group → RHDH RBAC role
        ▼                         ▼
   Red Hat Developer Hub (Backstage 1.45.3, RHDH 1.6)
        │  Kuadrant Backstage plugin (frontend + backend-dynamic)
        │    - browse APIProducts
        │    - request an API key (creates APIKey CR)
        │    - owners approve requests
        ▼
   Kuadrant CRs on the cluster (via in-cluster ServiceAccount RBAC)
        devportal.kuadrant.io: APIProduct, APIKey
        extensions.kuadrant.io: PlanPolicy
        kuadrant.io:  Auth/RateLimit/DNS/TLS Policy
        gateway.networking.k8s.io: Gateway, HTTPRoute
        ▼
   RHCL Gateway enforces the key the developer just minted
```

The **custom RHCL console** (our OpenShift dynamic plugin) links to this RHDH
instance via a new **"Internal Developer Hub"** sidebar item — see
[Console link](#console-link-internal-developer-hub) below.

---

## Components installed

| Component | What | Source |
|-----------|------|--------|
| RHDH Operator | Installs and manages Backstage instances | `rhdh` operator, `redhat-operators` catalog |
| `Backstage` CR | The RHDH instance (`rhdh` in `rhcl-developer-hub` ns) | `automation/roles/developer_hub` |
| Kuadrant plugin (frontend) | `@kuadrant/kuadrant-backstage-plugin-frontend@v0.1.0` | npm, loaded as a dynamic plugin |
| Kuadrant plugin (backend) | `@kuadrant/kuadrant-backstage-plugin-backend-dynamic@v0.1.0` | npm, loaded as a dynamic plugin |
| `dynamic-plugins-rhdh` ConfigMap | Declares the two Kuadrant plugins + routes/mount points | role-rendered |
| `rhdh-app-config` ConfigMap | OIDC auth (Keycloak), permissions, catalog rules, in-cluster k8s | role-rendered |
| `rbac-policies` ConfigMap | `rbac-policy.csv` — group→role→permission map | role-rendered |
| `rhdh-kuadrant` ClusterRole + Binding | Lets the RHDH ServiceAccount read/write Kuadrant CRs | role-rendered |

> **Version pin:** Kuadrant plugin **v0.1.0** is tested against **RHDH 1.6**
> (Backstage 1.45.3) per the [Kuadrant install guide](https://docs.kuadrant.io/1.4.x/kuadrant-backstage-plugin/docs/installation/).
> The role installs the RHDH 1.6 operator channel accordingly. Bump both
> together when Kuadrant certifies a newer pair.

---

## Console link ("Internal Developer Hub")

The RHCL custom console gets a sidebar item that opens the customer's RHDH,
mirroring the existing external **Developer Portal** link. It is **opt-in and
runtime-configured** — the item is hidden unless the URL is set, so a customer
who runs their own RHDH just points the link at it.

`custom-rhcl-console-config` ConfigMap (namespace `custom-rhcl-console`):

```yaml
data:
  # Existing external portal link (unchanged)
  developerPortalUrl: https://developer-portal.example.com
  # req029 — Internal Developer Hub (RHDH). Unset ⇒ nav item hidden.
  internalDeveloperHubUrl: https://backstage-rhdh-rhcl-developer-hub.apps.<cluster>
```

Implementation (custom-rhcl-console repo):
- `src/utils/pluginConfig.ts` — `internalDeveloperHubUrl?: string`
- `src/feature-flags/internalDeveloperHubFlag.ts` — flag `INTERNAL_DEVELOPER_HUB_URL_PRESENT`
- `src/components/developer-hub/InternalDeveloperHubRedirect.tsx` — the redirect landing
- `console-extensions.json` — flag hook + nav item + route, both gated on the flag

The `developer_hub` role sets `internalDeveloperHubUrl` on the ConfigMap
automatically after the Backstage Route is up, so the link "just appears".

---

## Manifests (reference render)

Rendered reference copies live under [`developer-hub-self-service/manifests/`](req029/). They are the
same objects `automation/roles/developer_hub` templates and applies.

| File | Resource |
|------|----------|
| [`developer-hub-self-service/manifests/00-operator-subscription.yaml`](developer-hub-self-service/manifests/00-operator-subscription.yaml) | RHDH Operator `Subscription` + `OperatorGroup` |
| [`developer-hub-self-service/manifests/01-rbac-cluster.yaml`](developer-hub-self-service/manifests/01-rbac-cluster.yaml) | `rhdh-kuadrant` ClusterRole + ClusterRoleBinding |
| [`developer-hub-self-service/manifests/02-dynamic-plugins.yaml`](developer-hub-self-service/manifests/02-dynamic-plugins.yaml) | `dynamic-plugins-rhdh` ConfigMap (Kuadrant plugins) |
| [`developer-hub-self-service/manifests/03-app-config.yaml`](developer-hub-self-service/manifests/03-app-config.yaml) | `rhdh-app-config` ConfigMap (OIDC + permissions + k8s) |
| [`developer-hub-self-service/manifests/04-rbac-policy.yaml`](developer-hub-self-service/manifests/04-rbac-policy.yaml) | `rbac-policies` ConfigMap (`rbac-policy.csv`) |
| [`developer-hub-self-service/manifests/05-backstage.yaml`](developer-hub-self-service/manifests/05-backstage.yaml) | `Backstage` CR wiring all of the above |

---

## Apply

### Recommended — Ansible (reproducible)

```bash
cd automation
# opt-in: the role short-circuits unless enabled
export DEVELOPER_HUB_ENABLED=true
# RHDH needs the Keycloak realm from rhbk-install (issuer + client)
ansible-playbook playbooks/developer_hub-install.yml
```

The role: installs the operator, creates the OIDC client in Keycloak, resolves
the plugin integrity hashes with `npm view`, renders the four ConfigMaps + the
ClusterRole/Binding + the `Backstage` CR, waits for the Route, and sets
`internalDeveloperHubUrl` on `custom-rhcl-console-config`.

### Manual (matches the Kuadrant docs, for auditing)

```bash
NS=rhcl-developer-hub
oc new-project "$NS"

# 1. Operator
oc apply -f developer-hub-self-service/manifests/00-operator-subscription.yaml

# 2. Cluster RBAC for the RHDH ServiceAccount to reach Kuadrant CRs
oc apply -f developer-hub-self-service/manifests/01-rbac-cluster.yaml

# 3. Resolve integrity hashes and substitute them into the dynamic-plugins CM
FE=$(npm view @kuadrant/kuadrant-backstage-plugin-frontend@v0.1.0 dist.integrity)
BE=$(npm view @kuadrant/kuadrant-backstage-plugin-backend-dynamic@v0.1.0 dist.integrity)
sed -e "s|__FRONTEND_INTEGRITY__|$FE|" -e "s|__BACKEND_INTEGRITY__|$BE|" \
    developer-hub-self-service/manifests/02-dynamic-plugins.yaml | oc apply -n "$NS" -f -

# 4. app-config (edit the OIDC issuer/clientId first) + rbac policy
oc apply -n "$NS" -f developer-hub-self-service/manifests/03-app-config.yaml
oc apply -n "$NS" -f developer-hub-self-service/manifests/04-rbac-policy.yaml

# 5. The Backstage instance
oc apply -n "$NS" -f developer-hub-self-service/manifests/05-backstage.yaml
```

---

## Validate

```bash
./developer-hub-self-service/scripts/validate.sh
```

The script checks:

1. RHDH operator CSV is `Succeeded`.
2. `Backstage/rhdh` reports its Deployment Available and the Route answers 200.
3. The Kuadrant dynamic plugins loaded (frontend asset + backend health).
4. The `rhdh-kuadrant` ClusterRole/Binding exist and the SA can `list`
   `apiproducts.devportal.kuadrant.io`.
5. `internalDeveloperHubUrl` is set on `custom-rhcl-console-config`.

Manual smoke (the actual self-service story):

1. Open the RHDH Route → **Sign in** with Keycloak (e.g. `alice`).
2. Left nav → **Kuadrant** → browse **API Products** (banking-api etc.).
3. Open banking-api → **Request access** → an `APIKey` CR is created.
4. As an owner/admin, **approve** the request in the same UI.
5. Copy the issued key and call the gateway — the RHCL Gateway enforces it.

---

## Expected evidence

- RHDH Route returns 200 and the top-bar shows the signed-in Keycloak identity.
- A **Kuadrant** entry is in the RHDH sidebar; **API Products** lists the same
  `APIProduct`s the RHCL console shows.
- Requesting access creates `apikeys.devportal.kuadrant.io` in the API namespace
  (visible via `oc get apikey -A` and in the RHCL console **API Keys** page).
- The RHCL console shows an **Internal Developer Hub** sidebar item that opens
  this RHDH.

---

## Success criteria

- [ ] A developer authenticated **only** through Keycloak can discover an API,
      obtain a key and call it — with no platform-team ticket.
- [ ] Keycloak group governs capability (consumer vs owner vs admin) via RHDH RBAC.
- [ ] The API-key lifecycle (request → approve → use → revoke) is entirely
      inside RHDH, backed by real Kuadrant CRs.
- [ ] The RHCL console links to the customer's RHDH when configured.

---

## Known limitations

- **Plugin maturity:** the Kuadrant Backstage plugin is **v0.1.0** — a preview.
  Treat the exact route/mount-point config as version-specific; re-verify
  against the plugin release the customer pins.
- **Version lock-step:** plugin v0.1.0 ↔ RHDH 1.6 (Backstage 1.45.3). Mismatched
  RHDH majors can fail to load the dynamic plugin.
- **`auth.environment: development` in the reference app-config** is the
  Kuadrant guide's quickstart posture. For a production BB deployment switch to
  `production`, drop the `guest` provider, and bind groups to roles strictly
  (remove the `guest → api-admin` line from `rbac-policy.csv`).
- **RBAC subject is the namespace `default` ServiceAccount** per the upstream
  guide; a hardened install uses a dedicated SA. The role parameterises this.
- **Integrity hashes** must be fetched at install time (`npm view … dist.integrity`)
  — they are not hard-coded in the manifests so a re-published patch of the same
  version doesn't silently fail the checksum.
- **The Kuadrant backend plugin needs an explicit `serviceAccountToken`.**
  `authProvider: serviceAccount` alone makes the backend crash-loop with
  `Missing required config value at
  kubernetes.clusterLocatorMethods[0].clusters[0].serviceAccountToken`.
  The role mints a 1-year SA token, stores it in Secret `rhdh-k8s-token`
  (key `K8S_SA_TOKEN`), references it as `${K8S_SA_TOKEN}` in app-config,
  and adds the secret to the Backstage `extraEnvs.secrets`. Validated
  2026-07-10 on cluster-mck9f — RHDH `1/1`, 0 restarts, plugin logs show
  `registering kuadrant apiproduct entity provider`.
- **RHDH 1.6 Route host is in `.status.ingress[0].host`, not `.spec.host`**,
  and the pod label is `rhdh.redhat.com/app` (not `app.kubernetes.io/*`).
  The role + validate.sh read the status host + the correct label.
- **OIDC sign-in needs three things RHDH doesn't set by default** (all
  validated on cluster-mck9f 2026-07-10):
  1. `signInPage: oidc` — else RHDH renders its built-in **GitHub** card
     and clicking it 404s with `No auth provider registered for 'github'`.
  2. `auth.session.secret` — else the OIDC OAuth flow errors
     `authentication requires session support` on `/api/auth/oidc/start`.
     The role generates it once and preserves it across re-runs.
  3. The Keycloak client's **redirect URI must be the real Route host**
     (`https://<subdomain>.<apps-domain>/*`), which for
     `route.subdomain: rhdh` is `rhdh.apps.<cluster>` — NOT
     `backstage-<instance>-<subdomain>-<ns>`. The role re-syncs the
     client redirect after the Route is admitted.
- **Branding is generic (`ACME — Internal Developer Hub`) by default** via
  `DEVELOPER_HUB_APP_TITLE` — set it to the customer's name per engagement.
- **Sign-in needs the user in the catalog (or the demo bypass).** After a
  successful Keycloak login RHDH runs the sign-in resolver, which by
  default requires a matching `User` entity in the Backstage catalog —
  without one the login fails "unable to resolve user identity". The lab
  doesn't ingest Keycloak users, so the role sets
  `dangerouslyAllowSignInWithoutUserInCatalog: true` on the resolver AND
  adds explicit `user:default/<name> → role` bindings in
  `rbac-policy.csv` (alice→admin, bob/carol→consumer) so RBAC still
  gates capability. **Production path:** ingest users + groups with the
  Keycloak catalog backend module (`@backstage-community/plugin-catalog-backend-module-keycloak`),
  drop the dangerous flag, and rely on the `group:default/* → role`
  bindings already in the policy.

---

## Relationship with other requirements

- **req018 (Cost Monitoring)** and the API Products / Plans / Keys the Kuadrant
  plugin surfaces are the same CRs the RHCL console renders.
- Complements the **standalone Developer Portal** (`hodrigohamalho/rhcl-developer-portal`) — same
  Keycloak realm, different portal surface; a customer picks one.
- Auth realm comes from **`rhbk-install`** (Keycloak) — the `developer_hub` role
  depends on it for the OIDC issuer + client.

## References

- [Kuadrant Backstage Plugins — install guide](https://docs.kuadrant.io/1.4.x/kuadrant-backstage-plugin/docs/installation/)
- [Installing dynamic plugins in Red Hat Developer Hub 1.4](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.4/html/installing_and_viewing_plugins_in_red_hat_developer_hub/index)
- Console link implementation: `custom-rhcl-console` — `internalDeveloperHubUrl`.
