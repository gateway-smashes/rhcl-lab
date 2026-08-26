# OpenShift deployment (Kustomize)

This directory provides a simple and ArgoCD-friendly structure:

- `kustomize/base`: reusable manifests
- `kustomize/overlays/dev`: dev customization (namespace, image tags)
- `kustomize/overlays/prod`: prod customization (namespace, image tags)

## Why this approach

- Easy to apply now with `oc apply -k`
- Easy to adopt with ArgoCD later (point ArgoCD app to an overlay path)
- Clear separation between shared resources and environment-specific changes

## 1) Build and push images

Image builds are configured to run automatically on Quay.

- Merge `main` into branch `frontend` to trigger frontend image build.
- Merge `main` into branch `backend` to trigger backend image build.

If the automatic build does not start, follow the manual build/push procedure below.

Use `podman` to build and push images to Quay (fallback/manual flow).

Suggested image names:
- `quay.io/hodrigohamalho/red-bank-backend:latest`
- `quay.io/hodrigohamalho/red-bank-frontend:latest`

Login:

```bash
podman login quay.io
```

Build `dev` images:

```bash
# Backend
podman build -t quay.io/hodrigohamalho/red-bank-backend:dev apps/backend/banking-api

# Frontend
podman build -t quay.io/hodrigohamalho/red-bank-frontend:dev \
  --build-arg PRIMARY_BACKEND_URL="https://<backend-route>/api/v1/accounts/summary" \
  --build-arg SECONDARY_BACKEND_URL="https://<backend-route>/api/v2/accounts/summary" \
  --build-arg DEFAULT_FLOW_MODE="round_robin" \
  apps/frontend/mobile-bank
```

Push `dev` images:

```bash
podman push quay.io/hodrigohamalho/red-bank-backend:dev
podman push quay.io/hodrigohamalho/red-bank-frontend:dev
```

For `prod`, build/push the same images with `:prod` tag.

### Copy/paste examples

Dev (local backends):

```bash
podman build -t quay.io/hodrigohamalho/red-bank-backend:dev apps/backend/banking-api

podman build -t quay.io/hodrigohamalho/red-bank-frontend:dev \
  --build-arg PRIMARY_BACKEND_URL="http://localhost:8080/api/v1/accounts/summary" \
  --build-arg SECONDARY_BACKEND_URL="http://localhost:8081/api/v2/accounts/summary" \
  --build-arg DEFAULT_FLOW_MODE="round_robin" \
  apps/frontend/mobile-bank

podman push quay.io/hodrigohamalho/red-bank-backend:dev
podman push quay.io/hodrigohamalho/red-bank-frontend:dev
```

Dev (OpenShift route already available):

```bash
BACKEND_HOST=$(oc get route red-bank-backend -n red-bank-dev -o jsonpath='{.spec.host}')

podman build -t quay.io/hodrigohamalho/red-bank-frontend:dev \
  --build-arg PRIMARY_BACKEND_URL="https://${BACKEND_HOST}/api/v1/accounts/summary" \
  --build-arg SECONDARY_BACKEND_URL="https://${BACKEND_HOST}/api/v2/accounts/summary" \
  --build-arg DEFAULT_FLOW_MODE="round_robin" \
  apps/frontend/mobile-bank

podman push quay.io/hodrigohamalho/red-bank-frontend:dev
```

Prod:

```bash
BACKEND_HOST=$(oc get route red-bank-backend -n red-bank-prod -o jsonpath='{.spec.host}')

podman build -t quay.io/hodrigohamalho/red-bank-backend:prod apps/backend/banking-api

podman build -t quay.io/hodrigohamalho/red-bank-frontend:prod \
  --build-arg PRIMARY_BACKEND_URL="https://${BACKEND_HOST}/api/v1/accounts/summary" \
  --build-arg SECONDARY_BACKEND_URL="https://${BACKEND_HOST}/api/v2/accounts/summary" \
  --build-arg DEFAULT_FLOW_MODE="round_robin" \
  apps/frontend/mobile-bank

podman push quay.io/hodrigohamalho/red-bank-backend:prod
podman push quay.io/hodrigohamalho/red-bank-frontend:prod
```

## 2) Deploy to OpenShift

Login:

```bash
oc login https://api.<your-cluster>:6443
```

Dev:

```bash
oc apply -k deploy/kustomize/overlays/dev
```

Prod:

```bash
oc apply -k deploy/kustomize/overlays/prod
```

Optional rollout checks:

```bash
oc rollout status deploy/red-bank-backend -n red-bank-dev
oc rollout status deploy/red-bank-frontend -n red-bank-dev
```

## 3) Verify

```bash
oc get all -n red-bank-dev
oc get route -n red-bank-dev
```

Get route URLs:

```bash
oc get route red-bank-frontend -n red-bank-dev -o jsonpath='{.spec.host}{"\n"}'
oc get route red-bank-backend -n red-bank-dev -o jsonpath='{.spec.host}{"\n"}'
```

Smoke test backend API:

```bash
BACKEND_HOST=$(oc get route red-bank-backend -n red-bank-dev -o jsonpath='{.spec.host}')
curl -k "https://${BACKEND_HOST}/api/v1/accounts/summary"
```

Smoke test WebSocket endpoint:

```bash
BACKEND_HOST=$(oc get route red-bank-backend -n red-bank-dev -o jsonpath='{.spec.host}')
# Requires a websocket client like wscat
wscat -c "wss://${BACKEND_HOST}/ws/live"
```

## Notes

- Backend `Route` exposes HTTP APIs and WebSocket endpoint (`/ws/live`) on the same service.
- Frontend route exposes the Flutter web app.
- Route host is intentionally omitted so OpenShift can auto-generate hostnames.