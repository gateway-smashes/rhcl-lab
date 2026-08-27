#!/usr/bin/env bash
set -euo pipefail

# Merge req030 envoyExtAuthzHttp extension provider into an existing Sail Istio CR.
# Lists every Istio resource in the cluster and prompts which one to patch.
# Existing extensionProviders are preserved (merge, never replace).
#
# Usage:
#   ./deploy-istio-extension-provider.sh
#
# Non-interactive (skip prompt):
#   ISTIO_NS=istio-system ISTIO_CR=default ./deploy-istio-extension-provider.sh

PROVIDER_NAME="req030-request-interceptor"
APPS_NS="req030-apps"
SERVICE_NAME="request-interceptor"
SERVICE_PORT=8080

if ! oc get crd istios.sailoperator.io &>/dev/null; then
  echo "ERROR: CRD istios.sailoperator.io not found. Is Sail Operator / OSSM 3.x installed?" >&2
  exit 1
fi

select_istio_cr() {
  local -a entries=()
  local line ns name

  while IFS=$'\t' read -r ns name; do
    [[ -n "$ns" && -n "$name" ]] && entries+=("${ns}/${name}")
  done < <(oc get istio -A --no-headers 2>/dev/null | awk '{print $1 "\t" $2}')

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "ERROR: No Istio CRs found in the cluster." >&2
    echo "       Install Sail Operator / OSSM and ensure at least one Istio CR exists." >&2
    exit 1
  fi

  echo "Istio CRs available in the cluster:"
  echo ""
  local i
  for i in "${!entries[@]}"; do
    printf "  [%d] %s\n" "$((i + 1))" "${entries[$i]}"
  done
  echo ""

  local choice
  while true; do
    read -rp "Select Istio CR to patch [1-${#entries[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#entries[@]} )); then
      ISTIO_CR="${entries[$((choice - 1))]%%/*}"
      ISTIO_NS="${entries[$((choice - 1))]#*/}"
      break
    fi
    echo "Invalid choice. Enter a number between 1 and ${#entries[@]}." >&2
  done
}

if [[ -n "${ISTIO_NS:-}" && -n "${ISTIO_CR:-}" ]]; then
  if ! oc -n "$ISTIO_NS" get istio "$ISTIO_CR" &>/dev/null; then
    echo "ERROR: Istio CR $ISTIO_NS/$ISTIO_CR not found." >&2
    exit 1
  fi
  echo "==> Using Istio CR from environment: $ISTIO_NS/$ISTIO_CR"
else
  select_istio_cr
  echo ""
  echo "==> Selected: $ISTIO_NS/$ISTIO_CR"
fi

echo "==> Merging extension provider '$PROVIDER_NAME' into Istio/$ISTIO_CR ($ISTIO_NS)..."

python3 - "$ISTIO_NS" "$ISTIO_CR" "$PROVIDER_NAME" "$APPS_NS" "$SERVICE_NAME" "$SERVICE_PORT" <<'PY'
import json
import subprocess
import sys

istio_ns, istio_cr, provider_name, apps_ns, service_name, service_port = sys.argv[1:7]
service_port = int(service_port)

raw = subprocess.check_output(
    ["oc", "-n", istio_ns, "get", "istio", istio_cr, "-o", "json"],
    text=True,
)
cr = json.loads(raw)

spec = cr.setdefault("spec", {})
values = spec.setdefault("values", {})
mesh = values.setdefault("meshConfig", {})
providers = mesh.setdefault("extensionProviders", [])

new_provider = {
    "name": provider_name,
    "envoyExtAuthzHttp": {
        "service": f"{service_name}.{apps_ns}.svc.cluster.local",
        "port": service_port,
        "pathPrefix": "/check",
        "timeout": "5s",
        "failOpen": False,
        "includeRequestHeadersInCheck": [
            "**",
            "authorization",
            "content-type",
            "x-request-id",
            "x-forwarded-for",
            "x-forwarded-host",
            "x-forwarded-proto",
            "user-agent",
        ],
        "headersToUpstreamOnAllow": [
            "x-inspected-by",
            "x-inspection-result",
            "x-request-interceptor-mode",
        ],
        "includeRequestBodyInCheck": {
            "maxRequestBytes": 8192,
            "allowPartialMessage": True,
        },
    },
}

providers = [p for p in providers if p.get("name") != provider_name]
providers.append(new_provider)
mesh["extensionProviders"] = providers

patch = {"spec": {"values": {"meshConfig": {"extensionProviders": providers}}}}
subprocess.run(
    [
        "oc", "-n", istio_ns, "patch", "istio", istio_cr,
        "--type=merge", "-p", json.dumps(patch),
    ],
    check=True,
)
print(f"  Provider '{provider_name}' registered (service: {new_provider['envoyExtAuthzHttp']['service']})")
PY