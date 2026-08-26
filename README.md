<div align="center">

# RHCL Lab

**A one-command, open-source reference lab for [Red Hat Connectivity Link](https://docs.kuadrant.io) (RHCL / Kuadrant).**

Stand up a complete API **and** AI gateway environment — policies, demo apps, a
developer portal, observability, and an opinionated console — on a fresh
OpenShift cluster, then explore every capability from a catalog of runnable
walkthroughs.

![OpenShift 4.19+](https://img.shields.io/badge/OpenShift-4.19%2B-EE0000)
![Kuadrant / RHCL](https://img.shields.io/badge/Kuadrant-RHCL-004080)
![Ansible](https://img.shields.io/badge/Ansible-automation-1A1918)
![License Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-3DA639)

</div>

---

## Why this exists

Red Hat Connectivity Link is a powerful engine — Gateways, HTTPRoutes,
AuthPolicies, RateLimitPolicies, TokenRateLimitPolicies, DNS and TLS — but
seeing it all work together usually means assembling a dozen moving parts by
hand. **RHCL Lab does the assembly for you.** One Ansible run turns a bare
OpenShift cluster into a working API-management and AI-gateway platform, with
realistic demo applications, tiered plans, a self-service portal, full
observability, and a browsable catalog of feature walkthroughs you can run and
read.

It is designed for the clusters Red Hat field teams already have — a fresh
sandbox or self-provisioned OpenShift cluster with cluster-admin — and it is
fully region-agnostic: no customer names, private domains, or environment
specifics anywhere in the tree.

## What gets deployed

`install-all.yml` reconciles the whole stack in order; each layer is also a
standalone playbook you can run on its own.

| Layer | What it installs |
|---|---|
| **Gateway** | Gateway API + Istio (Sail/OSSM), the Kuadrant / RHCL operator |
| **Certificates & DNS** | cert-manager, a Let's Encrypt `ClusterIssuer`, and managed DNS for a delegated zone (AWS Route 53 · Azure DNS · Google Cloud DNS) |
| **Identity** | Red Hat build of Keycloak (OIDC/JWT issuer for the demo APIs) |
| **Demo apps** | `banking-api` (REST + gRPC + WebSocket + an OpenAI-compatible AI surface), `pix-api`, `ledger-api`, and a `mobile-bank` frontend |
| **Policies** | AuthPolicies (API key + JWT), RateLimitPolicies, tiered **PlanPolicy** (gold/silver/bronze), **TokenRateLimitPolicy** for AI, DNSPolicy, TLSPolicy |
| **Observability** | user-workload monitoring, Grafana dashboards, Tempo tracing, access-log pipelines |
| **Console** | the [**Kuadrant Console**](https://github.com/gateway-smashes/kuadrant-console) OpenShift dynamic plugin — an opinionated view of RHCL |
| **Developer portal** | Red Hat Developer Hub (Backstage) with self-service API keys |
| **AI gateway** | an MCP gateway and a Model-as-a-Service surface, governed by token budgets |
| **Tests catalog** | an in-cluster catalog serving the runnable walkthroughs in [`tests/`](tests/) |

## Architecture

```
                       ┌──────────────── OpenShift cluster ────────────────┐
   client / mobile-bank│                                                    │
        │              │   ┌─ Gateway API + Istio edge ─┐   Kuadrant / RHCL │
        └── HTTPS ──────────►  AuthPolicy · RateLimit ·  │◄── operators      │
                       │   │  TokenRateLimit · DNS · TLS │   reconcile CRs    │
                       │   └──────────────┬─────────────┘                    │
                       │        ┌─────────┼──────────┬─────────────┐         │
                       │        ▼         ▼          ▼             ▼         │
                       │   banking-api  pix-api   ledger-api   AI / MaaS     │
                       │        │                                            │
                       │   Keycloak (OIDC) · Grafana · Tempo · Dev Hub ·     │
                       │   Kuadrant Console plugin                           │
                       └────────────────────────────────────────────────────┘
```

Everything is declarative: the apps and every policy are plain Kubernetes /
Gateway API / Kuadrant custom resources, rendered by the Ansible roles and
reconciled by the operators.

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift | **4.19+**, with `cluster-admin` (a fresh Red Hat sandbox or self-provisioned cluster is ideal) |
| `oc` CLI | logged in to the target cluster |
| `ansible-core` | 2.15+ with the `kubernetes.core` collection |
| A DNS provider | AWS Route 53 · Azure DNS · Google Cloud DNS — a **delegated zone** you control, for managed DNS + Let's Encrypt |
| Provider credentials | e.g. AWS access key/secret, kept in an **un-committed** secrets file (see below) |

> The lab targets the standard path — OpenShift Route + Let's Encrypt + Kuadrant
> DNSRecord. It does not require any corporate DNS appliance or internal PKI.

## Quick start

```bash
git clone https://github.com/gateway-smashes/rhcl-lab.git
cd rhcl-lab/automation

# 1. Point at your cluster
oc login <your-cluster-api-url>

# 2. Set the lab coordinates (DNS provider, delegated zone, Let's Encrypt email)
export RHCL_DNS_PROVIDER=aws
export RHCL_ZONE_ROOT_DOMAIN=lab.example.com          # your delegated zone
export LETSENCRYPT_EMAIL=you@example.com

# 3. Put provider credentials in an un-committed secrets file
cp scripts/cluster-secrets.sh.example ~/cluster-secrets.sh   # fill in AWS keys, etc.
source ~/cluster-secrets.sh

# 4. Bring the whole environment up
ansible-playbook -i inventories/example playbooks/install-all.yml
```

Full variable reference, the granular step-by-step sequence, and cluster
auto-discovery live in **[`automation/README.md`](automation/README.md)**.

Credentials never enter the repository — the secrets file above is git-ignored,
and every policy/app Secret is rendered from a variable, never checked in.

## Repository layout

| Path | What's in it |
|---|---|
| [`automation/`](automation/) | The Ansible roles + playbooks that install everything, plus the full variable reference |
| [`apps/`](apps/) | Source for the demo applications (`banking-api`, `pix-api`, `ledger-api`, `mobile-bank`) |
| [`tests/`](tests/) | The runnable feature walkthroughs — one directory per capability (`reqNNN`), each with manifests, scripts, and a written guide |
| [`deploy/`](deploy/) | Kustomize bases/overlays for deploying the demo backends directly |
| [`docs/`](docs/) | Supporting documentation |

## The walkthrough catalog

The heart of the lab is [`tests/`](tests/): dozens of self-contained
walkthroughs, each demonstrating one RHCL capability end to end — API-key and
JWT auth, per-plan and per-token rate limiting, mTLS, gRPC and WebSocket
routing, multi-site traffic, DNS and TLS policy, tracing, cost monitoring, MCP,
and the AI-gateway token governance. Every one ships its manifests, a
deploy/validate script, and a readable explanation. The **tests catalog** role
serves them in-cluster as a browsable site.

## Companion projects

Open source alongside this lab in the [**gateway-smashes**](https://github.com/orgs/gateway-smashes/repositories) org:

| Project | What it is |
|---|---|
| [**kuadrant-console**](https://github.com/gateway-smashes/kuadrant-console) | The OpenShift Console dynamic plugin this lab deploys — API products, operational dashboards, an AI-gateway lens, and MCP |
| [**rhcl-developer-portal**](https://github.com/gateway-smashes/rhcl-developer-portal) | A self-service developer portal — developers browse API products, subscribe to a plan, get a key and watch their own usage, all governed by RHCL |
| [**maas-external-model**](https://github.com/gateway-smashes/maas-external-model) | Registers a real external LLM with OpenShift AI Models-as-a-Service — the model the RHCL AI gateway governs |

This lab also installs **Red Hat Developer Hub** (Backstage) via the `developer_hub` role as the in-cluster portal.

## Contributing

Issues and pull requests are welcome. Keep everything region-agnostic — no
customer names, private domains, or environment-specific hostnames; use
`example.com` and generic placeholders. Never commit credentials, tokens, or
private keys.

## License

[Apache-2.0](LICENSE).
