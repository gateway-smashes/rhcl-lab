#!/usr/bin/env bash
# Inject the LiteLLM (upstream) API key on the ExternalModel HTTPRoute.
#
# On OpenShift's gateway controller the default payload-processing EnvoyFilter
# anchors on a non-existent WasmPlugin name, and even when ext_proc is present
# it is ordered *before* the Kuadrant wasm filter (auth). BBR then replaces the
# MaaS key before Authorino runs, or Authorino re-checks the rewritten path with
# the upstream key and returns 401.
#
# Workaround: after Kuadrant validates the client MaaS key on
# /external-models/<name>/..., the HTTPRoute RequestHeaderModifier replaces
# Authorization with the provider key from the bbr-managed Secret.
set -euo pipefail

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
NAME="${EXTERNAL_MODEL_NAME:-deepseek-r1-distill-qwen-14b-external}"
SECRET="${LITELLM_SECRET_NAME:-litellm-api-key}"
UPSTREAM_HOST="${LITELLM_UPSTREAM_HOST:-maas-rhdp.apps.maas.redhatworkshops.io}"

echo "Waiting for HTTPRoute ${NS}/${NAME}..."
for i in $(seq 1 30); do
  oc -n "${NS}" get httproute "${NAME}" >/dev/null 2>&1 && break
  sleep 2
done

if ! oc -n "${NS}" get httproute "${NAME}" >/dev/null 2>&1; then
  echo "HTTPRoute ${NS}/${NAME} not found; skip upstream auth patch."
  exit 0
fi

if ! oc -n "${NS}" get secret "${SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NS}/${SECRET} not found. Run scripts/create-secret.sh first."
  exit 1
fi

LITELLM_KEY="$(oc -n "${NS}" get secret "${SECRET}" -o jsonpath='{.data.api-key}' | base64 -d)"
if [[ -z "${LITELLM_KEY}" ]]; then
  echo "Secret ${NS}/${SECRET} has no api-key field."
  exit 1
fi

CURRENT="$(oc -n "${NS}" get httproute "${NAME}" -o json \
  | jq -r --arg k "${LITELLM_KEY}" '.spec.rules[0].filters[]?
    | select(.type=="RequestHeaderModifier")
    | .requestHeaderModifier.set[]
    | select(.name=="Authorization")
    | .value' 2>/dev/null || true)"
if [[ "${CURRENT}" == "Bearer ${LITELLM_KEY}" ]]; then
  echo "HTTPRoute ${NS}/${NAME} already has upstream Authorization inject."
  exit 0
fi

echo "Patching HTTPRoute ${NS}/${NAME} → Authorization: Bearer <litellm-api-key>"
oc -n "${NS}" patch httproute "${NAME}" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/filters/0/requestHeaderModifier/set\",\"value\":[
    {\"name\":\"Host\",\"value\":\"${UPSTREAM_HOST}\"},
    {\"name\":\"Authorization\",\"value\":\"Bearer ${LITELLM_KEY}\"}
  ]}
]"

echo "Done. Client requests still use the MaaS key (sk-oai-...); upstream uses LiteLLM."
