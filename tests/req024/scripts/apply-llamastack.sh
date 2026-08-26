#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"

oc apply -f "${ROOT}/manifests/00-namespace.yaml"

mapfile -t EXISTING_LSD < <(oc -n "${NS}" get llamastackdistribution \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ ${#EXISTING_LSD[@]} -gt 0 ]]; then
  echo "Found existing LlamaStackDistribution in ${NS}: ${EXISTING_LSD[*]}"
  echo "Patching in place (userConfig → rhcl-llamastack-config)..."
  bash "${ROOT}/scripts/patch-llamastack-distribution.sh"
  exit 0
fi

echo "No LlamaStackDistribution in ${NS}; greenfield install..."
if [[ "${LLAMASTACK_UI_PLAYGROUND:-}" == "true" ]]; then
  echo "LLAMASTACK_UI_PLAYGROUND=true — skipping manifest 41 (use dashboard Create playground)."
  echo "Run: ${ROOT}/scripts/prepare-ui-playground.sh"
  exec bash "${ROOT}/scripts/prepare-ui-playground.sh"
fi
 PG_SECRET="${LLAMASTACK_POSTGRES_SECRET_NAME:-llamastack-postgres}"
MAAS_SECRET="${LLAMASTACK_MAAS_SECRET_NAME:-llamastack-maas-api-key}"
CM_NAME="${LLAMASTACK_CONFIGMAP_NAME:-rhcl-llamastack-config}"

if ! oc -n "${NS}" get secret "${PG_SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NS}/${PG_SECRET} not found."
  echo "Run: ${ROOT}/scripts/create-llamastack-postgres-secret.sh"
  if [[ -z "${LLAMASTACK_POSTGRES_PASSWORD:-}" ]]; then
    exit 1
  fi
  bash "${ROOT}/scripts/create-llamastack-postgres-secret.sh"
fi

if ! oc -n "${NS}" get secret "${MAAS_SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NS}/${MAAS_SECRET} not found."
  echo "Run: ${ROOT}/scripts/create-maas-api-key-secret.sh"
  if [[ -z "${MAAS_API_KEY:-}" ]]; then
    exit 1
  fi
  bash "${ROOT}/scripts/create-maas-api-key-secret.sh"
fi

echo "Applying ConfigMap ${NS}/${CM_NAME} from manifests/llamastack/config.yaml"
oc -n "${NS}" create configmap "${CM_NAME}" \
  --from-file=config.yaml="${ROOT}/manifests/llamastack/config.yaml" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f "${ROOT}/manifests/40-llamastack-postgres.yaml"
oc apply -f "${ROOT}/manifests/41-llamastack-distribution.yaml"

echo "Waiting for LlamaStackDistribution..."
for _ in $(seq 1 60); do
  phase="$(oc -n "${NS}" get llamastackdistribution rhcl-maas-external-models \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Ready" ]] && break
  sleep 5
done

oc -n "${NS}" get llamastackdistribution rhcl-maas-external-models
oc -n "${NS}" get pods -l app.kubernetes.io/part-of=rhcl-req024-llamastack
echo "Validate logs: oc -n ${NS} logs -l app.kubernetes.io/part-of=rhcl-req024-llamastack --tail=50"
