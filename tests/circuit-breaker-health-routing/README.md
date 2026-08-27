---
title: Circuit breaker / health-driven routing
summary: The gateway pulls a backend out of rotation when its readiness flips to down, and restores it when it returns to healthy.
category: Traffic & routing
status: not-started
---

# Circuit breaker / health-driven routing

**Goal:** the gateway should pull a backend out of rotation when readiness flips
to `down`, and put it back when it returns to `healthy`.

**Backend (curl):**

```bash
# Make v1 unhealthy (readiness will start returning 503)
curl -s -X POST $BACKEND/api/test/mode \
  -H 'content-type: application/json' \
  -d '{"mode":"down"}'

curl -i $BACKEND/q/health/ready          # → HTTP/1.1 503

# Restore
curl -s -X POST $BACKEND/api/test/mode \
  -H 'content-type: application/json' \
  -d '{"mode":"healthy"}'

curl -i $BACKEND/q/health/ready          # → HTTP/1.1 200
```

**Frontend (PoC console):** **Chaos** tab → set the *Mode* dropdown to `down` →
press *Apply mode*. The "Readiness" indicator dot turns red and shows `503`.
Switch back to `healthy` to see it go green again.

**Expected result:** `/q/health/ready` flips between 200 and 503 in lockstep
with the chosen mode; with a gateway in front, traffic stops hitting the
instance while it's `down`.

---