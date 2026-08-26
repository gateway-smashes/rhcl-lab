#!/usr/bin/env bash
# Apply MaaS API-key AuthPolicies to External Model HTTPRoutes (lab fix when maas-controller
# did not attach them). Clones rules from redhat-ods-applications/maas-api-auth-policy.
set -euo pipefail

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
SRC_NS="${MAAS_API_SRC_NAMESPACE:-redhat-ods-applications}"
SRC_POLICY="${MAAS_API_AUTH_POLICY:-maas-api-auth-policy}"

MODELS="${EXTERNAL_MODEL_NAMES:-deepseek-r1-distill-qwen-14b-external llama-31-70b-external llama-scout-17b-external}"

rules_json="$(oc get authpolicy "$SRC_POLICY" -n "$SRC_NS" -o json | jq -c '.spec.rules')"

for name in $MODELS; do
  echo "Applying AuthPolicy ${name}-maas-auth in ${NS}"
  oc -n "$NS" create authpolicy "${name}-maas-auth" --dry-run=client -o json | jq \
    --arg name "$name" --argjson rules "$rules_json" \
    '.spec = {targetRef: {group: "gateway.networking.k8s.io", kind: "HTTPRoute", name: $name}, rules: $rules}' \
    | oc apply -f -
done

echo "Done. Restart MaaS gateway if policies do not enforce immediately:"
echo "  oc rollout restart deploy/maas-default-gateway-data-science-gateway-class -n openshift-ingress"
