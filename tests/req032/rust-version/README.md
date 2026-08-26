# Request Logger WASM Plugin (Rust)

A minimal Proxy-Wasm HTTP filter for Envoy/Istio gateways. It logs each incoming request as human-readable JSON (method, path, authority, scheme, headers, body) and forwards the request unchanged.

## How It Works

```
Client → Gateway (Envoy) → [WASM Filter] → Upstream
                              ↓
                    warn! pretty JSON log
```

For each request the filter:

1. Collects pseudo-headers and all request headers
2. Waits for the full body when present (`Action::Pause` until `end_of_stream`)
3. Emits a single `warn!` log line with pretty-printed JSON
4. Always continues the request (`Action::Continue`)

## Project Structure

```
rust-version/
├── src/lib.rs
├── Cargo.toml
├── build.sh
├── rust-toolchain.toml
├── .cargo/config.toml
├── kubernetes/
│   └── envoyfilter-request-logger.yaml
└── README.md
```

## Building

From this directory:

```bash
cd rust-version
./build.sh
```

Output: `rust-version/target/wasm32-unknown-unknown/release/rust_request_logger.wasm`

`Cargo.toml` must keep `strip = false` in `[profile.release]` so Proxy-Wasm ABI exports are preserved.

Run unit tests (host target; required because `.cargo/config.toml` defaults to WASM):

```bash
cargo test --target "$(rustc -vV | sed -n 's/^host: //p')"
```

## Deployment

Run these commands from `rust-version/` (or adjust paths to the WASM artifact below).

### Step 1: Create ConfigMap with the WASM binary

```bash
oc create configmap request-logger-wasm \
  --from-file=policy.wasm=target/wasm32-unknown-unknown/release/request_logger.wasm \
  -n ingress-gateway
```

### Step 2: Mount in Gateway pods

```bash
GATEWAY_DEPLOYMENT=$(oc get deployment -n ingress-gateway -o jsonpath='{.items[0].metadata.name}')

oc patch deployment $GATEWAY_DEPLOYMENT -n ingress-gateway --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "request-logger-wasm", "configMap": {"name": "request-logger-wasm"}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
    "name": "request-logger-wasm", "mountPath": "/var/lib/envoy/rust-request-logger.wasm",
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
    "content-type": "application/json"
  },
  "body": "{\"key\":\"value\"}"
}
```

## Limitations

- **Observe-only**: never blocks or modifies requests
- Large bodies may be truncated by Envoy buffer settings
- Bodyless routes (e.g. some `direct_response` configs) log headers only; `body` is `null`

## Updating the WASM Binary

```bash
./build.sh
oc delete configmap request-logger-wasm -n ingress-gateway
oc create configmap request-logger-wasm \
  --from-file=policy.wasm=target/wasm32-unknown-unknown/release/request_logger.wasm \
  -n ingress-gateway
oc rollout restart deployment -n ingress-gateway
```

## References

- [Proxy-Wasm Rust SDK](https://github.com/proxy-wasm/proxy-wasm-rust-sdk)
- [Envoy WASM Filter docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/wasm_filter)
