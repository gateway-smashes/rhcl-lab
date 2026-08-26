#!/usr/bin/env bash
# ExternalModel HTTPRoute matches /external-models/<name> but LiteLLM expects /v1/...
# Without ReplacePrefixMatch the upstream returns {"detail":"Not Found"}.
set -euo pipefail

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
NAME="${EXTERNAL_MODEL_NAME:-deepseek-r1-distill-qwen-14b-external}"

echo "Waiting for HTTPRoute ${NS}/${NAME}..."
for i in $(seq 1 30); do
  if oc -n "${NS}" get httproute "${NAME}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! oc -n "${NS}" get httproute "${NAME}" >/dev/null 2>&1; then
  echo "HTTPRoute ${NS}/${NAME} not found; skip rewrite patch."
  exit 0
fi

if oc -n "${NS}" get httproute "${NAME}" -o json \
  | jq -e '.spec.rules[0].filters[]? | select(.type=="URLRewrite")' >/dev/null 2>&1; then
  echo "HTTPRoute ${NS}/${NAME} already has URLRewrite."
  exit 0
fi

echo "Patching HTTPRoute ${NS}/${NAME} → ReplacePrefixMatch /external-models/${NAME} → /"
oc -n "${NS}" patch httproute "${NAME}" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/rules/0/filters/-",
    "value": {
      "type": "URLRewrite",
      "urlRewrite": {
        "path": {
          "type": "ReplacePrefixMatch",
          "replacePrefixMatch": "/"
        }
      }
    }
  }
]'
