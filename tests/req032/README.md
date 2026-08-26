# Request Logger WASM Plugin

Observe-only Proxy-Wasm HTTP filters for Envoy/Istio gateways. Each incoming request is logged once as pretty-printed JSON (method, path, authority, scheme, headers, body) and forwarded unchanged.

```
Client → Gateway (Envoy) → [WASM Filter] → Upstream
                              ↓
                    request-logger: JSON log
```

## Implementations

| | [rust-version](rust-version/) | [go-version](go-version/) |
|---|-------------------------------|---------------------------|
| Language | Rust | Go |
| SDK | [proxy-wasm-rust-sdk](https://github.com/proxy-wasm/proxy-wasm-rust-sdk) | [proxy-wasm-go-sdk](https://github.com/proxy-wasm/proxy-wasm-go-sdk) |
| Build | `./build.sh` (wasm32-unknown-unknown) | `./build.sh` (GOOS=wasip1) |
| Go / Rust version | Rust stable | Go 1.24+ |
| Envoy minimum | Broad (V8 runtime) | **Envoy ≥ 1.33** (WASI reactor) |
| Log prefix | `request-logger:` | `request-logger:` |

Pick one implementation and follow its README for build and Kubernetes deployment.

## Example log output

Both versions emit the same JSON shape:

```json
{
  "method": "POST",
  "path": "/api/foo",
  "authority": "gateway.example.com",
  "scheme": "https",
  "headers": { ":method": "POST", "content-type": "application/json" },
  "body": "{\"key\":\"value\"}"
}
```

## Verify in cluster

```bash
oc logs -n ingress-gateway -l gateway.istio.io/managed=istio.io-gateway-controller --tail=50 | \
  grep "request-logger:"
```
