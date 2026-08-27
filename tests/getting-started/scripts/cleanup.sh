#!/usr/bin/env bash
# Getting started — remove tudo que o apply.sh criou.
#
# Ordem inversa do apply, com --ignore-not-found pra ser idempotente.
# Does not touch banking-api-v1 (it is shared infra).
set -euo pipefail

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

echo "── Removendo Getting started (banking-lite) ─────────────────"
oc -n rhcl-apps delete apikey banking-lite-onboarding --ignore-not-found
oc -n rhcl-apps delete secret banking-lite-onboarding-key --ignore-not-found
oc -n rhcl-apps delete ratelimitpolicy banking-lite-global-ratelimit --ignore-not-found
oc -n rhcl-apps delete authpolicy banking-lite-apikey --ignore-not-found
oc -n rhcl-apps delete planpolicy banking-lite-plans --ignore-not-found
oc -n rhcl-apps delete apiproduct banking-lite --ignore-not-found
oc -n rhcl-apps delete httproute.gateway.networking.k8s.io banking-lite --ignore-not-found

echo ""
echo "✓ Cleanup completo. banking-api-v1 permanece intacto."
