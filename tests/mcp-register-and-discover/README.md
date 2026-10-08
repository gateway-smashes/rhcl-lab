---
title: Register and discover an MCP server
summary: Register an MCP server and see it surface in the console plugin.
category: MCP
status: done
---

# REQ 73 — MCP Gateway: register an MCP server and see it in the plugin

Stands up the **Kuadrant MCP Gateway** (Model Context Protocol, **Technology
Preview**) and registers one MCP server behind it, so the resource — and its
live tools — show up in the custom console plugin's **Connectivity Link → MCP
Servers** page and its in-console "try it" playground.

> **Verified end-to-end on 2026-07-28** against chart **0.7.1** on OpenShift.
> Source of truth for the manifests: [`github.com/Kuadrant/mcp-gateway`](https://github.com/Kuadrant/mcp-gateway).
> The released API is **`mcp.kuadrant.io/v1alpha1`** (the repo's `main` has `v1`,
> not yet in a release).

Layout that gets built:

```text
client → mcp-gateway (Istio/Envoy + MCP Router ext_proc, "mcp" listener)
         └─ broker "mcp-gateway" (gateway-system) federates tools, prefixes them
              └─ everything-server  (HTTPRoute on the "mcps" listener) ← MCPServerRegistration
```

## Prerequisites

- OpenShift with the Istio gateway controller (`oc get gatewayclass istio`).
- `oc` logged in, and **`helm`** v3.8+ (OCI support).
- The custom console plugin deployed (to see the result).

```bash
export APPS_DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
export MCP_PUBLIC_HOST="mcp.${APPS_DOMAIN}"
```

## Install

### 1. Install the MCP Gateway (Helm)

Installs the CRDs (`mcp.kuadrant.io/v1alpha1`: MCPServerRegistration,
MCPGatewayExtension, MCPVirtualServer), the controller, and — with
`gateway.create=true` — the `mcp-gateway` Gateway (listeners `mcp` + `mcps`) in
`gateway-system`.

```bash
oc create namespace gateway-system --dry-run=client -o yaml | oc apply -f -
oc create namespace mcp-system --dry-run=client -o yaml | oc apply -f -

helm install mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway --version 0.7.1 \
  -n mcp-system \
  --set gateway.create=true \
  --set gateway.publicHost="${MCP_PUBLIC_HOST}"
```

### 2. Create the MCPGatewayExtension

The chart creates the Gateway but **not** the extension — apply it, then the
controller provisions the broker + `/mcp` route + EnvoyFilter:

```bash
oc apply -f tests/req073-mcp-gateway/manifests/05-mcpgatewayextension.yaml
oc -n gateway-system wait mcpgatewayextension/mcp-gateway --for=condition=Ready=True --timeout=3m
oc -n gateway-system get deploy mcp-gateway            # the broker
```

### 3. Deploy the sample server and register it

```bash
oc apply -f tests/req073-mcp-gateway/manifests/10-everything-server.yaml
oc apply -f tests/req073-mcp-gateway/manifests/20-everything-server-httproute.yaml
oc apply -f tests/req073-mcp-gateway/manifests/30-mcpserverregistration.yaml
oc apply -f tests/req073-mcp-gateway/manifests/40-mcpvirtualserver.yaml   # optional

oc -n mcp-test rollout status deploy/everything-server --timeout=2m
oc -n mcp-test wait mcpserverregistration/everything-server --for=condition=Ready=True --timeout=3m
```

`Ready=True` reports e.g. *"server added successfully. Total tools added 14."*

## Validate

**In the cluster:**

```bash
oc get mcpserverregistration,mcpvirtualserver -A
oc -n gateway-system get mcpgatewayextension
```

**In the plugin:** OpenShift console → **Connectivity Link → MCP Servers** →
`everything-server` (prefix `everything_`, Ready). The **Add MCP Gateway** button
opens the guided wizard.

### Enable the in-console "try it" playground (optional)

The playground must reach the **MCP gateway** (Istio + MCP Router), not the
broker directly — the broker only *lists* tools; the router *forwards*
`tools/call`. The console proxy needs HTTPS, so a serving-cert TLS front
("mcp-broker-tls" in **`mcp-system`**) routes to the gateway with the `mcp`
Host header, and the ConsolePlugin gets an `mcp-broker` proxy alias.

With the Ansible automation this is applied for you: the `mcp_gateway` role
renders the TLS front (`broker-tls-front.yml.j2`, deriving the upstream and
Host from the install) and the `custom_console` role adds the `mcp-broker`
alias. The manifest below is the hand-apply equivalent for that role install
(gateway compat Service `rhcl-mcp-gateway-istio` in `mcp-gateway`). **Set the
Host header first** to your `mcp` listener hostname:

```bash
export APPS_DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
export MCP_PUBLIC_HOST="mcp-gateway.${APPS_DOMAIN}"
envsubst < tests/mcp-register-and-discover/manifests/50-broker-tls-proxy.yaml | oc apply -f -

# add the proxy alias to the deployed ConsolePlugin (or re-run the custom_console role)
oc patch consoleplugin kuadrant-console --type=json -p '[{"op":"add","path":"/spec/proxy/-","value":{"alias":"mcp-broker","authorization":"None","endpoint":{"type":"Service","service":{"name":"mcp-broker-tls","namespace":"mcp-system","port":8443}}}}]'
oc -n openshift-console rollout restart deployment/console
```

Then open a server's detail page → **Connect to broker** → the registered
server's tools list; pick one, pass JSON args, **Call**. Verify the path from a pod:

```bash
oc -n mcp-system run mcptest --rm -i --restart=Never --image=curlimages/curl -- sh -c '
  H=https://mcp-broker-tls.mcp-system.svc:8443/mcp
  SID=$(curl -sk -D - -o /dev/null -X POST $H -H "accept: application/json, text/event-stream" -H "content-type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}" | tr -d "\r" | awk "tolower(\$1)==\"mcp-session-id:\"{print \$2}")
  curl -sk -X POST $H -H "mcp-session-id: $SID" -H "accept: application/json, text/event-stream" -H "content-type: application/json" -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" >/dev/null
  curl -sk -X POST $H -H "mcp-session-id: $SID" -H "accept: application/json, text/event-stream" -H "content-type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"'
```

## Notes

- Broker Service is **`mcp-gateway`** in **`gateway-system`** (HTTP 8080) — the
  0.7.x chart name, not `mcp-broker`.
- The `mcps` listener (`*.mcp.local`) and the server route hostname
  (`everything-server.mcp.local`) are **internal only** — the MCP Router resolves
  them; clients never do.
- Sample image `ghcr.io/kuadrant/mcp-gateway/test-everything-server:latest`
  (`imagePullPolicy: IfNotPresent`). If it can't pull, swap any MCP server and
  point the registration's `targetRef` at its HTTPRoute.

## Cleanup

```bash
oc delete -f tests/req073-mcp-gateway/manifests/ --ignore-not-found
helm uninstall mcp-gateway -n mcp-system
oc delete ns mcp-test gateway-system mcp-system --ignore-not-found
```
