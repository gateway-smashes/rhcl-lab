#!/usr/bin/env bash
# Allow HTTPRoutes from external-models on the MaaS default gateway.
set -euo pipefail

GW_NS="${MAAS_GATEWAY_NAMESPACE:-openshift-ingress}"
GW_NAME="${MAAS_GATEWAY_NAME:-maas-default-gateway}"
MODELS_NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"

CURRENT=$(oc -n "${GW_NS}" get gateway "${GW_NAME}" \
  -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.selector.matchExpressions[0].values}' 2>/dev/null || true)

if echo "${CURRENT}" | grep -q "${MODELS_NS}"; then
  echo "Gateway ${GW_NS}/${GW_NAME} already allows namespace ${MODELS_NS}."
  exit 0
fi

VALUES=$(python3 - <<PY
import json
current = """${CURRENT}""".strip()
ns = "${MODELS_NS}"
vals = [v.strip() for v in current.split() if v.strip()] if current else []
if ns not in vals:
    vals.append(ns)
print(json.dumps(vals))
PY
)

oc -n "${GW_NS}" patch gateway "${GW_NAME}" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/allowedRoutes/namespaces/selector/matchExpressions/0/values\",\"value\":${VALUES}}]"

echo "Gateway ${GW_NS}/${GW_NAME} patched to allow ${MODELS_NS}."
