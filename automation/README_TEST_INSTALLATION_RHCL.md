# RHCL Test Installation

This guide validates the RHCL installation created by `playbooks/rhcl-install.yml`.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- Gateway API and cert-manager were installed first
- RHCL install playbook already ran successfully

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/rhcl-install.yml
```

Optional overrides:

- `RHCL_CONSOLE_PLUGIN_ENABLED=false` skips OpenShift Console plugin enablement
- `RHCL_CONSOLE_PLUGIN_NAME=kuadrant-console-plugin` sets the ConsolePlugin name

## Verify namespace, Subscription, and CSV

```bash
oc get namespace kuadrant-system
oc get subscription -n kuadrant-system
oc get csv -n kuadrant-system
```

Expected result:

- namespace `kuadrant-system` exists
- subscription `rhcl-operator` exists
- RHCL CSV is in `Succeeded`

## Verify the Kuadrant custom resource

```bash
oc get kuadrant -n kuadrant-system
oc describe kuadrant -n kuadrant-system kuadrant
oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready=true --timeout=300s
```

Expected result:

- `kuadrant` custom resource exists
- `Ready=True`

## Verify dependent operators

```bash
oc get csv -n kuadrant-system | egrep 'authorino|limitador|dns'
oc get deployments -n kuadrant-system
```

Expected result:

- dependent operators for `Authorino`, `DNS`, and `Limitador` are present

## Verify the OpenShift Console plugin

```bash
oc get consoleplugin kuadrant-console-plugin
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

Expected result:

- `kuadrant-console-plugin` exists
- `kuadrant-console-plugin` is listed in `spec.plugins`

## Optional inspection of RHCL APIs

```bash
oc api-resources | egrep 'kuadrant|authorino|limitador'
```

Expected result:

- Kuadrant-related API resources are registered in the cluster

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/rhcl-remove.yml
```
