#!/usr/bin/env bash
# Fix BBR (payload-processing) ext_proc placement on the MaaS gateway.
#
# NOTE: On OpenShift the maas-api operator reconciles this EnvoyFilter back to
# an anchor that does not exist (extensions.istio.io/wasmplugin/...). Even when
# ext_proc is present, creation order often places it *before* Kuadrant wasm
# auth. For a reliable PoC fix use patch-httproute-upstream-auth.sh instead.
#
# The default EnvoyFilter anchors on
#   extensions.istio.io/wasmplugin/openshift-ingress.kuadrant-maas-default-gateway
# which does not exist on OpenShift's gateway controller (Kuadrant uses
# envoy.filters.http.wasm). Without ext_proc in the filter chain, the MaaS API
# key (sk-oai-...) is forwarded to the upstream LiteLLM instead of the provider
# key from the bbr-managed Secret — LiteLLM then returns 401
# "Malformed API Key passed in".
#
# This patch inserts ext_proc immediately before the router filter. Re-run after
# maas-api reconciliation and restart the gateway deployment if ext_proc is missing.
set -euo pipefail

EF_NS="${MAAS_GATEWAY_NAMESPACE:-openshift-ingress}"
EF_NAME="${PAYLOAD_PROCESSING_ENVOYFILTER:-payload-processing}"

if ! oc -n "${EF_NS}" get envoyfilter "${EF_NAME}" >/dev/null 2>&1; then
  echo "EnvoyFilter ${EF_NS}/${EF_NAME} not found — is MaaS / payload-processing installed?"
  exit 1
fi

CURRENT_OP=$(oc -n "${EF_NS}" get envoyfilter "${EF_NAME}" \
  -o jsonpath='{.spec.configPatches[0].patch.operation}')
CURRENT_ANCHOR=$(oc -n "${EF_NS}" get envoyfilter "${EF_NAME}" \
  -o jsonpath='{.spec.configPatches[0].match.listener.filterChain.filter.subFilter.name}')

if [[ "${CURRENT_OP}" == "INSERT_BEFORE" && "${CURRENT_ANCHOR}" == "envoy.filters.http.router" ]]; then
  echo "EnvoyFilter ${EF_NS}/${EF_NAME} already patched (INSERT_BEFORE router)."
  exit 0
fi

echo "Patching ${EF_NS}/${EF_NAME}: anchor -> envoy.filters.http.router, operation -> INSERT_BEFORE"
oc patch envoyfilter "${EF_NAME}" -n "${EF_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/configPatches/0/match/listener/filterChain/filter/subFilter/name","value":"envoy.filters.http.router"},
  {"op":"replace","path":"/spec/configPatches/0/patch/operation","value":"INSERT_BEFORE"}
]'

echo "Waiting for gateway to reconcile (15s)..."
sleep 15
echo "Done. Re-test inference with model=deepseek-r1-distill-qwen-14b (targetModel) in the JSON body."
