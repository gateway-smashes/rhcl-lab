# cert-manager Test Installation

This guide validates the cert-manager Operator installed by `playbooks/cert_manager-install.yml`.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- `cert-manager` playbook already ran successfully

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/cert_manager-install.yml
```

## Verify namespace, Subscription, and CSV

```bash
oc get namespace cert-manager-operator
oc get subscription -n cert-manager-operator
oc get csv -n cert-manager-operator
```

Expected result:

- namespace `cert-manager-operator` exists
- subscription `openshift-cert-manager-operator` exists
- at least one CSV is in `Succeeded`

## Verify pods

```bash
oc get pods -n cert-manager-operator
```

Expected result:

- pods for `cert-manager`, `cert-manager-webhook`, and `cert-manager-cainjector` are `Running`

## Optional smoke test with a self-signed issuer

Create a namespace for the smoke test:

```bash
oc new-project cert-manager-test
```

Create a namespaced issuer:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: cert-manager-test
spec:
  selfSigned: {}
```

Create a test certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-certificate
  namespace: cert-manager-test
spec:
  secretName: test-certificate-tls
  commonName: test.example.internal
  dnsNames:
    - test.example.internal
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
```

Apply and inspect:

```bash
oc apply -f issuer.yaml
oc apply -f certificate.yaml
oc get issuer,certificate,secret -n cert-manager-test
oc describe certificate -n cert-manager-test test-certificate
```

Expected result:

- `Issuer` is ready
- `Certificate` is ready
- secret `test-certificate-tls` exists

## Cleanup

```bash
oc delete project cert-manager-test --ignore-not-found
```
