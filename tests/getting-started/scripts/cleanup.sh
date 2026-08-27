#!/usr/bin/env bash
# Getting started — removes everything apply.sh created.
#
# Reverse order of apply, with --ignore-not-found to be idempotent.
# Does not touch banking-api-v1 (it is shared infra).
set -euo pipefail

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc not logged in" >&2; exit 1; }

echo "── Removing Getting started (banking-lite) ─────────────────"
oc -n rhcl-apps delete apikey banking-lite-onboarding --ignore-not-found
oc -n rhcl-apps delete secret banking-lite-onboarding-key --ignore-not-found
oc -n rhcl-apps delete ratelimitpolicy banking-lite-global-ratelimit --ignore-not-found
oc -n rhcl-apps delete authpolicy banking-lite-apikey --ignore-not-found
oc -n rhcl-apps delete planpolicy banking-lite-plans --ignore-not-found
oc -n rhcl-apps delete apiproduct banking-lite --ignore-not-found
oc -n rhcl-apps delete httproute.gateway.networking.k8s.io banking-lite --ignore-not-found

echo ""
echo "✓ Cleanup complete. banking-api-v1 remains intact."
