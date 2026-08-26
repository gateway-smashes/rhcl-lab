#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/models.sh
source "${ROOT}/scripts/models.sh"

NS="${EXTERNAL_MODELS_NAMESPACE:-external-models}"
GW_NS="${MAAS_GATEWAY_NAMESPACE:-openshift-ingress}"
GW_NAME="${MAAS_GATEWAY_NAME:-maas-default-gateway}"

echo "=== ExternalModel / MaaSModelRef ==="
oc get externalmodel,maasmodelref -n "${NS}"

echo
echo "=== MaaSModelRef phases ==="
while IFS= read -r model; do
  phase="$(oc get maasmodelref "${model}" -n "${NS}" \
    -o jsonpath='{.status.phase}{"\n"}' 2>/dev/null || echo "missing")"
  target="$(req024_target_model "${model}" || echo "?")"
  echo "${model} (targetModel=${target}) phase=${phase}"
done < <(req024_model_names)

echo
echo "=== Derived networking resources ==="
oc get service,httproute,serviceentry,destinationrule -n "${NS}" 2>/dev/null || true

# Resolve MaaS API URL. Prefer OpenShift Route maas.apps (lab default); the Gateway
# listener hostname (maas-api.apps) often has no Route and returns 503 externally.
if [[ -z "${MAAS_URL:-}" ]]; then
  ROUTE_HOST="$(oc -n "${GW_NS}" get route "${GW_NAME}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${ROUTE_HOST}" ]]; then
    MAAS_URL="https://${ROUTE_HOST}"
    MAAS_URL_SOURCE="Route ${GW_NS}/${GW_NAME}"
  else
    MAAS_HOST="$(oc -n "${GW_NS}" get gateway "${GW_NAME}" \
      -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${MAAS_HOST}" ]]; then
      MAAS_URL="https://${MAAS_HOST}"
      MAAS_URL_SOURCE="Gateway listener ${GW_NS}/${GW_NAME}"
    else
      MAAS_DNS="$(oc get dnsrecord -n "${GW_NS}" \
        -l gateway.networking.k8s.io/gateway-name="${GW_NAME}" \
        -o jsonpath='{.items[0].spec.dnsName}' 2>/dev/null | sed 's/\.$//')"
      if [[ -n "${MAAS_DNS}" ]]; then
        MAAS_URL="https://${MAAS_DNS}"
        MAAS_URL_SOURCE="DNSRecord ${GW_NS}/${GW_NAME}"
      fi
    fi
  fi
fi

echo
echo "=== MaaS gateway URL ==="
if [[ -n "${MAAS_URL:-}" ]]; then
  echo "MAAS_URL=${MAAS_URL}"
  echo "(${MAAS_URL_SOURCE:-manual} — use maas.apps Route, NOT maas-api.apps listener)"
else
  echo "MAAS_URL not resolved — export MAAS_URL=https://maas.apps.\${RHCL_ZONE_ROOT_DOMAIN}"
fi

if [[ -n "${MAAS_URL:-}" ]]; then
  echo
  echo "=== Gateway connectivity (/v1/models, any Bearer) ==="
  CODE=$(curl -sk -o /tmp/req024-models.json -w "%{http_code}" \
    "${MAAS_URL}/v1/models" -H "Authorization: Bearer test" --connect-timeout 12)
  echo "http=${CODE} (500/401 = gateway reachable, auth missing; 503 = wrong host; 302 = rh-ai OAuth)"
  head -c 200 /tmp/req024-models.json 2>/dev/null; echo
fi

if [[ -n "${MAAS_URL:-}" && -n "${MAAS_API_KEY:-}" ]]; then
  echo
  echo "=== Inference smoke tests ==="
  while IFS= read -r model; do
    target="$(req024_target_model "${model}")"
    echo "--- ${model} (targetModel=${target}) ---"
    CODE=""
    for PATH_SUFFIX in \
      "/llm/${model}/v1/chat/completions" \
      "/external-models/${model}/v1/chat/completions"; do
      CODE=$(curl -sk -o /tmp/req024-maas.json -w "%{http_code}" \
        -X POST "${MAAS_URL}${PATH_SUFFIX}" \
        -H "Authorization: Bearer ${MAAS_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${target}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}" \
        --connect-timeout 15)
      echo "path=${PATH_SUFFIX} http=${CODE}"
      if [[ "${CODE}" == "200" ]]; then
        head -c 300 /tmp/req024-maas.json
        echo
        break
      fi
    done
    if [[ "${CODE:-}" != "200" ]]; then
      echo "hint: use MaaS key sk-oai-... from dashboard (not LiteLLM sk-...); add model to Subscription first"
      head -c 200 /tmp/req024-maas.json 2>/dev/null
      echo
    fi
  done < <(req024_model_names)
else
  echo
  echo "Optional inference test: export MAAS_API_KEY=sk-oai-... (from MaaS dashboard) and re-run"
fi
