# Applications Test Installation

This guide validates the sample applications installed by `playbooks/apps-install.yml`.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- `oc` is installed on the control host
- The RHCL core prerequisites already ran successfully

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/apps-install.yml
```

Optional overrides:

- `APPS_CONNECTIVITY_LINK_ENABLED=false` skips Gateway API connectivity resources
- `APPS_CONNECTIVITY_ROUTE_HOSTNAME=<host>` sets a fixed HTTPRoute hostname
- `APPS_CONNECTIVITY_GATEWAY_DENY_ALL_ENABLED=true` applies a deny-all `AuthPolicy` on the connectivity `Gateway`
- `APPS_CONNECTIVITY_ROUTE_CORS_ENABLED=true` injects CORS response headers from `HTTPRoute`
- `APPS_CONNECTIVITY_ROUTE_CORS_ALLOW_ORIGIN=*` controls allowed CORS origin
- `APPS_CONNECTIVITY_RATELIMIT_LIMIT=10` sets the request limit
- `APPS_CONNECTIVITY_RATELIMIT_WINDOW=1s` sets the rate limit window
- `APPS_CONNECTIVITY_TLS_ENABLED=true` adds an HTTPS/443 listener and a `TLSPolicy`
- `APPS_CONNECTIVITY_TLS_ISSUER_NAME=<issuer>` (required when TLS is enabled) cert-manager issuer to back the gateway certificate
- `APPS_CONNECTIVITY_TLS_ISSUER_KIND=ClusterIssuer` (default) or `Issuer`
- `APPS_CONNECTIVITY_TLS_ISSUER_GROUP=cert-manager.io` (default) issuer API group
- `APPS_CONNECTIVITY_TLS_SECRET_NAME=<secret>` (default `<gateway>-tls`) secret managed by cert-manager
- `APPS_CONNECTIVITY_TLS_POLICY_NAME=<policy>` (default `<gateway>-tls`) `TLSPolicy` resource name
- `APPS_BACKEND_TLS_ENABLED=true` enables the backend HTTPS listener on port `8443` with OpenShift service serving certificates
- `APPS_BACKEND_HTTPS_PORT=8443` changes the backend HTTPS container and service port
- `APPS_BACKEND_TLS_CLIENT_AUTH=none` controls Quarkus backend client certificate auth (`none`, `request`, or `required`)

## Optional: enable HTTPS on the connectivity gateway

When `APPS_CONNECTIVITY_TLS_ENABLED=true`, the playbook adds an HTTPS listener
to the gateway and creates a `TLSPolicy` that references a cert-manager issuer.
The cert-manager operator provisions the `tls.crt`/`tls.key` into a secret in
the gateway namespace, and the playbook waits for that secret before continuing.

Preconditions:

- `cert-manager` playbook already ran successfully
- a `ClusterIssuer` (or namespaced `Issuer` in `openshift-ingress`) is ready
- if the issuer uses ACME with DNS-01, the `dns-install.yml` playbook already
  configured the DNS provider secret consumed by your `DNSPolicy` flow

Example with a Let's Encrypt staging `ClusterIssuer`:

```bash
export APPS_CONNECTIVITY_TLS_ENABLED=true
export APPS_CONNECTIVITY_TLS_ISSUER_NAME=letsencrypt-staging
export APPS_CONNECTIVITY_TLS_ISSUER_KIND=ClusterIssuer
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/apps-install.yml
```

## Verify builds and image streams

```bash
oc get is,bc,build -n rhcl-apps
```

Expected result:

- image streams `banking-api` and `mobile-bank` exist
- build configs `banking-api` and `mobile-bank` exist
- the latest builds completed successfully

## Verify deployments, services, and routes

```bash
oc get deployment,svc,route -n rhcl-apps
oc get pods -n rhcl-apps
oc get gateway -n openshift-ingress rhcl-apps-gateway
oc get httproute,ratelimitpolicy -n rhcl-apps
oc get authpolicy -n openshift-ingress
```

Expected result:

- deployments `banking-api-v1`, `banking-api-v2`, and `mobile-bank` exist
- backend services expose both `http:8080` and `https:8443` when `APPS_BACKEND_TLS_ENABLED=true`
- HTTPRoute `backend-tls` and `BackendTLSPolicy` `backend-tls-backend-tls` exist when `APPS_BACKEND_TLS_ROUTE_ENABLED=true`
- deny-all `AuthPolicy` exists on the gateway namespace when enabled
- at least one pod per application is `Running`

## Resolve route hosts

```bash
oc get route -n rhcl-apps banking-api-v1 -o jsonpath='{.spec.host}{"\n"}'
oc get route -n rhcl-apps banking-api-v2 -o jsonpath='{.spec.host}{"\n"}'
oc get route -n rhcl-apps mobile-bank -o jsonpath='{.spec.host}{"\n"}'
```

## Test backend routes

```bash
curl "http://$(oc get route -n rhcl-apps banking-api-v1 -o jsonpath='{.spec.host}')/api/v1/accounts/summary"
curl "http://$(oc get route -n rhcl-apps banking-api-v2 -o jsonpath='{.spec.host}')/api/v2/accounts/summary"
curl "http://$(oc get route -n rhcl-apps banking-api-v1 -o jsonpath='{.spec.host}')/api/echo"
```

Expected result:

- the v1 route returns the v1 account summary payload
- the v2 route returns the v2 account summary payload
- the echo endpoint returns request details

## Test backend HTTPS inside the cluster

When `APPS_BACKEND_TLS_ENABLED=true`, OpenShift creates serving-cert secrets for
the backend services and the pods mount them at `/etc/banking-tls`.

```bash
oc get secret -n rhcl-apps banking-api-v1-tls banking-api-v2-tls
oc get svc -n rhcl-apps banking-api-v1 -o jsonpath='{range .spec.ports[*]}{.name}{" "}{.port}{"\n"}{end}'

oc run -n rhcl-apps backend-https-curl --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  -- curl -sk https://banking-api-v1.rhcl-apps.svc:8443/mcp \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}'
```

Expected result:

- the serving-cert secrets contain `tls.crt` and `tls.key`
- the `https` service port is present
- the MCP initialize request returns the backend `banking-api` MCP server info

## Test backend TLS route (req 47)

When `APPS_BACKEND_TLS_ROUTE_ENABLED=true`:

```bash
TLS_HOST="$(oc get httproute -n rhcl-apps backend-tls -o jsonpath='{.spec.hostnames[0]}')"
curl -sk "https://${TLS_HOST}/api/tls/info" | jq '{isSSL,tlsVersion,cipherSuite,alpn,instance}'
```

Expected: `isSSL: true`, `tlsVersion` is `TLSv1.2` or `TLSv1.3`.

## Test the Gateway API connectivity link

Resolve the HTTPRoute hostname:

```bash
CONNECTIVITY_HOST="$(oc get httproute -n rhcl-apps banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}')"
echo "http://${CONNECTIVITY_HOST}"
```

Call both backend versions through the same HTTPRoute:

```bash
curl "http://${CONNECTIVITY_HOST}/api/v1/accounts/summary"
curl "http://${CONNECTIVITY_HOST}/api/v2/accounts/summary"
```

Expected result:

- `/api/v1` traffic reaches `banking-api-v1`
- `/api/v2` traffic reaches `banking-api-v2`

Run a quick rate limit check:

```bash
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" "http://${CONNECTIVITY_HOST}/api/v1/accounts/summary"
done
```

Expected result:

- requests over the configured `10` requests per `1s` limit return rate-limited responses

Check CORS headers served from HTTPRoute:

```bash
curl -i -X OPTIONS "http://${CONNECTIVITY_HOST}/api/v1/accounts/summary" \
  -H "Origin: https://example-client.local" \
  -H "Access-Control-Request-Method: GET"
```

Expected result:

- response includes `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and related CORS headers configured in inventory vars

## Verify HTTPS on the connectivity gateway

Only when `APPS_CONNECTIVITY_TLS_ENABLED=true`.

```bash
oc get tlspolicy -n openshift-ingress
oc get secret -n openshift-ingress rhcl-apps-gateway-tls
oc get gateway -n openshift-ingress rhcl-apps-gateway -o jsonpath='{.spec.listeners[*].protocol}{"\n"}'
```

Expected result:

- `TLSPolicy` `rhcl-apps-gateway-tls` exists and is `Accepted`/`Enforced`
- secret `rhcl-apps-gateway-tls` contains `tls.crt` and `tls.key`
- gateway listeners include both `HTTP` and `HTTPS`

Hit the HTTPS endpoint (skip cert validation only for staging issuers):

```bash
curl -k "https://${CONNECTIVITY_HOST}/api/v1/accounts/summary"
```

Expected result:

- the v1 backend responds over TLS

## Test the frontend route

Open the frontend route in a browser:

```bash
echo "http://$(oc get route -n rhcl-apps mobile-bank -o jsonpath='{.spec.host}')"
```

After opening the UI:

- set the primary backend to `http://<banking-api-v1-route>/api/v1/accounts/summary`
- set the secondary backend to `http://<banking-api-v2-route>/api/v2/accounts/summary`
- verify balance loading, transfer simulation, echo inspection, and WebSocket feed behavior

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/apps-remove.yml
```
