# CoreDNS Test Installation

This guide validates the CoreDNS prerequisite installed by `playbooks/coredns-install.yml`.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- `kustomize` is installed on the control host
- RHCL install playbook already ran successfully

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/coredns-install.yml
```

## Verify namespace, deployment, and service

```bash
oc get namespace kuadrant-coredns
oc get deployment -n kuadrant-coredns
oc get service -n kuadrant-coredns
oc get configmap -n kuadrant-coredns
```

Expected result:

- namespace `kuadrant-coredns` exists
- deployment `kuadrant-coredns` exists
- service `kuadrant-coredns` exists
- configmap `kuadrant-coredns` exists

## Verify deployment readiness

```bash
oc wait -n kuadrant-coredns --for=condition=Available deployment/kuadrant-coredns --timeout=300s
oc get pods -n kuadrant-coredns
```

Expected result:

- at least one `coredns` pod is `Running`
- deployment is `Available`

## Optional DNS smoke check

Inspect the service and endpoints:

```bash
oc get svc,endpoints -n kuadrant-coredns
```

Start a temporary debug pod and test DNS resolution through CoreDNS:

```bash
oc run -n kuadrant-coredns dns-debug --image registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- sleep 3600
oc wait -n kuadrant-coredns --for=condition=Ready pod/dns-debug --timeout=180s
oc rsh -n kuadrant-coredns dns-debug getent hosts kuadrant.io
```

## Cleanup

```bash
oc delete pod -n kuadrant-coredns dns-debug --ignore-not-found
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/coredns-remove.yml
```
