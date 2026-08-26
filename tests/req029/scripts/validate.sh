#!/usr/bin/env bash
# req029 — Validation: self-service through the IDP (Red Hat Developer Hub +
# Kuadrant Backstage plugin).
set -euo pipefail

PASS=0
FAIL=0
WARN=0
check_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }

RHDH_NS="${RHDH_NS:-rhcl-developer-hub}"
CONSOLE_CFG_NS="${CONSOLE_CFG_NS:-custom-rhcl-console}"
CONSOLE_CFG="${CONSOLE_CFG:-custom-rhcl-console-config}"

echo "======================================================================"
echo " REQ 029 — Validation: Internal Developer Hub (RHDH + Kuadrant plugin)"
echo "======================================================================"
echo " Namespace: $RHDH_NS"
echo ""

echo "--- 1. RHDH operator ---"
CSV=$(oc get csv -A 2>/dev/null | grep -iE "rhdh|developer.hub" | awk '$NF=="Succeeded"{print $2; exit}')
if [ -n "$CSV" ]; then check_pass "operator CSV Succeeded ($CSV)"; else check_fail "no Succeeded RHDH operator CSV"; fi

echo "--- 2. Backstage instance + Route ---"
if oc -n "$RHDH_NS" get backstage rhdh &>/dev/null; then
  check_pass "Backstage/rhdh exists"
  # RHDH 1.6 puts the admitted hostname in .status.ingress[0].host on the
  # `backstage-<instance>` Route (spec.host stays empty).
  RHOST=$(oc -n "$RHDH_NS" get route backstage-rhdh -o jsonpath='{.status.ingress[0].host}' 2>/dev/null \
          || oc -n "$RHDH_NS" get route -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null || echo "")
  if [ -n "$RHOST" ]; then
    CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${RHOST}" --max-time 20 || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then check_pass "Route answers ($CODE): https://${RHOST}";
    else check_fail "Route not serving (HTTP $CODE): https://${RHOST}"; fi
  else check_fail "no RHDH Route found"; fi
else
  check_fail "Backstage/rhdh not found in $RHDH_NS"
fi

echo "--- 3. Kuadrant dynamic plugins declared ---"
if oc -n "$RHDH_NS" get cm dynamic-plugins-rhdh -o yaml 2>/dev/null | grep -q "kuadrant-backstage-plugin-frontend"; then
  check_pass "frontend plugin in dynamic-plugins-rhdh"
else check_fail "frontend plugin missing from dynamic-plugins-rhdh"; fi
if oc -n "$RHDH_NS" get cm dynamic-plugins-rhdh -o yaml 2>/dev/null | grep -q "kuadrant-backstage-plugin-backend-dynamic"; then
  check_pass "backend plugin in dynamic-plugins-rhdh"
else check_fail "backend plugin missing from dynamic-plugins-rhdh"; fi
# integrity hashes actually resolved (not left as placeholder)
if oc -n "$RHDH_NS" get cm dynamic-plugins-rhdh -o yaml 2>/dev/null | grep -q "__FRONTEND_INTEGRITY__\|__BACKEND_INTEGRITY__"; then
  check_fail "integrity placeholders were not substituted (npm view … dist.integrity)"
else check_pass "plugin integrity hashes substituted"; fi

echo "--- 4. Cluster RBAC for the RHDH ServiceAccount ---"
if oc get clusterrole rhdh-kuadrant &>/dev/null && oc get clusterrolebinding rhdh-kuadrant &>/dev/null; then
  check_pass "rhdh-kuadrant ClusterRole + Binding exist"
  SA_NS=$(oc get clusterrolebinding rhdh-kuadrant -o jsonpath='{.subjects[0].namespace}' 2>/dev/null)
  SA_NAME=$(oc get clusterrolebinding rhdh-kuadrant -o jsonpath='{.subjects[0].name}' 2>/dev/null)
  if oc auth can-i list apiproducts.devportal.kuadrant.io --as="system:serviceaccount:${SA_NS}:${SA_NAME}" -A &>/dev/null; then
    check_pass "SA ${SA_NS}/${SA_NAME} can list apiproducts"
  else check_warn "SA cannot list apiproducts (RBAC not effective yet?)"; fi
else check_fail "rhdh-kuadrant ClusterRole/Binding missing"; fi

echo "--- 5. Console link (internalDeveloperHubUrl) ---"
URL=$(oc -n "$CONSOLE_CFG_NS" get cm "$CONSOLE_CFG" -o jsonpath='{.data.internalDeveloperHubUrl}' 2>/dev/null || echo "")
if [ -n "$URL" ]; then check_pass "internalDeveloperHubUrl set → $URL";
else check_warn "internalDeveloperHubUrl not set on $CONSOLE_CFG (console nav item stays hidden)"; fi

echo ""
echo "======================================================================"
echo " RESULT: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "======================================================================"
[ "$FAIL" -eq 0 ]
