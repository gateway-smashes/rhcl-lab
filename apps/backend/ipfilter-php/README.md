# RHCL IP Filter Probe

Small PHP application used by the RHCL PoC to validate source-IP filtering
without touching the main banking API route.

The page shows:

- The peer address seen by PHP (`REMOTE_ADDR`).
- The `x-forwarded-for` chain received through the gateway.
- The first IP in `x-forwarded-for`, used as the effective client IP in the
  PoC IP ACL policy.

The JSON endpoint is available at `/api/ip`; health checks use `/healthz`.
