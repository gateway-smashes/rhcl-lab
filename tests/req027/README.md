# REQ 027 — A2A (Agent2Agent) traffic through RHCL to an external agent

Reference design for routing **A2A protocol** traffic from inside the cluster to
an **external agent** (for example, an agent hosted on a Microsoft product such
as Copilot Studio / Azure AI Foundry Agent Service) through Red Hat Connectivity
Link. See [`../req027.md`](../req027.md) for the short overview.

> **Important**
>
> This page describes an **architectural possibility** for integrating with a
> product external to Red Hat. The configuration is **not part of the
> implementation scope** of this project and does **not** represent an
> architecture certified or jointly validated by Red Hat and Microsoft.
>
> The example reuses the external-service access pattern documented for Red Hat
> Connectivity Link — `ServiceEntry`, `DestinationRule`, and `HTTPRoute`. RHCL
> would treat A2A traffic as plain **HTTP/JSON-RPC**, without semantically
> interpreting the A2A protocol.

## What A2A looks like on the wire

A2A is **JSON-RPC 2.0 over HTTPS** with optional **SSE** streaming:

| Concern | A2A surface | RHCL handling |
| --- | --- | --- |
| Discovery | `GET /.well-known/agent-card.json` | Plain HTTP GET |
| Synchronous call | `POST` `message/send` (JSON-RPC) | Plain HTTP POST + JSON body |
| Streaming | `POST` `message/stream` (SSE) | HTTP response streaming |
| Task lifecycle | `tasks/get`, `tasks/cancel` | Plain HTTP POST |

Everything is L7 HTTP, so RHCL carries it like any other HTTP/JSON-RPC backend.

## Target flow

```text
In-cluster client / app
    │  POST a2a.<zone>/  (JSON-RPC: message/send | message/stream)
    v
RHCL gateway (rhcl-apps-gateway)
    │  HTTPRoute a2a-external-agent  (host a2a.<zone>)
    v
DestinationRule a2a-external-agent  (TLS origination, SNI)
    │
    v
ServiceEntry a2a-external-agent  (MESH_EXTERNAL, DNS)
    │  HTTPS :443
    v
External A2A agent (e.g. Microsoft Copilot Studio / Azure AI Foundry)
```

## Files

| Path | Purpose |
| --- | --- |
| [`manifests/00-serviceentry-a2a-agent.yaml`](manifests/00-serviceentry-a2a-agent.yaml) | Register the external A2A host as a mesh-external service |
| [`manifests/10-destinationrule-a2a-agent.yaml`](manifests/10-destinationrule-a2a-agent.yaml) | TLS origination (SIMPLE; switch to MUTUAL for mTLS) |
| [`manifests/20-httproute-a2a.yaml`](manifests/20-httproute-a2a.yaml) | Publish the agent under `a2a.${RHCL_ZONE_ROOT_DOMAIN}` |
| [`manifests/21-virtualservice-a2a-alternative.yaml`](manifests/21-virtualservice-a2a-alternative.yaml) | Egress routing fallback when HTTPRoute external backendRefs are unsupported |
| [`../req027.md`](../req027.md) | Requirement overview |

## Prerequisites

- RHCL/Kuadrant installed with the shared `rhcl-apps-gateway` (Istio Gateway in
  `openshift-ingress`).
- Outbound network egress allowed from the cluster to the external agent host.
- The external A2A agent reachable over **HTTPS :443** with a valid public
  certificate (or a CA you can pin in the DestinationRule).
- `envsubst` from `gettext`.

```bash
export RHCL_ZONE_ROOT_DOMAIN="$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')"
export A2A_AGENT_HOST="my-agent.example.azurewebsites.net"   # external A2A host
```

## Apply on the cluster

```bash
for f in 00-serviceentry-a2a-agent 10-destinationrule-a2a-agent 20-httproute-a2a; do
  envsubst < "tests/req027/manifests/${f}.yaml" | oc apply -f -
done

oc -n rhcl-apps get serviceentry,destinationrule,httproute -l rhcl.poc/item=27
```

If your Istio/RHCL version does not resolve external hostnames as HTTPRoute
`backendRefs`, use the VirtualService fallback instead of `20-`:

```bash
envsubst < tests/req027/manifests/21-virtualservice-a2a-alternative.yaml | oc apply -f -
```

## How to verify

```bash
export A2A_URL="https://a2a.${RHCL_ZONE_ROOT_DOMAIN}"

# 1. Agent Card discovery (proves the egress path + TLS origination)
curl -sk "${A2A_URL}/.well-known/agent-card.json" | jq '{name,version,url}'

# 2. JSON-RPC message/send (replace params with a valid A2A message)
curl -sk -X POST "${A2A_URL}/" \
  -H 'content-type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{ "kind": "text", "text": "ping" }],
        "messageId": "m1"
      }
    }
  }' | jq .

# 3. Streaming (SSE) — expect a text/event-stream response
curl -sk -N -X POST "${A2A_URL}/" \
  -H 'content-type: application/json' \
  -H 'accept: text/event-stream' \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/stream","params":{}}'
```

Success: the Agent Card returns over the RHCL hostname and `message/send`
reaches the external agent with a JSON-RPC reply.

## Does the plan work?

**Yes, at the transport layer** — with caveats, consistent with the disclaimer
above:

- **ServiceEntry + DestinationRule (TLS origination):** standard, well-supported
  Istio egress pattern. This is the solid core of the design.
- **HTTPRoute to an external host:** routing a Gateway API `backendRef` to a
  `ServiceEntry` hostname depends on the Istio/RHCL version. Where it is not
  supported, the included **VirtualService** (`21-`) is the broadly supported
  fallback for gateway → ServiceEntry egress.
- **JSON-RPC + SSE:** both are plain HTTP, so `message/send` and `message/stream`
  traverse RHCL unchanged. Keep idle/stream timeouts high enough on the
  HTTPRoute for long-running SSE tasks.
- **What RHCL does NOT do:** it does not parse the A2A protocol, validate Agent
  Cards, route by skill/task, or enforce A2A-level auth. RHCL only sees HTTP
  method, path, headers, and body.
- **Auth:** the external product's credential (API key / OAuth bearer) is passed
  through as an HTTP header. RHCL can add Kuadrant `AuthPolicy` for *ingress*
  auth on `a2a.<zone>`, but cannot interpret A2A's own auth scheme.
- **mTLS to the agent:** only if the external product supports it — switch the
  DestinationRule to `mode: MUTUAL` and provide client cert material.

In short, the plan is a valid **HTTP/JSON-RPC passthrough**; it is not an
A2A-aware gateway and is not a certified Red Hat + Microsoft architecture.

## Conceptual integration with IBM watsonx Orchestrate

> **Important**
>
> This section describes an **architectural possibility** for integrating Red Hat
> Connectivity Link with **IBM watsonx Orchestrate**, a product external to the
> Red Hat portfolio.
>
> The configuration is **not part of the implementation scope** of this project
> and must **not** be interpreted as a joint architecture certified or validated
> by Red Hat and IBM.
>
> IBM watsonx Orchestrate supports integration with external agents through the
> Agent-to-Agent (A2A) protocol, as well as agents that expose an OpenAI
> Chat Completions–compatible API. In this scenario, an agent running on
> OpenShift can be registered in watsonx Orchestrate as an external collaborator
> agent.
>
> The example reuses the external-service access pattern documented for Red Hat
> Connectivity Link — `ServiceEntry`, `DestinationRule`, and `HTTPRoute`. RHCL
> would act as an intermediary layer for routing, TLS, authentication, policy
> enforcement, and observability of the traffic between the agent hosted on
> OpenShift and IBM watsonx Orchestrate.
>
> Although A2A traffic is carried over HTTP and uses structured messages
> (typically JSON-RPC), RHCL does **not** semantically interpret the A2A
> protocol. Capabilities such as agent discovery, Agent Card reading, task
> delegation, task state control, and A2A message validation remain the
> responsibility of the agent and of IBM watsonx Orchestrate.
>
> Endpoint availability, the A2A protocol version, the authentication mechanisms,
> and the limitations of the watsonx Orchestrate deployment modality must be
> validated before production adoption.

Unlike the Microsoft scenario above, here watsonx Orchestrate is the **caller**
and the OpenShift agent is the **collaborator** — traffic flows *into* the
cluster. IBM documents adding external agents to watsonx Orchestrate using both
the A2A standard and an OpenAI Chat Completions–style API. The current ADK
exposes an A2A identifier (e.g. `external_chat/A2A/0.3.0`); since that version
may evolve, it is intentionally not pinned in the notice above.

```text
IBM watsonx Orchestrate
        |
        | HTTPS / A2A
        | JSON-RPC
        v
Red Hat Connectivity Link
        |
        | HTTPRoute + policies
        v
External agent on OpenShift
        |
        +-- Agent Card
        +-- A2A endpoint
        +-- Agent logic
        +-- Internal models and services
```

### Responsibilities — IBM watsonx Orchestrate

- Register the external agent.
- Read the metadata published by the agent.
- Select the agent as a collaborator.
- Delegate tasks using the A2A protocol.
- Track task state and results.
- Combine the result with the execution flow of the other agents.

### Responsibilities — Red Hat Connectivity Link

- Publish or broker the agent endpoint.
- Control request routing.
- Apply TLS to the traffic.
- Validate credentials at the gateway ingress.
- Apply authorization policies.
- Rate-limit request volume.
- Generate metrics and observability data.
- Standardize access to the agent hosted on OpenShift.

### Responsibilities — the external agent

- Implement an A2A protocol version compatible with watsonx Orchestrate.
- Serve the Agent Card at the expected endpoint.
- Process A2A messages and tasks.
- Return responses in the format defined by the protocol.
- Implement additional authentication when required.
- Control task state.
- Integrate with the required models, tools, and services.

RHCL does **not** automatically turn a conventional API into an A2A agent. If the
application does not implement the protocol, an adapter is required to expose the
Agent Card and convert A2A messages to the application's internal API.

IBM documents the A2A flow using a discovery endpoint such as
`/.well-known/agent.json` and JSON-RPC requests for message and task delegation.

### Difference from the Azure AI Foundry scenario

For IBM watsonx Orchestrate there is **explicit documentation** to import
external agents, use the A2A protocol, use external agents as collaborators, and
communicate with endpoints hosted outside IBM. Therefore it is accurate to state:

> IBM watsonx Orchestrate has documented support for consuming external
> A2A-compatible agents.

But it would **not** be accurate to state:

> Red Hat Connectivity Link has native integration with IBM watsonx Orchestrate.

The correct relationship is:

```text
watsonx Orchestrate
    └── understands and uses A2A

Red Hat Connectivity Link
    └── transports, secures, observes, and governs the HTTP traffic
```

The `ServiceEntry` + `DestinationRule` pattern is consistent with RHCL
documentation for registering and configuring TLS for external services. The
`HTTPRoute` defines routing behavior but does not implement the functional rules
of the A2A protocol.

> **Deployment limitation**
>
> The integration must account for the watsonx Orchestrate deployment modality.
> Certain A2A partner-agent capabilities documented by IBM are **not available**
> in the on-premises deployment. Compatibility must be validated specifically for
> the version and modality in use.
>
> When watsonx Orchestrate is installed on IBM Software Hub, Red Hat OpenShift AI
> may be required to run local models. That relationship is different from the
> integration described in this section: OpenShift AI provides the inference
> infrastructure, while RHCL governs connectivity to the endpoints.

IBM currently states that Partner A2A agents are not supported in the on-premises
deployment. Separately, IBM states that Red Hat OpenShift AI is required when
watsonx Orchestrate runs models locally, but not when it uses the AI Gateway to
access third-party models.

## Cleanup

```bash
oc -n rhcl-apps delete serviceentry,destinationrule,httproute,virtualservice \
  -l rhcl.poc/item=27 --ignore-not-found
```

## Related requirements

- **req 024** — external model/endpoint access (ServiceEntry/DestinationRule pattern)
- **req 017** — RHCL lab MCP servers for OpenShift AI
- **req 059** — MCP Gateway (dedicated Istio Gateway for agent tooling)
