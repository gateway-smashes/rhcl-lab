#!/usr/bin/env bash
# Apply the req026 RHCL streaming controls (EnvoyFilter + HTTPRoute
# timeout) using kubectl only — bypasses the Ansible playbook for
# ad-hoc testing.
#
# The current implementation uses `envoy.filters.http.lua` with a
# streaming `bodyChunks()` iterator (`01-envoyfilter-streaming-cap.yaml`).
# Prior versions of the PoC used `envoy.filters.http.buffer` — this
# script also removes the legacy EnvoyFilter if present, so migrations
# don't leave two conflicting size caps active on the same gateway.
#
# Prerequisite: banking-api HTTPRoute `banking-api-connectivity` already
# exists in the rhcl-apps namespace (created by the apps role). This
# script only adds the streaming controls; it does NOT recreate the
# HTTPRoute from scratch.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${HERE}/../manifests"

GATEWAY_NS="${GATEWAY_NS:-openshift-ingress}"
APPS_NS="${APPS_NS:-rhcl-apps}"
HTTPROUTE_NAME="${HTTPROUTE_NAME:-banking-api-connectivity}"

echo "==> Removing legacy buffer-based EnvoyFilter if present"
oc -n "${GATEWAY_NS}" delete envoyfilter files-upload-max-body --ignore-not-found

echo "==> Applying streaming EnvoyFilter (Lua bodyChunks() cap = 32 MiB) to ${GATEWAY_NS}"
oc apply -f "${MANIFESTS_DIR}/01-envoyfilter-streaming-cap.yaml"

echo "==> Patching HTTPRoute ${HTTPROUTE_NAME} with /api/files/upload timeout (60s)"
# Idempotency: only add the rule if no rule already has timeouts.request set
# on the /api/files/upload path.
if oc -n "${APPS_NS}" get httproutes.gateway.networking.k8s.io "${HTTPROUTE_NAME}" -o json \
  | jq -e '.spec.rules[] | select(.timeouts.request) | .matches[].path.value | contains("/api/files/upload")' >/dev/null; then
  echo "    (timeout rule already present — skipping patch)"
else
  oc -n "${APPS_NS}" patch httproutes.gateway.networking.k8s.io "${HTTPROUTE_NAME}" \
    --type=json --patch-file "${MANIFESTS_DIR}/02-httproute-timeout-patch.yaml"
fi

echo ""
echo "==> Current state"
oc -n "${GATEWAY_NS}" get envoyfilter files-upload-streaming-cap
oc -n "${APPS_NS}" get httproutes.gateway.networking.k8s.io "${HTTPROUTE_NAME}" \
  -o jsonpath='HTTPRoute timeout rule: {.spec.rules[?(@.timeouts)].timeouts}{"\n"}'
