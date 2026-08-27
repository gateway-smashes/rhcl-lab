#!/usr/bin/env bash
# Enable AI asset custom endpoints in OdhDashboardConfig (merge patch).
# Required for external LiteLLM / OpenAI-compatible gateways in Gen AI studio.
#
# Red Hat docs: externalProviders depends on dashboardConfig.aiAssetCustomEndpoints=true.
# Do not add broad public TLDs (e.g. .com) to clusterDomains — internal org domains only.
set -euo pipefail

NS="${OCP_AI_APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
NAME="${OCP_AI_ODH_DASHBOARD_CONFIG_NAME:-odh-dashboard-config}"

EXTERNAL_PROVIDERS="${OCP_AI_DASHBOARD_AI_ASSET_EXTERNAL_PROVIDERS:-true}"
CLUSTER_DOMAINS="${OCP_AI_DASHBOARD_AI_ASSET_CLUSTER_DOMAINS:-}"

# Build clusterDomains JSON array from comma-separated env (empty → [])
if [[ -z "${CLUSTER_DOMAINS}" ]]; then
  DOMAINS_JSON='[]'
else
  DOMAINS_JSON="$(CLUSTER_DOMAINS="${CLUSTER_DOMAINS}" python3 -c "
import json, os
domains = [d.strip() for d in os.environ['CLUSTER_DOMAINS'].split(',') if d.strip()]
print(json.dumps(domains))
")"
fi

PATCH="$(EXTERNAL_PROVIDERS="${EXTERNAL_PROVIDERS}" DOMAINS_JSON="${DOMAINS_JSON}" python3 -c "
import json, os
print(json.dumps({
    'spec': {
        'dashboardConfig': {
            'aiAssetCustomEndpoints': True
        },
        'genAiStudioConfig': {
            'aiAssetCustomEndpoints': {
                'externalProviders': os.environ.get('EXTERNAL_PROVIDERS', 'true').lower() == 'true',
                'clusterDomains': json.loads(os.environ['DOMAINS_JSON'])
            }
        }
    }
}))
")"

echo "Patching ${NS}/${NAME} (aiAssetCustomEndpoints + externalProviders)..."
oc patch odhdashboardconfig "${NAME}" \
  -n "${NS}" \
  --type=merge \
  -p "${PATCH}"

echo
echo "Current values:"
oc get odhdashboardconfig "${NAME}" -n "${NS}" -o jsonpath=$'dashboardConfig.aiAssetCustomEndpoints={.spec.dashboardConfig.aiAssetCustomEndpoints}\nexternalProviders={.spec.genAiStudioConfig.aiAssetCustomEndpoints.externalProviders}\nclusterDomains={.spec.genAiStudioConfig.aiAssetCustomEndpoints.clusterDomains}\n'
echo
echo "Hard-refresh the OpenShift AI dashboard (Ctrl+Shift+R) after applying."
