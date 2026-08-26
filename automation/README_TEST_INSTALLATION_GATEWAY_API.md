# Gateway API Test Installation

This guide validates the Gateway API prerequisite installed by `playbooks/gateway_api-install.yml`.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- OpenShift `4.19+`
- `GatewayClass` `openshift-default` was applied by the automation

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/gateway_api-install.yml
```

## Verify the GatewayClass

```bash
oc get gatewayclass
oc get gatewayclass openshift-default -o yaml
```

Expected result:

- `openshift-default` exists
- `spec.controllerName` is `openshift.io/gateway-controller/v1`

## Verify the ingress-managed deployment

```bash
oc get deployment -n openshift-ingress
oc get deployment -n openshift-ingress istiod-openshift-gateway
oc wait -n openshift-ingress --for=condition=Available deployment/istiod-openshift-gateway --timeout=300s
```

Expected result:

- deployment `istiod-openshift-gateway` exists
- `AVAILABLE` is at least `1`

## Optional smoke setup with a dedicated Gateway

Check the cluster base domain:

```bash
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```

Create a simple `Gateway` in `openshift-ingress`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: example-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "example.apps.cluster.example.com"
      allowedRoutes:
        namespaces:
          from: All
```

Apply it:

```bash
oc apply -f example-gateway.yaml
oc wait -n openshift-ingress --for=condition=Programmed gateways.gateway.networking.k8s.io/example-gateway --timeout=300s
oc get gateway -n openshift-ingress example-gateway -o yaml
```

## Optional HTTPRoute example

Create a test namespace and a sample backend:

```bash
oc new-project gateway-api-test
oc new-app --name hello --image quay.io/openshifttest/hello-openshift:1.2 -n gateway-api-test
oc get svc -n gateway-api-test hello
```

Create an `HTTPRoute`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example-route
  namespace: gateway-api-test
spec:
  parentRefs:
    - name: example-gateway
      namespace: openshift-ingress
  hostnames:
    - "example.apps.cluster.example.com"
  rules:
    - backendRefs:
        - name: hello
          port: 8080
```

Apply and inspect:

```bash
oc apply -f example-route.yaml
oc get httproute -n gateway-api-test
oc describe httproute -n gateway-api-test example-route
```

Expected result:

- `HTTPRoute` is accepted by the gateway
- route status shows resolved parent references

## Cleanup

```bash
oc delete httproute -n gateway-api-test example-route --ignore-not-found
oc delete gateway -n openshift-ingress example-gateway --ignore-not-found
oc delete project gateway-api-test --ignore-not-found
```
