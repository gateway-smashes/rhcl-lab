# Request Logger WASM Plugin (Go)

A minimal Proxy-Wasm HTTP filter for Envoy/Istio gateways. It logs each incoming request as human-readable JSON (method, path, authority, scheme, headers, body) and forwards the request unchanged. Supports optional sensitive-header obfuscation via plugin configuration.

**Requires Envoy ≥ 1.33** (WASI reactor host support used by the official [proxy-wasm-go-sdk](https://github.com/proxy-wasm/proxy-wasm-go-sdk)).

## Project Structure

```
go-version/
├── main.go
├── structures.go
├── go.mod
├── build.sh
├── Containerfile.wasm
├── kubernetes/
│   └── envoyfilter-request-logger.yaml
└── README.md
```

## Prerequisites

- Go 1.24 or later

## Building

```bash
cd go-version
go mod tidy
./build.sh
```

Output: `go-version/request_logger.wasm`

## Deployment

Run these commands from `go-version/`.

### Step 1: Create ConfigMap with the WASM binary

```bash
oc create configmap request-logger-wasm \
  --from-file=policy.wasm=request_logger.wasm \
  -n ingress-gateway
```

### Step 2: Mount in Gateway pods

```bash
GATEWAY_DEPLOYMENT=$(oc get deployment -n ingress-gateway -o jsonpath='{.items[0].metadata.name}')

oc patch deployment $GATEWAY_DEPLOYMENT -n ingress-gateway --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "request-logger-wasm", "configMap": {"name": "request-logger-wasm"}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
    "name": "request-logger-wasm", "mountPath": "/var/lib/envoy/request-logger.wasm",
    "subPath": "policy.wasm", "readOnly": true}}
]'
```

### Step 3: Apply EnvoyFilter

```bash
oc apply -f kubernetes/envoyfilter-request-logger.yaml
```

### Step 4: Restart Gateway

```bash
oc rollout restart deployment -n ingress-gateway
```

### Verify

```bash
oc logs -n ingress-gateway -l gateway.istio.io/managed=istio.io-gateway-controller --tail=50 | \
  grep "request-logger:"
```

## Example Log Output

Without sensitive-header configuration (default):

```json
{
  "method": "POST",
  "path": "/api/foo",
  "authority": "gateway.example.com",
  "scheme": "https",
  "headers": {
    ":authority": "gateway.example.com",
    ":method": "POST",
    ":path": "/api/foo",
    ":scheme": "https",
    "authorization": "Bearer eyJhbGciOi...",
    "content-type": "application/json",
    "cookie": "session=abc123"
  },
  "body": "{\"key\":\"value\"}"
}
```

With `sensitive_headers` configured (see section below):

```json
{
  "method": "POST",
  "path": "/api/foo",
  "authority": "gateway.example.com",
  "scheme": "https",
  "headers": {
    ":authority": "gateway.example.com",
    ":method": "POST",
    ":path": "/api/foo",
    ":scheme": "https",
    "authorization": "***",
    "content-type": "application/json",
    "cookie": "***"
  },
  "body": "{\"key\":\"value\"}"
}
```

## Sensitive Header Obfuscation

The plugin accepts an optional JSON configuration via the EnvoyFilter `configuration` field. When a list of sensitive headers is provided, their values are replaced with `"***"` in the log output. The actual HTTP request is **never modified**.

When no configuration is provided the plugin behaves exactly as before — all header values are logged in cleartext.

### Configuration format

```json
{"sensitive_headers": ["authorization", "cookie", "set-cookie", "x-api-key"]}
```

Header matching is **case-insensitive** (`Authorization`, `AUTHORIZATION`, and `authorization` all match).

### EnvoyFilter example

```yaml
typed_config:
  "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
  config:
    name: request-logger
    root_id: request_logger_root
    configuration:
      "@type": type.googleapis.com/google.protobuf.StringValue
      value: '{"sensitive_headers":["authorization","cookie","set-cookie","x-api-key"]}'
    vm_config:
      vm_id: request_logger_vm
      runtime: envoy.wasm.runtime.v8
      code:
        local:
          filename: /var/lib/wasm-plugins/request-logger.wasm
```

## Alternative Deployment: Init Container (large WASM binaries)

Kubernetes ConfigMaps have a 1 MB size limit. If your WASM binary exceeds this (e.g. standard Go compiler output is ~3 MB), you can use an init container to deliver the file instead.

This approach stores the WASM inside an OCI image on Quay.io, then copies it into the pod at startup via a shared `emptyDir` volume.

### Step 1: Build and push the WASM image to Quay.io

```bash
IMAGE=quay.io/jsimas/request-logger-wasm:1.2   # increment tag on each rebuild

podman build -t $IMAGE -f Containerfile.wasm .
podman push $IMAGE
```

> **Note:** Run `podman login quay.io` first if you haven't authenticated.

### Step 2: Patch the gateway deployment with an init container

```bash
GATEWAY_DEPLOYMENT=$(oc get deployment -n $GATEWAY_NAMESPACE \
  -l gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME \
  -o jsonpath='{.items[0].metadata.name}')

oc patch deployment $GATEWAY_DEPLOYMENT -n $GATEWAY_NAMESPACE --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/initContainers", "value": [{
    "name": "copy-wasm-plugin",
    "image": "'$IMAGE'",
    "command": ["/usr/bin/cp", "/plugin.wasm", "/wasm/request-logger.wasm"],
    "volumeMounts": [{"name": "wasm-plugins", "mountPath": "/wasm"}]
  }]},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "wasm-plugins", "emptyDir": {}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
    "name": "wasm-plugins", "mountPath": "/var/lib/wasm-plugins", "readOnly": true}}
]'
```

> If your Quay.io repository is private, create an image pull secret and reference it in the deployment's `imagePullSecrets`.

### Step 3: Apply EnvoyFilter

Use the same EnvoyFilter but point `filename` to the init container path:

```yaml
code:
  local:
    filename: /var/lib/wasm-plugins/request-logger.wasm
```

```bash
oc apply -f kubernetes/envoyfilter-request-logger.yaml
```

> **Note:** Edit the EnvoyFilter's `filename` field to `/var/lib/wasm-plugins/request-logger.wasm` if it differs from the ConfigMap mount path.

### Updating the WASM (init container method)

```bash
./build.sh
IMAGE=quay.io/jsimas/request-logger-wasm:1.x   # increment tag
podman build -t $IMAGE -f Containerfile.wasm .
podman push $IMAGE
oc set image deployment/$GATEWAY_DEPLOYMENT -n $GATEWAY_NAMESPACE copy-wasm-plugin=$IMAGE
oc rollout restart deployment/$GATEWAY_DEPLOYMENT -n $GATEWAY_NAMESPACE
```

## Limitations

- **Observe-only**: never blocks or modifies requests
- Large bodies may be truncated by Envoy buffer settings
- Bodyless requests log headers only; `body` is omitted (`null` in JSON when marshaled with explicit null — absent fields match Rust `null` for optional authority/scheme/body)

## Updating the WASM Binary

```bash
./build.sh
oc delete configmap request-logger-wasm -n ingress-gateway
oc create configmap request-logger-wasm \
  --from-file=policy.wasm=request_logger.wasm \
  -n ingress-gateway
oc rollout restart deployment -n ingress-gateway
```

## References

- [Proxy-Wasm Go SDK](https://github.com/proxy-wasm/proxy-wasm-go-sdk)
- [Envoy WASM Filter docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/wasm_filter)
