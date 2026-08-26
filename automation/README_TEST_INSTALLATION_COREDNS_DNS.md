# CoreDNS as Kuadrant DNS Provider — Test Installation

This guide validates the on-prem CoreDNS DNS provider configured by
`playbooks/coredns_dns-install.yml`. It is **additive** to the existing
`coredns-install.yml` playbook and replaces the cloud-provider flow
(`dns-install.yml`) when you want HTTPRoute hostnames to be resolved by
your own CoreDNS instead of Route 53 / Azure DNS / Cloud DNS.

The playbook implements the Kuadrant CoreDNS provider flow described in the
Red Hat Connectivity Link 1.3 docs (section *Using on-prem DNS with CoreDNS*)
and the upstream Kuadrant guide
[CoreDNS Support](https://docs.kuadrant.io/dev/kuadrant-operator/doc/user-guides/dns/core-dns/).

## What the playbook creates / changes

1. Creates a sibling Service `kuadrant-coredns-ext` (`type: LoadBalancer`) in
   the `kuadrant-coredns` namespace, with the same selector as the upstream
   `kuadrant-coredns` Service but exposing **only UDP/53** by default. The
   AWS in-tree Cloud Controller Manager refuses to provision a single
   LoadBalancer that mixes UDP and TCP (`mixed protocol is not supported for
   LoadBalancer`), so the original Service stays `ClusterIP` and the
   external entrypoint serves UDP only. DNS clients fall back to TCP only
   for responses >512 B or AXFR, neither of which the PoC relies on. To add
   TCP, install the AWS Load Balancer Controller and set
   `COREDNS_DNS_EXTERNAL_PROTOCOLS=UDP,TCP`.
2. Patches the `kuadrant-coredns` `ConfigMap` `Corefile` to replace the
   upstream demo zone (`k.example.com`) with the target zone
   (`COREDNS_DNS_ZONE`, e.g. `poccoredns.rhcl.com.br`) and rolls the CoreDNS
   `Deployment` to pick up the change.
3. Creates a `kuadrant.io/coredns` `Secret` in the Gateway namespace with
   `ZONES=<target zone>`. Optionally labels it
   `kuadrant.io/default-provider=true`.
4. Creates a `DNSPolicy` (`<gateway>-coredns`) that targets the apps
   Gateway and references the CoreDNS Secret via `providerRefs`. By default
   it sets `delegate: true` so multiple CoreDNS instances (one per cluster)
   can act as primaries when the PoC scales to 2-3 clusters.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created
  a working context.
- RHCL is installed (`playbooks/rhcl-install.yml`).
- The apps Gateway is being deployed (or already deployed) via
  `playbooks/apps-install.yml` — the `DNSPolicy` is admitted but stays
  `enforced=false` until its target Gateway is `Programmed`.
- `playbooks/coredns-install.yml` already ran successfully (creates the
  `kuadrant-coredns` namespace, Deployment, Service and ConfigMap).
- The cluster's LoadBalancer integration is working (cloud LB on managed
  clusters; MetalLB or equivalent on bare metal).

## Phase 1 — single cluster

Pick a subdomain that you control on the parent zone (Cloudflare,
Route 53, …). The example below uses `poccoredns.rhcl.com.br` delegated
from `rhcl.com.br` on Cloudflare.

```bash
# Required
export COREDNS_DNS_ENABLED=true
export COREDNS_DNS_ZONE=poccoredns.rhcl.com.br

# Target Gateway (defaults to APPS_CONNECTIVITY_GATEWAY_* — only set if
# you customised the apps Gateway name/namespace)
# export COREDNS_DNS_POLICY_TARGET_GATEWAY_NAME=rhcl-apps-gateway
# export COREDNS_DNS_POLICY_TARGET_GATEWAY_NAMESPACE=openshift-ingress

# Optional — Service exposure (defaults shown)
# export COREDNS_DNS_SERVICE_TYPE=LoadBalancer
# export COREDNS_DNS_LB_WAIT_TIMEOUT=300

# AWS NLB compatibility (default true — adds
# service.beta.kubernetes.io/aws-load-balancer-type=nlb on the external
# Service. Safe to leave on for Azure/GCP — the annotation is ignored
# there.)
# export COREDNS_DNS_AWS_NLB_COMPAT=true

# External Service exposure (defaults shown)
# export COREDNS_DNS_EXTERNAL_SERVICE_NAME=kuadrant-coredns-ext
# export COREDNS_DNS_EXTERNAL_PROTOCOLS=UDP        # add TCP only if the
                                                  # AWS Load Balancer
                                                  # Controller is installed

# Optional — multi-cluster prep (defaults work for phase 1)
# export COREDNS_DNS_POLICY_DELEGATE=true
# export COREDNS_DNS_POLICY_LOAD_BALANCING_ENABLED=false
```

Run the playbook:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/coredns_dns-install.yml
```

At the end the playbook prints the delegation block to add to the parent
zone, e.g.:

```
; Glue A records (one per CoreDNS endpoint)
ns1.poccoredns.rhcl.com.br. A <LB IP>
; NS delegation
poccoredns.rhcl.com.br. NS ns1.poccoredns.rhcl.com.br.
```

Add those records on the parent zone (Cloudflare → `rhcl.com.br`). Until
this delegation is in place, only Kuadrant internals will see the records
CoreDNS serves; public resolvers will return `NXDOMAIN` for the zone.

## Phase 2 — adding more clusters (2 or 3)

The CoreDNS Kuadrant plugin is designed to run as **multiple primaries**.
The flow for each new cluster:

1. Run `coredns-install.yml` on the new cluster (creates its own
   `kuadrant-coredns` instance).
2. Run `coredns_dns-install.yml` with **the same `COREDNS_DNS_ZONE`** and
   per-cluster overrides for geo / weight:

   ```bash
   export COREDNS_DNS_ENABLED=true
   export COREDNS_DNS_ZONE=poccoredns.rhcl.com.br
   export COREDNS_DNS_POLICY_LOAD_BALANCING_ENABLED=true
   export COREDNS_DNS_POLICY_GEO=GEO-NA           # or GEO-EU, GEO-SA, ...
   export COREDNS_DNS_POLICY_DEFAULT_GEO=false    # only one cluster should be default
   export COREDNS_DNS_POLICY_WEIGHT=120
   ```

3. The playbook prints a new `nsN.poccoredns.rhcl.com.br` glue/NS pair for
   the new cluster's LoadBalancer IP. Append those records to the parent
   zone alongside the existing ones — Cloudflare will list every cluster as
   authoritative for `poccoredns.rhcl.com.br`.

Each CoreDNS instance is authoritative for the zone and answers with the
geo/weight-aware records of its own cluster (`delegate: true` makes the
instance act as a clustered primary instead of a standalone authority).

## Verify the Service is exposed

```bash
oc get service -n kuadrant-coredns
oc get service -n kuadrant-coredns kuadrant-coredns-ext \
  -o jsonpath='{.spec.type}{"  "}{.status.loadBalancer.ingress}{"\n"}'
```

Expected result:

- The original `kuadrant-coredns` Service stays `ClusterIP`.
- `kuadrant-coredns-ext` is `LoadBalancer` and
  `status.loadBalancer.ingress[]` has at least one entry (`ip` or
  `hostname`).

## Verify the CoreDNS Corefile picked up the zone

```bash
oc get configmap -n kuadrant-coredns kuadrant-coredns \
  -o jsonpath='{.data.Corefile}{"\n"}'
```

Expected result:

- The Corefile starts with `poccoredns.rhcl.com.br {` (or whatever you set
  in `COREDNS_DNS_ZONE`); the upstream `k.example.com` zone is no longer
  present.

## Verify the Secret and DNSPolicy

```bash
oc get secret -n openshift-ingress rhcl-coredns-credentials
oc get secret -n openshift-ingress rhcl-coredns-credentials \
  -o jsonpath='{.type}{"\n"}{.data.ZONES}{"\n"}'
oc get dnspolicy -n openshift-ingress
oc get dnspolicy -n openshift-ingress rhcl-apps-gateway-coredns -o yaml
```

Expected result:

- Secret type is `kuadrant.io/coredns`; the `ZONES` data is the
  base64-encoded target zone.
- DNSPolicy exists in the Gateway namespace, `targetRef` points at the
  apps Gateway, `providerRefs[0].name` matches the Secret.
- `status.conditions[type=Accepted].status == "True"`.
- Once an HTTPRoute hostname falls within the CoreDNS zone, `DNSRecord`
  resources start showing up:

  ```bash
  oc get dnsrecord -n openshift-ingress
  ```

The `validate` playbook automates the same checks:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/coredns_dns-test.yml
```

## Smoke-test resolution

Once the parent-zone delegation is live and an HTTPRoute attaches to the
Gateway with a hostname under the zone (e.g.
`banking-api.poccoredns.rhcl.com.br`):

```bash
LB_IP=$(oc get svc -n kuadrant-coredns kuadrant-coredns-ext \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Query the cluster CoreDNS directly (bypasses the public resolver chain)
dig @${LB_IP} banking-api.poccoredns.rhcl.com.br +short

# Query through the public resolver chain (requires the NS delegation on
# the parent zone to be live and propagated)
dig banking-api.poccoredns.rhcl.com.br +short
```

## Changing the zone after the first install

The Corefile patch in step 2 replaces the upstream `k.example.com` zone
with `COREDNS_DNS_ZONE`. Re-running the playbook with a **different**
`COREDNS_DNS_ZONE` will not rewrite an already-customised Corefile — the
upstream string is no longer present after the first run. To switch the
zone, run `coredns-remove.yml` followed by `coredns-install.yml` first to
restore the upstream ConfigMap, then re-run `coredns_dns-install.yml`
with the new zone.

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/coredns_dns-remove.yml
```

`coredns_dns-remove.yml` deletes the DNSPolicy, the CoreDNS Secret, and
the `kuadrant-coredns-ext` external Service (which in turn releases the
AWS NLB). The upstream `kuadrant-coredns` Service, Deployment and
ConfigMap are owned by `coredns-install.yml` — run `coredns-remove.yml`
to tear those down too.
