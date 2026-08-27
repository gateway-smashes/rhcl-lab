---
title: WebSocket routing
summary: Route real-time WebSocket APIs through the Gateway API.
category: Traffic & routing
status: done
---

# WebSocket routing

Demonstrates WebSocket connectivity between the browser and the banking-api
backend — both directly and through RHCL / the Gateway API — for real-time
balance and transfer-status updates without HTTP polling.

## What it demonstrates

- The gateway upgrades an HTTP GET (`Upgrade: websocket`) to a bidirectional
  WebSocket and proxies it to the backend, with no extra annotation, filter or
  Gateway configuration — Istio (the RHCL data plane) supports WebSocket
  natively; the path just needs to be routed.
- After a transfer, the backend broadcasts a sequence of events over the socket:
  `transfer.pending → transfer.processing → transfer.completed → balance.updated`
  (plus a `backend.health` heartbeat every ~1s).

```
Scenario — with RHCL / Gateway API

  Frontend --wss://gateway-host/ws/live--> RHCL Gateway (Istio) --ws://backend:8080/ws/live--> Backend (Quarkus)
            (HTTP GET + Upgrade)            - terminates TLS                                    broadcasts:
                                            - applies policies                                 transfer.pending
                                            - upgrades HTTP → WS                               transfer.processing
                                            - bidirectional proxy                              transfer.completed
                                                                                               balance.updated
```

## Files

- [index.html](index.html) — single-file interactive page (no build step).

## Prerequisites

1. **Backend** running with the `/ws/live` WebSocket endpoint (shipped with
   `banking-api`).
2. **HTTPRoute** must include a rule for the `/ws` path pointing at the backend.
   **This is the most common cause of failure** — if `/ws/live` is not mapped,
   the gateway rejects the connection before the upgrade happens.
3. **Frontend** (Red Bank) configured to point its WebSocket at the RHCL gateway
   host.

### The required HTTPRoute rule

```yaml
    # WebSocket rule — required
    - matches:
        - path:
            type: PathPrefix
            value: /ws
      backendRefs:
        - name: banking-api-v1       # backend Service
          port: 8080
```

> **No CORS filter needed** — WebSocket connections do not use the browser CORS
> mechanism; the `Sec-WebSocket-*` handshake differs from XHR/fetch and fires no
> preflight `OPTIONS`.

## Run it

Serve the page (any port works — it connects over WebSocket to the configured
URL, so the backend must be reachable):

```bash
# from the repo root
python3 -m http.server 9090 --directory tests/websocket-routing
# open http://localhost:9090
```

Then:

1. **Set the WebSocket URL** — use a preset (localhost or RHCL Gateway) or type
   it. The gateway URL is persisted in `localStorage`.
2. **Click Connect** — the page opens a WebSocket to `/ws/live`; the badge turns
   `connected` (green).
3. **Send a transfer** — *Send transfer* POSTs to the REST endpoint
   `/api/v1/transfers`; the backend processes it and emits WebSocket events.
4. **Watch the events** — the log shows each JSON message and the stage
   indicators advance `PENDING → PROCESSING → COMPLETED → BALANCE UPDATED`.
5. **Terminal commands** — copy-ready `websocat`, `wscat` and `curl` blocks.

### Command-line tests

```bash
# websocat (recommended)
websocat wss://banking-api-connectivity.apps.example.com/ws/live

# wscat (needs Node.js: npm install -g wscat)
wscat -c wss://banking-api-connectivity.apps.example.com/ws/live

# curl — verify the HTTP upgrade (expect 101 Switching Protocols)
curl -iv --no-buffer \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://banking-api-connectivity.apps.example.com/ws/live
# < HTTP/1.1 101 Switching Protocols
# < upgrade: websocket
# < connection: upgrade
```

A `404` or a failed connection means the `/ws` rule is missing from the
HTTPRoute.

## What to look for

- The badge shows **connected**; `backend.health` heartbeats appear ~every 1s.
- After *Send transfer*, four events arrive in sequence: `transfer.pending →
  transfer.processing → transfer.completed → balance.updated`, and the stage
  indicators advance grey → yellow → green.
- In the **Red Bank** frontend, the "Live operations feed (WebSocket)" card shows
  `v1: connected`, the transfer-status card advances PENDING → PROCESSING →
  COMPLETED, and the balance card updates automatically ~2s later (no Refresh).

### Backend WebSocket events

| Event | Delay | Description |
|---|---|---|
| `transfer.pending` | 0ms | Transfer received, awaiting processing |
| `transfer.processing` | ~600ms | Transfer being processed |
| `transfer.completed` | ~1500ms | Transfer completed |
| `balance.updated` | ~2000ms | Balance updated (includes an account snapshot) |
| `backend.health` | every 1s | Backend health heartbeat |

Example `balance.updated` message:

```json
{
  "type": "balance.updated",
  "apiVersion": "v1",
  "instance": "banking-api-v1",
  "transferId": "a1b2c3d4-...",
  "amount": 1000,
  "accountTotal": 5441.43,
  "banks": [
    { "bankName": "Example Bank", "account": "1234-5", "balance": 2200.43 },
    { "bankName": "Metro Bank",   "account": "8888-9", "balance": 790.80 },
    { "bankName": "Global Bank",  "account": "1010-1", "balance": 2450.20 }
  ],
  "timestamp": "2026-05-06T11:00:02.000Z"
}
```

### Failure signals

- WebSocket status `disconnected` → the `/ws` path is not in the HTTPRoute.
- Transfer sent but no events / balance does not auto-update → the socket is
  disconnected (the frontend falls back to a degraded, poll-to-refresh mode).
- Console error `WebSocket connection to 'wss://...' failed` → the gateway
  rejected the connection (HTTPRoute missing the `/ws` rule).
