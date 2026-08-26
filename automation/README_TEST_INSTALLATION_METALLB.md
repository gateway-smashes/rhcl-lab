# MetalLB — Test Installation

This guide validates the on-prem LoadBalancer provider installed by
`playbooks/metallb-install.yml`. MetalLB is the bare-metal replacement
for the cloud LB controller — without it, Services of `type=LoadBalancer`
on a home-lab OpenShift cluster stay in `Pending` forever.

It is only required on clusters that have no cloud Load Balancer (lab,
home OpenShift, MicroShift, …). On AWS / Azure / GCP the cloud
controller-manager already provisions LBs and this playbook should stay
disabled (`METALLB_ENABLED=false`, the default).

## Object chain — how a Service gets an EXTERNAL-IP

```
OperatorGroup           (metallb-system, AllNamespaces mode)
  └─> Subscription      (metallb-operator in redhat-operators / channel stable)
        └─> CSV         (installs the operator workloads)
              └─> MetalLB CR                  (spawns controller + speaker DaemonSet)
                    └─> IPAddressPool         (declares the available IP range)
                          └─> L2Advertisement (announces the pool via ARP / L2)
                                └─> Service type=LoadBalancer
                                      receives EXTERNAL-IP from the pool
```

Each step is a precondition of the next: the operator cannot accept a
`MetalLB` CR until the webhook is up, the `IPAddressPool` is inert until
a `MetalLB` instance reconciles it, and addresses are only handed out to
Services once an `L2Advertisement` (or `BGPAdvertisement`) attaches the
pool to a network path. The Ansible role enforces this order and waits
between steps; if you create resources by hand, follow the same order.

## API names

The current MetalLB Operator on `redhat-operators` (OCP 4.11+) uses the
modern CRDs `IPAddressPool` + `L2Advertisement`. The legacy `AddressPool`
CRD plus ConfigMap configuration only exists on OCP 4.10 and older.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already
  created a working context.
- The cluster has no working cloud LB integration (otherwise prefer the
  cloud LB).
- A free IPv4 range on the same L2 segment as the cluster nodes, outside
  the DHCP scope of the local router.

## Required exports

```bash
# Enable the playbook
export METALLB_ENABLED=true

# Pool addresses — see "Address notation" below for the accepted syntax.
export METALLB_ADDRESSES="192.168.68.31-192.168.68.35"

# Optional — defaults shown
# export METALLB_NAMESPACE=metallb-system
# export METALLB_CHANNEL=stable
# export METALLB_IPADDRESSPOOL_NAME=rhcl-pool
# export METALLB_L2ADVERTISEMENT_NAME=rhcl-l2
# export METALLB_AUTO_ASSIGN=true
# export METALLB_AVOID_BUGGY_IPS=false

# Optional — restrict the L2 advertisement
# export METALLB_L2ADVERTISEMENT_INTERFACES="eth0,bond0"
# export METALLB_L2ADVERTISEMENT_NODE_SELECTOR_LABEL=node-role.kubernetes.io/worker
# export METALLB_L2ADVERTISEMENT_NODE_SELECTOR_VALUE=""
```

## Address notation

`METALLB_ADDRESSES` accepts a comma-separated mix of:

| Input token | What it becomes in the IPAddressPool |
|---|---|
| `192.168.68.31-192.168.68.35` | `192.168.68.31-192.168.68.35` (range, passed through) |
| `192.168.68.31` | `192.168.68.31-192.168.68.31` (single IP, normalised to a range) |
| `192.168.68.0/28` | `192.168.68.0/28` (CIDR, passed through) |

Mix freely, separated by commas:

```bash
export METALLB_ADDRESSES="192.168.68.31-192.168.68.35,192.168.68.40,192.168.68.0/28"
```

Whitespace inside the value is tolerated. An empty value fails fast at
the install assertion.

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/metallb-install.yml
```

The role waits for each step in the chain (Subscription → CSV → webhook
deployment → MetalLB CR → speaker DaemonSet → controller Deployment)
before creating the `IPAddressPool` and `L2Advertisement`. At the end it
prints a summary of the configured pool.

## Verify OperatorGroup, Subscription, and CSV

```bash
oc get operatorgroup -n metallb-system
oc get subscription -n metallb-system
oc get csv -n metallb-system
```

Expected result:

- OperatorGroup `metallb-operator` exists with **no** `spec.targetNamespaces`
  (AllNamespaces mode — the only mode the current operator supports).
- Subscription `metallb-operator` exists and `status.currentCSV` is set.
- CSV is `Succeeded`.

If you see the error `OwnNamespace InstallModeType not supported`, the
OperatorGroup was created with `spec.targetNamespaces: [metallb-system]`
— the playbook now creates it without `targetNamespaces`, so re-running
fixes new clusters; existing failed installs may need a cleanup:

```bash
CSV=$(oc -n metallb-system get sub metallb-operator -o jsonpath='{.status.currentCSV}')
oc -n metallb-system delete subscription metallb-operator --ignore-not-found
[ -n "$CSV" ] && oc -n metallb-system delete csv "$CSV" --ignore-not-found
oc -n metallb-system delete installplan --all --ignore-not-found
```

## Verify the MetalLB CR and workloads

```bash
oc get metallb -n metallb-system
oc get deploy,ds -n metallb-system
```

Expected result:

- `MetalLB` instance `metallb` exists.
- `controller` Deployment is Available (>=1 replica).
- `speaker` DaemonSet has `numberReady == desiredNumberScheduled`.

## Verify the IPAddressPool and L2Advertisement

```bash
oc get ipaddresspool -n metallb-system
oc get ipaddresspool -n metallb-system rhcl-pool -o yaml
oc get l2advertisement -n metallb-system
```

Expected result:

- `IPAddressPool` `rhcl-pool` exists; `spec.addresses` matches the
  normalised list (single IPs appear as `x.x.x.x-x.x.x.x`).
- `L2Advertisement` `rhcl-l2` exists; `spec.ipAddressPools` contains
  `rhcl-pool`.

The `validate` playbook automates the same checks:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/metallb-test.yml
```

## Smoke-test the EXTERNAL-IP assignment

Create a throwaway Service of `type=LoadBalancer` and check it receives
an address from the pool:

```bash
oc create deployment metallb-smoke --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep 3600
oc expose deployment metallb-smoke --port=80 --type=LoadBalancer
oc get svc metallb-smoke -w
```

Expected result:

- Within a few seconds, `EXTERNAL-IP` becomes an address from
  `METALLB_ADDRESSES`.
- `oc get ipaddresspool -n metallb-system rhcl-pool -o yaml` shows the
  address as assigned in `status`.

Cleanup the smoke test:

```bash
oc delete svc metallb-smoke
oc delete deployment metallb-smoke
```

## How RHCL components consume the pool

- `playbooks/coredns_dns-install.yml` creates `kuadrant-coredns-ext`
  (Service `type=LoadBalancer`, UDP/53). Without MetalLB it stays
  `Pending` and the playbook fails the LB-wait step.
- `playbooks/apps-install.yml` creates the apps `Gateway`. The OpenShift
  Gateway API controller (Istio) auto-provisions a Service
  `type=LoadBalancer` for the Gateway in `openshift-ingress`. Without
  MetalLB the Gateway never becomes `Programmed`.

Both consumers expect MetalLB to be ready, so run
`metallb-install.yml` before either of them.

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local \
  ansible-playbook playbooks/metallb-remove.yml
```

`metallb-remove.yml` deletes `L2Advertisement` → `IPAddressPool` →
`MetalLB` CR (waits for the operator to drain speakers and controller)
→ the `metallb-system` namespace (which removes the Subscription, CSV,
and OperatorGroup with it).
