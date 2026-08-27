#!/usr/bin/env bash
# Remove the req026 RHCL controls. After this runs:
#   - oversize uploads (>32 MiB) hit the backend's Quarkus cap (1G) and
#     succeed end-to-end up to whatever the backend allows.
#   - slow uploads no longer time out at the gateway.
# Leaves the HTTPRoute intact, only drops the timeout rule.
set -euo pipefail

GATEWAY_NS="${GATEWAY_NS:-openshift-ingress}"
APPS_NS="${APPS_NS:-rhcl-apps}"
HTTPROUTE_NAME="${HTTPROUTE_NAME:-banking-api-connectivity}"

echo "==> Deleting streaming-cap EnvoyFilter"
oc -n "${GATEWAY_NS}" delete envoyfilter files-upload-streaming-cap --ignore-not-found
# Legacy name, kept for compatibility with clusters where the previous
# (buffered) manifest was applied before the migration.
oc -n "${GATEWAY_NS}" delete envoyfilter files-upload-max-body --ignore-not-found

echo "==> Removing /api/files/upload timeout rule from HTTPRoute"
# Find the rule index of the timeout rule and JSON-patch-remove it.
IDX=$(oc -n "${APPS_NS}" get httproutes.gateway.networking.k8s.io "${HTTPROUTE_NAME}" -o json \
  | jq '.spec.rules | map(.matches[0].path.value == "/api/files/upload" and (.timeouts.request != null)) | index(true)')
if [ "${IDX}" != "null" ] && [ -n "${IDX}" ]; then
  oc -n "${APPS_NS}" patch httproutes.gateway.networking.k8s.io "${HTTPROUTE_NAME}" \
    --type=json -p="[{\"op\":\"remove\",\"path\":\"/spec/rules/${IDX}\"}]"
  echo "    removed rule at index ${IDX}"
else
  echo "    (no timeout rule found — skipping)"
fi
