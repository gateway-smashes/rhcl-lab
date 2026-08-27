#!/usr/bin/env bash
# Getting started — aplica todos os 7 manifests em ordem.
#
# Uso:
#   HOSTNAME=banking-lite.pocrhcl.redhat.lab.example.com ./scripts/apply.sh
#
# HOSTNAME is required — without it the HTTPRoute keeps a literal
# placeholder and the gateway does not route. If you don't know which hostname to use,
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

# Preflight: banking-api-v1 must exist. If not, the HTTPRoute
# has an invalid backendRef and no request passes.
if ! oc -n rhcl-apps get svc banking-api-v1 >/dev/null 2>&1; then
  echo "ERROR: Service banking-api-v1 not found in rhcl-apps." >&2
  echo "       Instalar o PoC apps primeiro (playbook apps-install ou role apps)." >&2
  exit 1
fi

echo "[1/7] HTTPRoute banking-lite (with the hostname substituted)"
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

# Waits for Authorino to pick up the new AuthPolicy — ~5s is enough in
# maioria dos clusters. Sem essa espera, o 1º curl pode dar 401 falso.
echo ""
echo "→ Aguardando Authorino sincronizar (5s)..."
sleep 5

KEY=$(oc -n rhcl-apps get secret banking-lite-onboarding-key -o jsonpath='{.data.api_key}' | base64 -d)

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " ✓ Done. Banking Lite available at:"
echo "   https://${HOSTNAME}/api/v1/accounts/summary"
echo ""
echo " Chave (getting-started demo):"
echo "   ${KEY}"
echo ""
echo " Quick test:"
echo "   curl -sk -H 'api-key: ${KEY}' \\"
echo "     https://${HOSTNAME}/api/v1/accounts/summary | jq '.[0:2]'"
echo ""
echo " Validar tudo (12 checks):"
echo "   HOSTNAME=${HOSTNAME} ./scripts/validate.sh"
echo "════════════════════════════════════════════════════════════════"
