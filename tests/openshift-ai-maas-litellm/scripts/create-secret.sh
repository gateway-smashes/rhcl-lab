#!/usr/bin/env bash
# Create the LiteLLM credential Secret without echoing the key to shell history.
set -euo pipefail

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
SECRET_NAME="${LITELLM_SECRET_NAME:-litellm-api-key}"

if [[ -n "${LITELLM_API_KEY:-}" ]]; then
  KEY="${LITELLM_API_KEY}"
else
  read -r -s -p "LiteLLM API key: " KEY
  echo
fi

if [[ -z "${KEY}" ]]; then
  echo "ERROR: empty API key" >&2
  exit 1
fi

oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -

oc -n "${NS}" create secret generic "${SECRET_NAME}" \
  --from-literal=api-key="${KEY}" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "${NS}" label secret "${SECRET_NAME}" \
  inference.networking.k8s.io/bbr-managed=true --overwrite

unset KEY LITELLM_API_KEY 2>/dev/null || true
echo "Secret ${NS}/${SECRET_NAME} applied."
