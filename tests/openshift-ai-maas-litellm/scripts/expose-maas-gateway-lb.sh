#!/usr/bin/env bash
# Expose maas-default-gateway externally via Gateway API (LoadBalancer + HTTPRoute).
# No OpenShift Route — the Gateway Service gets an AWS ELB like rhcl-apps-gateway.
set -euo pipefail

GW_NS="${MAAS_GATEWAY_NAMESPACE:-openshift-ingress}"
GW_NAME="${MAAS_GATEWAY_NAME:-maas-default-gateway}"
CM_NAME="${MAAS_GATEWAY_CONFIG_NAME:-${GW_NAME}-config}"
DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-apps.example.com}"
HOSTNAME="${MAAS_GATEWAY_HOSTNAME:-maas-api.${DOMAIN}}"

echo "Patching ${GW_NS}/${CM_NAME} → Service type LoadBalancer"
oc -n "${GW_NS}" patch configmap "${CM_NAME}" --type=merge -p "$(cat <<EOF
data:
  service: |
    metadata:
      annotations:
        service.beta.openshift.io/serving-cert-secret-name: "${GW_NAME}-service-tls"
    spec:
      type: LoadBalancer
EOF
)"

echo "Setting listener hostname on Gateway ${GW_NS}/${GW_NAME} → ${HOSTNAME}"
oc -n "${GW_NS}" patch gateway "${GW_NAME}" --type=merge -p "$(cat <<EOF
spec:
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "${HOSTNAME}"
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                values:
                  - openshift-ingress
                  - redhat-ods-applications
                  - external-models
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${GW_NAME}-service-tls
EOF
)"

SVC="${GW_NAME}-data-science-gateway-class"
echo "Waiting for LoadBalancer on ${GW_NS}/${SVC}..."
for i in $(seq 1 36); do
  ELB=$(oc -n "${GW_NS}" get svc "${SVC}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  TYPE=$(oc -n "${GW_NS}" get svc "${SVC}" -o jsonpath='{.spec.type}' 2>/dev/null || true)
  echo "t=${i} type=${TYPE} elb=${ELB:-pending}"
  [[ -n "${ELB}" ]] && break
  sleep 10
done

ELB=$(oc -n "${GW_NS}" get svc "${SVC}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
echo ""
echo "Gateway API external URL:"
echo "  https://${HOSTNAME}"
echo ""
echo "Inference example:"
echo "  curl -sk -X POST https://${HOSTNAME}/llm/qwen3-14b-external/v1/chat/completions \\"
echo "    -H 'Authorization: Bearer <sk-oai-...>' -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"qwen3-14b-external\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":50}'"
if [[ -n "${ELB}" ]]; then
  echo ""
  echo "ELB: ${ELB}"
  echo ""
  echo "DNS: o OpenShift Ingress Operator cria o registro automaticamente"
  echo "     (DNSRecord + Route53) quando o listener tem hostname."
  echo "     Verifique:"
  echo "       oc get dnsrecord -n ${GW_NS} -l gateway.networking.k8s.io/gateway-name=${GW_NAME}"
  echo "     No need to create Route53 manually."
fi
