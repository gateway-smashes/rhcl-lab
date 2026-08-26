# mock-api

Small Node.js HTTP server for integration tests: configurable **status codes**, **response body**, **extra headers**, **artificial delay** (timeout testing), and **CORS**. Everything is controlled with **environment variables** read at process startup.

Requires **Node.js 20+**.

## Quick start

```bash
npm start
```

Default listen port is **8080**. Open another terminal:

```bash
curl -sS -i http://127.0.0.1:8080/health
```

You should see `HTTP/1.1 200` and a JSON body `{"status":"ok"}`.

## How it behaves

| Request | Behavior |
|--------|----------|
| `GET /health` | Always **200** and `{"status":"ok"}`. **No** mock delay, so it is safe for Kubernetes/OpenShift liveness and readiness probes. |
| `OPTIONS` | If `CORS_ENABLED` is true: **204** with CORS headers and `Access-Control-Max-Age`. **No** mock delay. |
| Any other method/path | After optional `DELAY_MS`, returns the configured status, `Content-Type`, body, CORS headers (if enabled), and any headers from `RESPONSE_HEADERS`. |

**Body source:** If `RESPONSE_BODY_FILE` is set, the file is read **once at startup** and that buffer is used for every mock response. Otherwise `RESPONSE_BODY` is used (default empty string if unset). For large or JSON bodies, prefer a file (e.g. mounted from a ConfigMap in OpenShift).

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | TCP port to listen on. |
| `HTTP_STATUS` | `200` | HTTP status code for mock responses (not used for `/health` or CORS `OPTIONS`). |
| `RESPONSE_BODY` | *(empty)* | Response body as a UTF-8 string. Ignored if `RESPONSE_BODY_FILE` is set. |
| `RESPONSE_BODY_FILE` | *(unset)* | Path to a file whose contents become the response body (read at startup). |
| `CONTENT_TYPE` | `text/plain; charset=utf-8` | `Content-Type` for mock responses. Use `application/json; charset=utf-8` for JSON. |
| `DELAY_MS` | `0` | Milliseconds to wait before sending each mock response (not applied to `/health` or CORS `OPTIONS`). Use this to trigger client read timeouts. |
| `RESPONSE_HEADERS` | *(empty)* | JSON object of extra headers, e.g. `{"X-Custom":"1","Cache-Control":"no-store"}`. Invalid JSON is ignored. Keys in this object can override `Content-Type` if repeated. |
| `CORS_ENABLED` | `false` | Set to `true`, `1`, or `yes` to enable CORS on mock responses and handle `OPTIONS`. |
| `ACCESS_CONTROL_ALLOW_ORIGIN` | `*` | `Access-Control-Allow-Origin` when CORS is enabled. |
| `ACCESS_CONTROL_ALLOW_METHODS` | `GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS` | `Access-Control-Allow-Methods`. |
| `ACCESS_CONTROL_ALLOW_HEADERS` | `Content-Type,Authorization` | `Access-Control-Allow-Headers`. |
| `ACCESS_CONTROL_ALLOW_CREDENTIALS` | `false` | Set to `true` / `1` / `yes` to send `Access-Control-Allow-Credentials: true`. |
| `LOG_LEVEL` | `info` | Use `silent` to suppress routine logs (errors still print). |

Examples:

```bash
HTTP_STATUS=503 CONTENT_TYPE=application/json RESPONSE_BODY='{"error":"upstream"}' npm start
```

```bash
DELAY_MS=30000 npm start
```

```bash
CORS_ENABLED=true ACCESS_CONTROL_ALLOW_ORIGIN=https://app.example.com npm start
```

## Local checks with curl

Use one terminal for the server and one for `curl`.

1. **Health**

   ```bash
   curl -sS -i http://127.0.0.1:8080/health
   ```

   Expect **200** and JSON `{"status":"ok"}`.

2. **Custom status and body**

   ```bash
   HTTP_STATUS=418 CONTENT_TYPE=text/plain RESPONSE_BODY=teapot npm start
   ```

   ```bash
   curl -sS -i http://127.0.0.1:8080/
   ```

   Expect **418**, body `teapot`, and `Content-Type: text/plain`.

3. **Extra headers**

   ```bash
   RESPONSE_HEADERS='{"X-Mock":"1","Cache-Control":"no-store"}' npm start
   ```

   ```bash
   curl -sS -i http://127.0.0.1:8080/
   ```

4. **CORS preflight**

   ```bash
   CORS_ENABLED=true ACCESS_CONTROL_ALLOW_ORIGIN=https://app.example npm start
   ```

   ```bash
   curl -sS -i -X OPTIONS http://127.0.0.1:8080/ \
     -H "Origin: https://app.example" \
     -H "Access-Control-Request-Method: POST"
   ```

   Expect **204** and `Access-Control-*` headers matching your env.

5. **Delay / timeout**

   ```bash
   DELAY_MS=3000 npm start
   ```

   ```bash
   curl -sS -i --max-time 1 http://127.0.0.1:8080/
   ```

   Expect curl to fail with a timeout (often exit code **28**).

   ```bash
   curl -sS -i --max-time 5 http://127.0.0.1:8080/
   ```

   Expect a successful response after about three seconds.

## Container image

Build and push with **Podman** (Quay.io example). Log in once if you have not already:

```bash
podman login quay.io
```

```bash
podman build -t quay.io/jsimas/mock-api:latest .
podman push quay.io/jsimas/mock-api:latest
```

The image runs as a non-root user and listens on port **8080** by default.

If you use Docker instead, the same `build` / `push` commands work with `docker` in place of `podman`.

## OpenShift

Example manifests live under [`openshift/deployment.yaml`](openshift/deployment.yaml): `ConfigMap`, `Deployment`, and `Service`. Adjust the namespace, image tag, and ConfigMap values, then apply:

```bash
oc apply -n <your-namespace> -f openshift/deployment.yaml
```

Tune mock behavior by editing the `mock-api-config` ConfigMap (or by using `env` / `envFrom` with a Secret for sensitive values) and rolling the Deployment.

For routes and in-cluster testing, see the commented `Route` example in the same file.
