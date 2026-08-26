# REQ 29 — Self-service through the IDP (Internal Developer Hub)

Demo package for item 29 of the RHCL PoC. See
[`../req029.md`](../req029.md) for the full context, architecture diagram, and
the relationship with the standalone Developer Portal.

Item 29 is satisfied by **Red Hat Developer Hub (RHDH)** wired to the
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
cd ../tests && ./req029/scripts/validate.sh
```

The manual, manifest-by-manifest path (mirrors the upstream Kuadrant install
guide, including the `npm view … dist.integrity` hash substitution) is in
[`../req029.md`](../req029.md#apply).

> **Version pin:** Kuadrant Backstage plugin **v0.1.0** ↔ **RHDH 1.6**
> (Backstage 1.45.3). Bump both together.
