# RHOAI Assistant

Standalone chat application (Flutter + Quarkus) integrated with **Red Hat OpenShift AI**
via an **OpenAI-compatible** MaaS LiteLLM gateway.

## Components

| Path | Role |
| --- | --- |
| `backend/` | Quarkus API — conversations, SSE streaming, model catalog, routing, fallback |
| `frontend/` | Flutter Web — chat UI + model catalog (nginx proxies `/api` to backend) |

## Architecture

```
Browser → Route (rhoai-assistant-frontend) → nginx /api → rhoai-assistant-backend
    → OpenShift MaaS gateway (/external-models/<name>/v1) per ExternalModel CR
```

The backend discovers models by listing **ExternalModel** and **MaaSModelRef** CRs in
`external-models`, then calls each model's MaaS endpoint with a **MaaS API key**
(`sk-oai-...`). The **Select model** tab lists cluster External Models and switches
the active model for chat.

## Local development

### Backend

```bash
cd backend
export MAAS_API_KEY='sk-...'
export MAAS_BASE_URL='https://maas-rhdp.apps.maas.redhatworkshops.io/v1'
export MAAS_MODEL='qwen3-14b'
mvn quarkus:dev
```

### Frontend

```bash
cd frontend
flutter pub get
# Point a local proxy at :8080 or run behind nginx; for quick UI test:
flutter run -d chrome
```

## Deploy on OpenShift (Ansible)

From `automation/`:

```bash
export APPS_RHOAI_ENABLED=true
export APPS_RHOAI_CATALOG_SOURCE=external-models
export APPS_RHOAI_EXTERNAL_MODELS_NAMESPACE=external-models
export APPS_RHOAI_MAAS_API_KEY='sk-oai-...'   # optional in-cluster (SA token preferred)

ansible-playbook playbooks/apps-install.yml
bash ../apps/rhoai-assistant/openshift/patch-external-model-maas-auth.sh
ansible-playbook playbooks/apps-test.yml
```

Open the UI:

```bash
oc get route rhoai-assistant-frontend -n rhcl-apps -o jsonpath='https://{.spec.host}{"\n"}'
```

## API smoke test

```bash
ROUTE=$(oc get route rhoai-assistant-frontend -n rhcl-apps -o jsonpath='{.spec.host}')

# Create conversation
CONV=$(curl -s -X POST "https://${ROUTE}/api/v1/conversations" \
  -H 'Content-Type: application/json' \
  -d '{"title":"test","requestedModel":"auto"}' | jq -r .id)

# Send message
REQ=$(curl -s -X POST "https://${ROUTE}/api/v1/conversations/${CONV}/messages" \
  -H 'Content-Type: application/json' \
  -d '{"content":"Hello"}' | jq -r .requestId)

# Stream SSE
curl -N "https://${ROUTE}/api/v1/conversations/${CONV}/stream?requestId=${REQ}"
```

## Features (Phases 1–2)

- Chat with streaming SSE (`model.selected`, `message.delta`, `usage.completed`, `message.completed`)
- Manual or automatic model selection
- Model catalog with health status
- Fallback chain when primary model fails
- Model change events (`model.changed`)
- In-memory persistence (conversations reset on pod restart)

## Out of scope (later phases)

- Usage/cost dashboard, Prometheus cost metrics
- Model Registry sync, Azure/IBM live adapters
- Database persistence
