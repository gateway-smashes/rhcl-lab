#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/models.sh
source "${ROOT}/scripts/models.sh"

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
SECRET_NAME="${LITELLM_SECRET_NAME:-litellm-api-key}"

oc apply -f "${ROOT}/manifests/00-namespace.yaml"

if ! oc -n "${NS}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  echo "Secret ${NS}/${SECRET_NAME} not found."
  echo "Run: ${ROOT}/scripts/create-secret.sh"
  echo "Or export LITELLM_API_KEY and re-run this script."
  if [[ -z "${LITELLM_API_KEY:-}" ]]; then
    exit 1
  fi
  bash "${ROOT}/scripts/create-secret.sh"
fi

bash "${ROOT}/scripts/patch-maas-gateway.sh"

for manifest in "${ROOT}"/manifests/*-external-model.yaml; do
  echo "Applying ${manifest}..."
  oc apply -f "${manifest}"
done

# MaaS controller creates HTTPRoutes without path rewrite; patch after reconcile.
while IFS= read -r model; do
  echo "Waiting for HTTPRoute ${NS}/${model}..."
  for _ in $(seq 1 30); do
    oc -n "${NS}" get httproute "${model}" >/dev/null 2>&1 && break
    sleep 2
  done
  EXTERNAL_MODEL_NAME="${model}" bash "${ROOT}/scripts/patch-httproute-rewrite.sh"
  EXTERNAL_MODEL_NAME="${model}" bash "${ROOT}/scripts/patch-httproute-upstream-auth.sh"
done < <(req024_model_names)

# Optional: BBR ext_proc anchor fix (maas-api operator may revert; HTTPRoute inject above is the PoC workaround)
bash "${ROOT}/scripts/patch-payload-processing-envoyfilter.sh" || true

echo "REQ 024 manifests applied. Validate with: ${ROOT}/scripts/validate.sh"
