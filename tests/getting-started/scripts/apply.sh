#!/usr/bin/env bash
# Getting started — aplica todos os 7 manifests em ordem.
#
# Uso:
#   HOSTNAME=banking-lite.apps.example.com ./scripts/apply.sh
#
# HOSTNAME é obrigatório — sem ele o HTTPRoute fica com placeholder
# literal e o gateway não roteia. Se você não sabe qual hostname usar,
# derive do banking-api existente:
#   BASE=$(oc get httproutes.gateway.networking.k8s.io banking-api-connectivity \
#     -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}' | cut -d. -f2-)
#   HOSTNAME="banking-lite.${BASE}"
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${HERE}/../manifests"

: "${HOSTNAME:?HOSTNAME env var required — see script header for how to derive}"

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

echo "── Getting started: aplicando banking-lite ─────────────────────"
echo "   hostname: ${HOSTNAME}"
echo ""

# Pré-flight: o banking-api-v1 tem que existir. Se não, o HTTPRoute
# fica com backendRef inválido e nenhum request passa.
if ! oc -n rhcl-apps get svc banking-api-v1 >/dev/null 2>&1; then
  echo "ERROR: Service banking-api-v1 não encontrado em rhcl-apps." >&2
  echo "       Instalar o PoC apps primeiro (playbook apps-install ou role apps)." >&2
  exit 1
fi

echo "[1/7] HTTPRoute banking-lite (com hostname substituída)"
sed "s|\${HOSTNAME}|${HOSTNAME}|g" "${MANIFESTS}/01-httproute.yaml" | oc apply -f -

echo "[2/7] APIProduct banking-lite"
oc apply -f "${MANIFESTS}/02-apiproduct.yaml"

echo "[3/7] PlanPolicy banking-lite-plans (tier demo, 60/min por consumer)"
oc apply -f "${MANIFESTS}/03-planpolicy.yaml"

echo "[4/7] AuthPolicy banking-lite-apikey (exige header api-key)"
oc apply -f "${MANIFESTS}/04-authpolicy.yaml"

echo "[5/7] RateLimitPolicy banking-lite-global-ratelimit (500/min agregado)"
oc apply -f "${MANIFESTS}/05-ratelimitpolicy.yaml"

echo "[6/7] Secret banking-lite-onboarding-key (chave real, watchada pelo Authorino)"
oc apply -f "${MANIFESTS}/06-apikey-secret.yaml"

echo "[7/7] APIKey CR banking-lite-onboarding (aparece no dev portal)"
oc apply -f "${MANIFESTS}/07-apikey-cr.yaml"

# Aguarda o Authorino pegar a nova AuthPolicy — ~5s é suficiente na
# maioria dos clusters. Sem essa espera, o 1º curl pode dar 401 falso.
echo ""
echo "→ Aguardando Authorino sincronizar (5s)..."
sleep 5

KEY=$(oc -n rhcl-apps get secret banking-lite-onboarding-key -o jsonpath='{.data.api_key}' | base64 -d)

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " ✓ Pronto. Banking Lite disponível em:"
echo "   https://${HOSTNAME}/api/v1/accounts/summary"
echo ""
echo " Chave (getting-started demo):"
echo "   ${KEY}"
echo ""
echo " Testar rapidão:"
echo "   curl -sk -H 'api-key: ${KEY}' \\"
echo "     https://${HOSTNAME}/api/v1/accounts/summary | jq '.[0:2]'"
echo ""
echo " Validar tudo (12 checks):"
echo "   HOSTNAME=${HOSTNAME} ./scripts/validate.sh"
echo "════════════════════════════════════════════════════════════════"
