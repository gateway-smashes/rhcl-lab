---
title: Multi-cloud DNS management
summary: Managed DNS across AWS Route 53 / Azure DNS / Google Cloud DNS via Kuadrant DNSPolicy.
category: Networking & DNS
status: done
---

# Req 09 — DNS Management across Multi-Cloud Environments

## Requirement Demonstrated

- **Req 09: DNS management and registration of APIs** across on-premise, Azure, Google Cloud, and AWS environments.
- DNSPolicy-based traffic steering with multi-cloud and multi-cluster support.
- Integration with external DNS providers (Route53, Azure DNS, Cloud DNS, CoreDNS).

---

## Overview

**DNSPolicy** is a Kuadrant resource that manages DNS records for Gateways across different cloud providers and on-premise DNS systems. It allows:

- **Centralized DNS management** for APIs exposed by Kuadrant Gateways
- **Load balancing by weight** between clusters (inter-cluster traffic steering)
- **Geo-aware routing** when supported by the provider
- **Seamless multi-cloud operation** — same API hostname across AWS, Azure, GCP, and on-premise

### How DNSPolicy Works

1. **Target**: DNSPolicy attaches to a Kubernetes Gateway (via `targetRef`)
2. **Provider**: Credentials for the external DNS provider (AWS Route53, Azure DNS, GCP Cloud DNS, or CoreDNS)
3. **Load Balancing** (optional): Weight-based or geo-based distribution across clusters
4. **Automation**: The Kuadrant controller reconciles the policy and updates DNS records automatically

---

## Supported DNS Providers

| Provider | Environment | Mechanism | Setup |
|----------|-------------|-----------|-------|
| **AWS Route53** | AWS public cloud | DNS A records with weighted routing | API credentials + hosted zone |
| **Azure DNS** | Azure public cloud | DNS A records via Azure API | Service principal + resource group |
| **Google Cloud DNS** | GCP public cloud | DNS A records via Cloud DNS API | Service account + managed zone |
| **CoreDNS** | On-premise / private | Direct zone file updates or API | Kubeconfig access to CoreDNS namespace |

---

## Quick Start

### Option 1: Using Automation (Recommended)

The `automation/roles/dns/` Ansible role handles all setup:

```bash
# Discover cluster environment
source automation/scripts/cluster-env.sh

# Install DNSPolicy and DNS provider secret
RHCL_DNS_PROVIDER=aws \
RHCL_DNS_POLICY_ENABLED=true \
RHCL_DNS_POLICY_LOAD_BALANCING_ENABLED=true \
RHCL_DNS_POLICY_WEIGHT=80 \
ansible-playbook automation/playbooks/dns-install.yml
```

### Option 2: Manual Manifest Application

Apply the pre-built manifests from `tests/multi-cloud-dns/manifests/`:

```bash
# For AWS Route53
oc apply -f tests/multi-cloud-dns/manifests/dnspolicy-aws-route53.yaml

# For Azure DNS
oc apply -f tests/multi-cloud-dns/manifests/dnspolicy-azure-dns.yaml

# For GCP Cloud DNS
oc apply -f tests/multi-cloud-dns/manifests/dnspolicy-gcp-cloud-dns.yaml

# For on-premise CoreDNS (DNSPolicy targeting the apps Gateway)
oc apply -f tests/multi-cloud-dns/manifests/dnspolicy-onprem-coredns.yaml
```

For a self-contained on-premise demo that creates a DNS zone and resolves
it **inside the cluster without any LoadBalancer**, see
[On-Premise CoreDNS — Internal Zone Demo](#on-premise-coredns--internal-zone-demo-manual-no-ansible)
below ([`manifests/coredns-internal-zone-demo.yaml`](manifests/coredns-internal-zone-demo.yaml)).

---

## Manifest Structure

Each DNSPolicy manifest includes:

1. **Secret** with DNS provider credentials
2. **DNSPolicy** resource pointing to the Gateway

### Example: AWS Route53

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: rhcl-dns-credentials
  namespace: openshift-ingress
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: <your-access-key>
  AWS_SECRET_ACCESS_KEY: <your-secret-key>

---
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: rhcl-apps-gateway-dns
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: rhcl-apps-gateway
  providerRefs:
    - name: rhcl-dns-credentials
  loadBalancing:
    defaultGeo: true
    weight: 80
```

---

## Configuration Guide

### DNS Provider Credentials

Each provider requires different credentials:

#### AWS Route53
```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-2
```
**Required IAM permissions**: `route53:*` on the hosted zone

#### Azure DNS
```bash
AZURE_CLIENT_ID=...
AZURE_CLIENT_SECRET=...
AZURE_SUBSCRIPTION_ID=...
AZURE_TENANT_ID=...
AZURE_RESOURCE_GROUP=...
```
**Required**: Service principal with `DNS Zone Contributor` role

#### GCP Cloud DNS
```bash
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
GOOGLE_PROJECT_ID=...
```
**Required**: Service account with `dns.admin` role

#### CoreDNS (On-Premise)
```bash
# No external credentials needed — uses in-cluster kubeconfig
# CoreDNS must be running in a specific namespace (e.g., coredns)
# and expose a Kuadrant-compatible update API
```

---

## Load Balancing Configuration

### By Weight (Global Distribution)

Distribute traffic proportionally between clusters:

```yaml
spec:
  loadBalancing:
    defaultGeo: true
    weight: 80  # This cluster receives 80% of DNS queries
```

**When to use:**
- Multi-cluster HA setup with proportional failover
- Canary deployments across clusters (cluster A: 90, cluster B: 10)
- No geographic preference

### By Geo (Geographic Distribution)

Route traffic based on client location:

```yaml
spec:
  loadBalancing:
    geo: "GEO-NA"          # North America gets this cluster
    defaultGeo: true       # Other regions use this cluster as fallback
```

**Supported geo codes** (varies by provider):
- `GEO-NA` — North America
- `GEO-EU` — Europe
- `GEO-APAC` — Asia-Pacific
- `GEO-SA` — South America
- Others per provider

---

## Multi-Cluster DNS Setup

To expose the same API across multiple clusters:

### Cluster A (Primary)
```yaml
spec:
  loadBalancing:
    weight: 80
```

### Cluster B (Secondary)
```yaml
spec:
  loadBalancing:
    weight: 20
```

**Result:** DNS resolver sees both cluster IPs, weight-based round-robin:
- 80% queries → Cluster A
- 20% queries → Cluster B

---

## Validation

### Check DNSPolicy Status

```bash
oc get dnspolicy -n openshift-ingress -o wide
oc describe dnspolicy rhcl-apps-gateway-dns -n openshift-ingress
```

### Verify DNS Resolution

```bash
# Query multiple times to see weight distribution
for i in {1..20}; do
  dig +short banking-api-connectivity.${RHCL_ZONE_ROOT_DOMAIN} @8.8.8.8
done | sort | uniq -c
```

Expected with 80/20 weight:
```
  16 <IP-cluster-A>
   4 <IP-cluster-B>
```

### TTL and Caching

DNS results are cached by resolvers. To observe distribution:
- Use different resolvers (8.8.8.8, 1.1.1.1, 208.67.222.222)
- Or disable caching: `dig +nocache`
- Or wait for TTL expiration (usually 60–300 seconds)

---

## On-Premise CoreDNS — Internal Zone Demo (manual, no Ansible)

This walkthrough demonstrates the core on-premise capability **without any
external LoadBalancer**: create a DNS zone in CoreDNS, register a record,
and resolve it from inside the cluster. It is self-contained and does not
depend on the Ansible-driven `kuadrant-coredns` flow.

> **Internal-only scope:** the demo CoreDNS is exposed via a `ClusterIP`
> Service, so resolution works for **in-cluster clients (pods) only**.
> Publishing the zone to clients outside the cluster would require
> **MetalLB** (bare metal) or a cloud LoadBalancer to give CoreDNS an
> externally reachable address — out of scope here. The manifest used by
> this section is
> [`manifests/coredns-internal-zone-demo.yaml`](manifests/coredns-internal-zone-demo.yaml).

### Step 1 — Deploy the standalone CoreDNS with a custom zone

```bash
oc apply -f tests/multi-cloud-dns/manifests/coredns-internal-zone-demo.yaml
```

This creates, in namespace `req009-coredns`:

- a **ConfigMap** (`coredns-poc`) holding the `Corefile` and the zone file
  `db.poc.internal` (zone `poc.internal` with A records `ns1`,
  `banking-api`, `api`);
- a **Deployment** running CoreDNS, listening on the unprivileged port
  `5353` (so it runs under the OpenShift `restricted-v2` SCC);
- a **ClusterIP Service** (`coredns-poc`) mapping port `53` → `5353`.

Wait for the pod to become ready:

```bash
oc rollout status deploy/coredns-poc -n req009-coredns
oc get pods -n req009-coredns
```

### Step 2 — Inspect the zone CoreDNS is serving

```bash
# The Corefile (server blocks) and the zone file (records)
oc get configmap coredns-poc -n req009-coredns -o jsonpath='{.data.Corefile}{"\n"}'
oc get configmap coredns-poc -n req009-coredns -o jsonpath='{.data.db\.poc\.internal}{"\n"}'
```

Expected: the `poc.internal:5353` server block uses `file
/etc/coredns/db.poc.internal`, and the zone file lists the SOA, NS and the
`banking-api` / `api` A records.

### Step 3 — Query the zone from inside the cluster

```bash
# ClusterIP of the demo CoreDNS Service
COREDNS_IP=$(oc get svc coredns-poc -n req009-coredns -o jsonpath='{.spec.clusterIP}')
echo "CoreDNS ClusterIP: $COREDNS_IP"

# Resolve an A record (dnsutils image has dig)
oc run dnsutils --rm -it --restart=Never -n req009-coredns \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- \
  dig @${COREDNS_IP} banking-api.poc.internal +short
```

Expected output:

```
10.96.0.20
```

Prove CoreDNS is authoritative for the zone (SOA query):

```bash
oc run dnsutils --rm -it --restart=Never -n req009-coredns \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- \
  dig @${COREDNS_IP} poc.internal SOA +short
```

> **No public image access?** If the cluster cannot pull
> `jessie-dnsutils`, use `busybox` (widely mirrored) with `nslookup`:
> ```bash
> oc run dnsutils --rm -it --restart=Never -n req009-coredns \
>   --image=busybox:1.36 -- \
>   nslookup -type=a banking-api.poc.internal ${COREDNS_IP}
> ```

You can also query by the Service FQDN instead of the ClusterIP from any
other pod in the cluster:

```bash
dig @coredns-poc.req009-coredns.svc.cluster.local banking-api.poc.internal +short
```

### Step 4 — Add or change a record

Edit the zone file in the ConfigMap, **bump the SOA serial**, then roll the
Deployment so CoreDNS reloads the zone:

```bash
oc edit configmap coredns-poc -n req009-coredns
# Under data.db\.poc\.internal:
#   - add e.g.  payments  IN  A  10.96.0.40
#   - increment the serial: 2026061001 -> 2026061002

oc rollout restart deploy/coredns-poc -n req009-coredns
oc rollout status deploy/coredns-poc -n req009-coredns

# Verify the new record resolves
oc run dnsutils --rm -it --restart=Never -n req009-coredns \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- \
  dig @${COREDNS_IP} payments.poc.internal +short
```

### Step 5 (optional) — Make every pod resolve the zone transparently

So far queries target the CoreDNS Service explicitly. To let **any pod**
resolve `poc.internal` through the cluster's default DNS (no explicit
resolver), add a forwarding zone to the OpenShift DNS Operator:

```bash
COREDNS_IP=$(oc get svc coredns-poc -n req009-coredns -o jsonpath='{.spec.clusterIP}')

oc patch dns.operator/default --type=merge -p "$(cat <<EOF
spec:
  servers:
    - name: poc-internal
      zones:
        - poc.internal
      forwardPlugin:
        upstreams:
          - ${COREDNS_IP}
EOF
)"
```

The OpenShift DNS Operator rolls out the change to the cluster default DNS
(`openshift-dns`). After that, any pod resolves the zone without naming the
resolver:

```bash
oc run dnsutils --rm -it --restart=Never -n default \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 -- \
  dig banking-api.poc.internal +short
```

> Port `53` is implied by the DNS Operator forwarder. The ClusterIP is
> stable for the life of the Service — if you recreate the Service, update
> the forwarder with the new IP. Remove the forwarding zone by editing
> `dns.operator/default` and deleting the `poc-internal` server entry.

### Step 6 — Cleanup

```bash
oc delete -f tests/multi-cloud-dns/manifests/coredns-internal-zone-demo.yaml

# If you added the DNS Operator forwarder in Step 5, remove the
# poc-internal server from dns.operator/default:
oc edit dns.operator/default   # delete the spec.servers[poc-internal] entry
```

---

## Interactive Console

The DNSPolicy console at `tests/multi-cloud-dns/index.html` provides:

1. **DNS Status Panel**
   - Current Gateway name and namespace
   - Exposed hostnames
   - Resolved IPs and TTL

2. **Provider Info**
   - Active provider (AWS/Azure/GCP/CoreDNS)
   - Credentials status
   - Load balancing configuration

3. **DNS Testing**
   - Resolve any hostname
   - Test multi-cluster distribution
   - View raw DNS response

4. **Configuration Display**
   - Current DNSPolicy YAML
   - Secret status (redacted)
   - Provider connection status

**To run:**
```bash
# The console is served by the test catalog container
curl http://localhost:3000/multi-cloud-dns/index.html
# or through OpenShift Route if deployed
```

---

## Troubleshooting

### DNSPolicy Not Applying

```bash
# Check controller logs
oc logs -n kuadrant-system -l app=kuadrant-operator

# Verify secret exists in same namespace as Gateway
oc get secret rhcl-dns-credentials -n openshift-ingress

# Check targetRef matches Gateway name/namespace
oc get gateway -n openshift-ingress
```

### DNS Not Resolving

```bash
# Check if Route53/Azure/GCP has the record
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> | grep banking-api

# Verify credentials are valid
oc get secret rhcl-dns-credentials -n openshift-ingress -o yaml
# (check that AWS_ACCESS_KEY_ID is present and non-empty)

# Check controller events
oc describe dnspolicy rhcl-apps-gateway-dns -n openshift-ingress | tail -20
```

### Wrong Traffic Distribution

```bash
# Verify weight was applied
oc get dnspolicy rhcl-apps-gateway-dns -n openshift-ingress -o yaml | grep weight

# Check TTL — results are cached
dig ${HOSTNAME} | grep -i "TTL"
# Wait at least TTL seconds and re-query, or use +nocache

# For geo routing, verify geo code is supported by provider
# (not all providers support all geo regions)
```

---

## Notes

- **Namespace requirement**: The DNS provider secret and DNSPolicy must be in the same namespace as the target Gateway
- **TTL caching**: DNS results are cached globally — allow time for propagation
- **Provider-specific limits**: Some providers have API rate limits for DNS updates
- **Fallback**: If DNSPolicy fails, the Gateway IP remains resolvable via standard DNS (doesn't break connectivity)

---

## Live PoC evidence — two clouds, one Route53 zone (AWS + Azure)

This is the concrete demonstration of the requirement: **exposing the app on the Azure cluster updates the same Route53 zone that the AWS cluster manages**, with no shared config — each cluster reconciles its own records into `example.com`.

Both clusters run a `DNSPolicy` targeting their local `rhcl-apps-gateway`, pointed at the **same** hosted zone `Z04631642WLNFO9ZK0A5U` via a `rhcl-dns-credentials` secret. Kuadrant assigns each cluster a distinct `ownerID` so they co-own the record set without clobbering each other:

```bash
# On each cluster:
oc get dnsrecords.kuadrant.io rhcl-apps-gateway-https -n openshift-ingress \
  -o jsonpath='rootHost={.spec.rootHost} owner={.status.ownerID} zone={.status.zoneID} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Actual output (2026-07-09):

| Cluster | rootHost | zoneID | ownerID | ready |
|---------|----------|--------|---------|-------|
| AWS `lab` | `*.example.com` | `…/Z04631642WLNFO9ZK0A5U` | `tmycba6c` | True |
| Azure `cluster-azure` | `*.example.com` | `…/Z04631642WLNFO9ZK0A5U` | `2867jg2l` | True |

Confirm both `DNSPolicy` objects are enforced:

```bash
oc get dnspolicy rhcl-apps-gateway-dns -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}{"\n"}'
# → "DNSPolicy has been successfully enforced"   (on both clusters)
```

Query the authoritative Route53 nameserver directly and see the record Kuadrant built:

```bash
NS=$(dig +short NS example.com | head -1)
dig +noall +answer banking-api-connectivity.example.com @${NS}
# CNAME → klb → geo-na → { AWS ELB , Azure LB IP }
```

The weighted / geo steering built on top of this shared record is **Item 10** — see [`../multi-site-load-balancing/README.md`](../multi-site-load-balancing/README.md).

---

## Related Items

- **Item 5:** Load balancing by weight (intra-cluster via HTTPRoute, inter-cluster via DNSPolicy)
- **Item 10:** Multi-site / multicloud load balancing of one API — [`../multi-site-load-balancing/README.md`](../multi-site-load-balancing/README.md)
- **Item 71:** Multi-cluster integration and distributed routing
- **Automation:** `automation/roles/dns/` for repeatable setup
- **Demo:** `tests/weighted-load-balancing/dnspolicy-weighted.yaml` for a working multi-cluster example
