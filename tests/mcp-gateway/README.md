---
title: MCP Gateway (dedicated)
summary: A dedicated Istio Gateway for MCP traffic.
category: MCP
status: done
---

# REQ 59 — MCP Gateway (dedicated Istio Gateway)

This runbook installs the **MCP Gateway operator** (RHCL Technology Preview) on a
**dedicated Gateway** (`rhcl-mcp-gateway`) and **all req 59 resources** in
namespace **`mcp-gateway`**, isolated from `rhcl-apps-gateway`.

Manifests live under [`manifests/`](manifests/). Hostnames use
**`${RHCL_ZONE_ROOT_DOMAIN}`** — expand with `envsubst` before `oc apply`.

Automation equivalent: `automation/playbooks/mcp_gateway-install.yml` (see
[`automation/README_TEST_INSTALLATION_MCP_GATEWAY.md`](../../automation/README_TEST_INSTALLATION_MCP_GATEWAY.md)).

## Target flow

```
browser / curl ──► http://mcp-gateway.<zone>:8080/mcp
        (or OpenShift Route mcp-gateway-browser → :8080)
                         │
              Gateway rhcl-mcp-gateway (Istio, listener `mcp`)
                         │
              HTTPRoute mcp-gateway-route-custom (CORS)
                         │
              MCPGatewayExtension → broker Service mcp-gateway:8080
                         │
              MCPServerRegistration → banking-api-mcp-server HTTPRoute
                         │  (listener `mcps` on same Gateway)
                         ▼
              Service rhcl-apps/banking-api-v1:8080  →  Quarkus MCP (/mcp)
```

**Not used for req 59:** `rhcl-apps-gateway`, `HTTPRoute banking-api-connectivity`,
`AuthPolicy banking-api-connectivity-apikey`, or any RHCL-only `/mcp` exposure.

## Prerequisites

### Tooling

- `oc` logged in to the target cluster (`oc whoami` must succeed).
- `envsubst` from `gettext` (used to expand `${RHCL_ZONE_ROOT_DOMAIN}`).
- `ansible-playbook` 2.15+ with the `kubernetes.core` collection (used by the
  `mcp_gateway` role).
- `jq` (optional) for parsing CRD schemas and MCP responses.

### Cluster baseline (in install order)

1. `playbooks/gateway_api-install.yml` — `gateway.networking.k8s.io` CRDs and the
   `openshift-default` GatewayClass.
2. `playbooks/cert_manager-install.yml` + `playbooks/letsencrypt-install.yml` —
   only required if you front the MCP Gateway with TLS (this runbook uses HTTP
   :8080 directly).
3. `playbooks/rhcl-install.yml` — installs `rhcl-operator` v1.4 + dependencies
   (`authorino-operator`, `limitador-operator`, `dns-operator`). MCP Gateway
   has `olm.package.required: rhcl-operator >=1.3.2`.
4. `playbooks/apps-install.yml` — `banking-api-v1` Deployment + Service in
   `rhcl-apps` serving Streamable HTTP MCP on `/mcp` (req 21).

### MCP-specific

- **MCP Gateway operator bundle** available in `redhat-operators` catalog
  (`PackageManifest: mcp-gateway`, channel `preview`, current CSV
  `mcp-gateway.v0.7.0`). The operator is **Tech Preview** — only RHCL 1.3+ ships
  it.
- **`RHCL_ZONE_ROOT_DOMAIN`** exported in the shell. The role uses it for the
  Gateway listener hostname, the backend MCP server route hostname and the
  OpenShift browser Route. Source from the cluster:

  ```bash
  export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}')"
  ```

  Do not pipe `source scripts/cluster-env.sh | tail -5` — the pipe forks a
  subshell and the `export` is lost. Source it directly or copy the value out
  with `oc get` as above.

- **Internal hair-pin host (`spec.privateHost`)** on `MCPGatewayExtension`. The
  broker reaches backend MCP servers through the dedicated gateway listener on
  port **8080** via the compat Service `rhcl-mcp-gateway-istio` (created by
  `30-gateway-istio-compat-service.yaml` / the Ansible role). Set:

  ```text
  rhcl-mcp-gateway-istio.mcp-gateway.svc.cluster.local:8080
  ```

  Override with `MCP_GATEWAY_PRIVATE_HOST` or `MCP_GATEWAY_PORT` when the
  listener port changes. Do **not** point this at `rhcl-apps-gateway-istio`
  (that Service belongs to the apps gateway in `openshift-ingress`, not the
  dedicated MCP gateway).

### Kuadrant AuthPolicy namespace (**critical**)

`rhcl-mcp-gateway` and every MCP `HTTPRoute` live in **`mcp-gateway`**. Kuadrant
`AuthPolicy` resources must be created in the **same namespace as their
`targetRef`**:

| AuthPolicy | Namespace | `targetRef` |
| --- | --- | --- |
| `rhcl-mcp-gateway-deny-all` | `mcp-gateway` | `Gateway/rhcl-mcp-gateway` |
| `banking-api-mcp-server-allow-mcp-discovery` | `mcp-gateway` | `HTTPRoute/banking-api-mcp-server` |
| `mcp-gateway-route-custom-allow-public` | `mcp-gateway` | `HTTPRoute/mcp-gateway-route-custom` |

Policies in `openshift-ingress` (apps gateway) or `rhcl-apps` do **not** apply to
the dedicated MCP gateway. Route-level policies use `allow = true` to override
the gateway deny-all in `mcp-gateway`.

### AuthPolicy schema migration (**critical** — read before installing)

`mcp-gateway.v0.7.0` ships a stricter `authconfigs.authorino.kuadrant.io` CRD:
`spec.<rule>.when[*].predicate` was removed from the `oneOf`, so only
`patternRef`, `operator+selector`, `all` and `any` are accepted at the
AuthConfig level. OLM refuses to upgrade the CRD when any existing **AuthConfig
(generated by Kuadrant from `predicate`-style AuthPolicies)** would violate the
new schema, with a message like:

```
InstallPlanFailed: error validating existing CRs against new CRD's schema for
"authconfigs.authorino.kuadrant.io": updated validation is too restrictive:
... spec.authentication.<rule>.when[0].patternRef: Required value
```

Before running this runbook on a cluster where `apps-install` already ran
(typical lab flow) you must let the operator install **once with no
`predicate`-style AuthConfigs in `kuadrant-system`**. Two options:

- **Recommended — drain and re-apply (≈30 s downtime on banking-api auth):**

  ```bash
  mkdir -p /tmp/authpolicy-backup
  for AP in rhcl-apps/banking-api-connectivity-apikey openshift-ingress/rhcl-apps-gateway-deny-all; do
    NS="${AP%%/*}"; NAME="${AP##*/}"
    oc get authpolicy "$NAME" -n "$NS" -o yaml > "/tmp/authpolicy-backup/${NS}_${NAME}.yaml" 2>/dev/null \
      && oc delete authpolicy "$NAME" -n "$NS"
  done
  oc get authconfigs -n kuadrant-system   # expect: No resources found

  # Install MCP (steps 2–8 below). When the CSV is Succeeded, restore:
  for F in /tmp/authpolicy-backup/*.yaml; do [ -s "$F" ] && oc apply -f "$F"; done
  ```

- **Alternative — migrate AuthPolicies to `patternRef`** by declaring named
  patterns in `spec.patterns` and referencing them from `when[*].patternRef`.
  Heavier refactor across `automation/roles/apps/templates/`; only worth it if
  a future bundle also tightens `authorino.kuadrant.io/v1beta3`.

### Existing-Gateway considerations (skip if `MCP_GATEWAY_MANAGE_GATEWAY=true`)

- If you point the role at the shared `rhcl-apps-gateway` instead of letting it
  create `rhcl-mcp-gateway`, the role refuses to add a second listener whose
  `(port, protocol, hostname)` matches another listener. Adjust
  `MCP_GATEWAY_LISTENER_NAME` / `MCP_GATEWAY_LISTENER_HOSTNAME` (and the
  `_SERVER_` equivalents) to keep listeners unique, or remove the conflicting
  listener first.
- Cleanup of any legacy `/mcp` exposure on `rhcl-apps-gateway` is documented in
  [Migration from RHCL-reuse (legacy)](#migration-from-rhcl-reuse-legacy) below.

## Installation — Ansible (recommended)

```bash
cd automation
source scripts/cluster-env.sh   # sets RHCL_ZONE_ROOT_DOMAIN from cluster ingress

export MCP_GATEWAY_MANAGE_GATEWAY=true          # default
export MCP_GATEWAY_GATEWAY_NAME=rhcl-mcp-gateway
export MCP_GATEWAY_NAMESPACE=mcp-gateway
export MCP_GATEWAY_GATEWAY_NAMESPACE=mcp-gateway
export MCP_GATEWAY_LISTENER_HOSTNAME=mcp-gateway.${RHCL_ZONE_ROOT_DOMAIN}
export MCP_GATEWAY_HOSTNAME=mcp-gateway.${RHCL_ZONE_ROOT_DOMAIN}
export MCP_GATEWAY_SERVER_ROUTE_HOSTNAME=banking-api-mcp-server.${RHCL_ZONE_ROOT_DOMAIN}

ansible-playbook playbooks/mcp_gateway-install.yml
ansible-playbook playbooks/mcp_gateway-test.yml
```

## Installation — manifests (manual)

Run from the repository root (`rhcl-lab/`). Set the lab zone first:

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"
: "${RHCL_ZONE_ROOT_DOMAIN:?set RHCL_ZONE_ROOT_DOMAIN before envsubst}"
```

Full install (copy-paste):

```bash
# 1 — Drain AuthPolicies (skip if not present)
mkdir -p /tmp/authpolicy-backup
for AP in rhcl-apps/banking-api-connectivity-apikey openshift-ingress/rhcl-apps-gateway-deny-all; do
  NS="${AP%%/*}"; NAME="${AP##*/}"
  if oc get authpolicy "$NAME" -n "$NS" >/dev/null 2>&1; then
    oc get authpolicy "$NAME" -n "$NS" -o yaml > "/tmp/authpolicy-backup/${NS}_${NAME}.yaml"
    oc delete authpolicy "$NAME" -n "$NS"
    echo "drained ${NS}/${NAME}"
  else
    echo "skip ${NS}/${NAME} (not present)"
  fi
done
sleep 5
oc get authconfigs -n kuadrant-system

# 2 — Operator
oc apply -f tests/mcp-gateway/manifests/10-mcp-gateway-namespace.yaml
oc apply -f tests/mcp-gateway/manifests/11-mcp-gateway-operatorgroup.yaml
oc apply -f tests/mcp-gateway/manifests/12-mcp-gateway-subscription.yaml
for i in $(seq 1 18); do
  PHASE="$(oc get csv mcp-gateway.v0.7.0 -n mcp-gateway -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$PHASE" = "Succeeded" ] && break
  echo "waiting for mcp-gateway.v0.7.0 CSV... ($i/18)"
  sleep 10
done
oc get csv mcp-gateway.v0.7.0 -n mcp-gateway -o jsonpath='{.status.phase}{"\n"}'

# 3 — Restore AuthPolicies
for F in /tmp/authpolicy-backup/*.yaml; do
  [ -s "$F" ] && oc apply -f "$F" || echo "skip empty backup: $F"
done

# 4 — Dedicated Istio Gateway
envsubst < tests/mcp-gateway/manifests/30-rhcl-mcp-gateway.yaml | oc apply -f -
oc wait --for=condition=Programmed -n mcp-gateway gateway/rhcl-mcp-gateway --timeout=2m

# 5 — Gateway deny-all (namespace mcp-gateway — not openshift-ingress)
oc apply -f tests/mcp-gateway/manifests/31-mcp-gateway-deny-all-authpolicy.yaml

# 6 — ReferenceGrant + compat Service
oc apply -f tests/mcp-gateway/manifests/21-referencegrant-mcp-httproute-to-backend.yaml
oc apply -f tests/mcp-gateway/manifests/30-gateway-istio-compat-service.yaml

# 7 — Extension, routes, auth, registration
envsubst < tests/mcp-gateway/manifests/40-mcpgatewayextension.yaml | oc apply -f -
envsubst < tests/mcp-gateway/manifests/41-mcpserver-httproute.yaml | oc apply -f -
oc apply -f tests/mcp-gateway/manifests/42-mcpserver-authpolicy.yaml
envsubst < tests/mcp-gateway/manifests/43-mcpserverregistration.yaml | oc apply -f -
envsubst < tests/mcp-gateway/manifests/44-mcp-custom-httproute.yaml | oc apply -f -
oc apply -f tests/mcp-gateway/manifests/45-mcp-custom-httproute-authpolicy.yaml
envsubst < tests/mcp-gateway/manifests/46-mcp-browser-route.yaml | oc apply -f -

# 7 — CORS EnvoyFilter
oc apply -f tests/mcp-gateway/manifests/47-mcp-cors-envoyfilter.yaml

# 8 — Readiness
oc wait --for=condition=Ready mcpgatewayextension/mcp-gateway -n mcp-gateway --timeout=2m
oc wait --for=condition=Ready mcpserverregistration/banking-api -n mcp-gateway --timeout=2m
oc get mcpgatewayextension,mcpserverregistration,gateway,httproute,route -n mcp-gateway
```

Step-by-step reference:

**1.** Drain AuthPolicies (required when `apps-install` already ran — see
[AuthPolicy schema migration](#authpolicy-schema-migration-critical--read-before-installing)):

```bash
mkdir -p /tmp/authpolicy-backup

for AP in rhcl-apps/banking-api-connectivity-apikey openshift-ingress/rhcl-apps-gateway-deny-all; do
  NS="${AP%%/*}"
  NAME="${AP##*/}"
  if oc get authpolicy "$NAME" -n "$NS" >/dev/null 2>&1; then
    oc get authpolicy "$NAME" -n "$NS" -o yaml \
      > "/tmp/authpolicy-backup/${NS}_${NAME}.yaml"
    oc delete authpolicy "$NAME" -n "$NS"
    echo "drained ${NS}/${NAME}"
  else
    echo "skip ${NS}/${NAME} (not present)"
  fi
done

sleep 5
oc get authconfigs -n kuadrant-system   # expect: No resources found
```

**2.** Operator namespace and subscription:

```bash
oc apply -f tests/mcp-gateway/manifests/10-mcp-gateway-namespace.yaml
oc apply -f tests/mcp-gateway/manifests/11-mcp-gateway-operatorgroup.yaml
oc apply -f tests/mcp-gateway/manifests/12-mcp-gateway-subscription.yaml

for i in $(seq 1 18); do
  PHASE="$(oc get csv mcp-gateway.v0.7.0 -n mcp-gateway -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$PHASE" = "Succeeded" ] && break
  echo "waiting for mcp-gateway.v0.7.0 CSV... ($i/18)"
  sleep 10
done
oc get csv mcp-gateway.v0.7.0 -n mcp-gateway -o jsonpath='{.status.phase}{"\n"}'   # expect: Succeeded
```

**3.** Restore AuthPolicies (skip files that were not backed up in step 1):

```bash
for F in /tmp/authpolicy-backup/*.yaml; do
  [ -s "$F" ] && oc apply -f "$F" || echo "skip empty backup: $F"
done
```

**4.** Dedicated Istio Gateway:

```bash
envsubst < tests/mcp-gateway/manifests/30-rhcl-mcp-gateway.yaml | oc apply -f -
oc wait --for=condition=Programmed -n mcp-gateway gateway/rhcl-mcp-gateway --timeout=2m
```

**5.** Gateway deny-all AuthPolicy (must live in **`mcp-gateway`** with `rhcl-mcp-gateway`; do not reuse `openshift-ingress/rhcl-apps-gateway-deny-all`):

```bash
oc apply -f tests/mcp-gateway/manifests/31-mcp-gateway-deny-all-authpolicy.yaml
```

**6.** Backend ReferenceGrant and compat Service:

```bash
oc apply -f tests/mcp-gateway/manifests/21-referencegrant-mcp-httproute-to-backend.yaml
oc apply -f tests/mcp-gateway/manifests/30-gateway-istio-compat-service.yaml
```

**7.** MCP Gateway extension and routes:

```bash
envsubst < tests/mcp-gateway/manifests/40-mcpgatewayextension.yaml | oc apply -f -
envsubst < tests/mcp-gateway/manifests/41-mcpserver-httproute.yaml | oc apply -f -
oc apply -f tests/mcp-gateway/manifests/42-mcpserver-authpolicy.yaml
envsubst < tests/mcp-gateway/manifests/43-mcpserverregistration.yaml | oc apply -f -
envsubst < tests/mcp-gateway/manifests/44-mcp-custom-httproute.yaml | oc apply -f -
oc apply -f tests/mcp-gateway/manifests/45-mcp-custom-httproute-authpolicy.yaml
envsubst < tests/mcp-gateway/manifests/46-mcp-browser-route.yaml | oc apply -f -
```

**8.** CORS EnvoyFilter (handles preflight before auth, adds headers to all responses):

```bash
oc apply -f tests/mcp-gateway/manifests/47-mcp-cors-envoyfilter.yaml
```

**9.** Wait for readiness:

```bash
oc wait --for=condition=Ready mcpgatewayextension/mcp-gateway -n mcp-gateway --timeout=2m
oc wait --for=condition=Ready mcpserverregistration/banking-api -n mcp-gateway --timeout=2m
oc get mcpgatewayextension,mcpserverregistration,gateway,httproute,route -n mcp-gateway
```

## MCP base URL

```bash
# Direct to Gateway listener (HTTP :8080):
export MCP_URL="http://mcp-gateway.${RHCL_ZONE_ROOT_DOMAIN}:8080/mcp"

# Via OpenShift Route (TLS edge, still forwards to :8080):
# export MCP_URL="https://mcp-gateway.${RHCL_ZONE_ROOT_DOMAIN}/mcp"
```

## Validate with `curl`

### `initialize` (capture `mcp-session-id`)

```bash
INIT_HEADERS="$(mktemp)"

curl -si \
  -D "${INIT_HEADERS}" \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": { "name": "curl", "version": "1.0.0" }
    }
  }' \
  "${MCP_URL}"

export MCP_SESSION_ID="$(awk 'BEGIN { IGNORECASE=1 } /^mcp-session-id:/ { print $2 }' "${INIT_HEADERS}" | tr -d "\r")"
echo "session=${MCP_SESSION_ID}"
```

Expect `HTTP/1.1 200`, JSON-RPC `result`, and a non-empty `MCP_SESSION_ID`.

### `tools/list` (prefixed tools via broker)

```bash
curl -si \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: ${MCP_SESSION_ID}" \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "${MCP_URL}"
```

Expect tools such as `banking_getAccountSummary` (broker prefix `banking_`).

### `tools/call`

```bash
curl -si \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: ${MCP_SESSION_ID}" \
  --data '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "banking_getAccountSummary",
      "arguments": { "version": "v1" }
    }
  }' \
  "${MCP_URL}"
```

## Validate in the PoC app (Flutter)

1. Open the **mobile-bank** URL from your cluster route.
2. Open the **PoC console** → **MCP Integration** tab.
3. Set **MCP Gateway URL** to `http://mcp-gateway.<zone>/mcp`
   (port 80 — via OpenShift Route `mcp-gateway-browser`).
4. If an old URL is cached: `localStorage.removeItem('redbank.mcpGatewayUrl')` then reload.
5. Open a fresh **incognito window** to avoid stale CORS preflight cache.
6. Run **Initialize** → **List tools** → **Call tool**.

## Interactive static test page

```bash
python3 -m http.server 8080 --directory tests/req059
```

Open `http://localhost:8080` — [index.html](index.html) pre-fills the URL from `/env.json` when `RHCL_ZONE_ROOT_DOMAIN` is set on the tests container.

## Migration from RHCL-reuse (legacy)

If a previous install exposed `/mcp` on `banking-api-connectivity` or patched
`rhcl-apps-gateway` with listeners `mcp`/`mcps`, clean up before applying this runbook:

```bash
# Remove legacy EnvoyFilter (RHCL-reuse track)
oc -n openshift-ingress delete envoyfilter/mcp-cors-preflight --ignore-not-found

# Remove MCP listeners from the apps gateway (if present)
for L in mcp mcps; do
  IDX="$(oc get gateway rhcl-apps-gateway -n openshift-ingress -o json \
    | jq "[.spec.listeners[].name] | index(\"$L\")")"
  [[ "$IDX" != "null" ]] && oc patch gateway rhcl-apps-gateway -n openshift-ingress \
    --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/listeners/$IDX\"}]"
done

# Re-apply apps role to drop /mcp from banking-api-connectivity HTTPRoute
cd automation && ansible-playbook playbooks/apps-install.yml
```

## Cleanup

```bash
cd automation
ansible-playbook playbooks/mcp_gateway-remove.yml
```

Or delete manifests in reverse order; the dedicated Gateway namespace is removed when `MCP_GATEWAY_MANAGE_GATEWAY=true`.

## Files

| File                                                                                             | Purpose                                                     |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| [manifests/10–12](manifests/)                                                                    | Operator namespace, OperatorGroup, Subscription             |
| [manifests/15-mcp-gateway-namespace.yaml](manifests/15-mcp-gateway-namespace.yaml)               | Namespace for dedicated Gateway                             |
| [manifests/30-rhcl-mcp-gateway.yaml](manifests/30-rhcl-mcp-gateway.yaml)                         | Istio Gateway `rhcl-mcp-gateway` (listeners `mcp` + `mcps`) |
| [manifests/31-mcp-gateway-deny-all-authpolicy.yaml](manifests/31-mcp-gateway-deny-all-authpolicy.yaml) | Gateway deny-all AuthPolicy in `mcp-gateway`            |
| [manifests/30-gateway-istio-compat-service.yaml](manifests/30-gateway-istio-compat-service.yaml) | Internal `rhcl-mcp-gateway-istio` Service                   |
| [manifests/19–21](manifests/)                                                                    | ReferenceGrants (gateway + backend)                         |
| [manifests/40–46](manifests/)                                                                    | Extension, backend route, registration, browser route       |
| [manifests/47-mcp-cors-envoyfilter.yaml](manifests/47-mcp-cors-envoyfilter.yaml)                 | CORS EnvoyFilter (Lua — preflight before auth)              |
| [index.html](index.html)                                                                         | Browser-side MCP smoke test                                 |

## Requirement context

REQ 59 validates the banking-api MCP server exposed through the **MCP Gateway
operator** (RHCL Technology Preview) on a **dedicated Istio Gateway**
(`rhcl-mcp-gateway` in namespace `mcp-gateway`), isolated from `rhcl-apps-gateway`.

- Manifests to apply with `oc apply -f tests/mcp-gateway/manifests/`
  (self-contained — 19 YAMLs covering the operator subscription,
  the MCP gateway CR, listeners and the HTTPRoute). The role
  `automation/roles/mcp_gateway/` bundles the same content behind
  `ansible-playbook automation/playbooks/mcp_gateway-install.yml`
  for operators who prefer the batch path.
- Backend MCP server (req 21) stays on `banking-api-v1`; the broker discovers it
  via `HTTPRoute banking-api-mcp-server` on listener `mcps`.
- Browser clients use `http://mcp-gateway.<zone>:8080/mcp` (or the OpenShift
  Route `mcp-gateway-browser`).
- Tools are prefixed by the broker (default `banking_`, e.g. `banking_getAccountSummary`).

The PoC console **MCP Integration** tab targets the MCP Gateway URL above — not
`banking-api-connectivity/.../mcp`.
