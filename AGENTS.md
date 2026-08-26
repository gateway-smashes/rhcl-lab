# AGENTS.md

## Purpose

This repository documents the RHCL Proof of Concept workstreams, prerequisites, and lab topologies for corporate and Red Hat lab environments.

## Scope

- Keep all repository content in English.
- Use this repository for PoC documentation, sprint requirements, application inventory, and lab definitions.
- Preserve external diagram/image links unless a replacement asset is added intentionally.
- Treat sprint folders as the operational breakdown of the PoC plan.

## Repository Structure

- `README.md`: shared requirements that apply to all sprints
- `apps/README.md`: application inventory and the per-requirement coverage matrix
- `apps/TESTING.md`: per-requirement test walkthrough (Goal / Backend curl / Frontend PoC console / Expected result), executed against the apps deployed in OpenShift
- `sprint1/README.md` to `sprint4/README.md`: sprint objectives, scope, and deliverables
- `labs/README.md`: lab topology definitions and reference diagrams

## Editing Rules

- Translate any newly added Portuguese content to English before merging it.
- Keep documentation concise and operational.
- Prefer updating the existing README in the relevant folder instead of creating redundant files.
- Use consistent terms: `PoC`, `RHCL`, `lab`, `cluster`, `LDAP`, `mTLS`.
- When adding requirements, write them as short bullet points.
- When adding topology descriptions, keep the naming aligned with the existing lab names.
- When a sprint plan is inferred from planning material rather than copied from an official schedule, state that clearly in the README.

## Documentation Expectations

- Sprint requirements should describe prerequisites and deliverables only.
- The applications section should list backend, frontend, integration, and connectivity components used by the PoC.
- Lab documentation should state the purpose of each lab and the infrastructure footprint it requires.
- Root documentation should summarize PoC goals, technical focus, and out-of-scope items.

## Maintaining `apps/TESTING.md`

`apps/TESTING.md` is the living, executable companion to the coverage matrix in `apps/README.md`. Anyone extending it should follow these rules:

- All commands target the apps **already deployed in OpenShift** by the cluster automation. Do not add `mvn quarkus:dev`, `flutter run`, local TLS profiles, or any other localhost-based setup steps.
- Reuse the environment variables defined in section `0. Prerequisites`: `$NS`, `$BACKEND`, `$BACKEND_V2`, `$FRONTEND`, `$GRPC_HOST`, `$CONSUMER`, `$TRACE`. Derive new variables from `oc get route` / `oc get svc` rather than hardcoding hostnames.
- Use `oc -n $NS …` for cluster operations: `logs` for runtime checks, `set env` for runtime config toggles, `port-forward` for direct-to-Pod gRPC/mTLS tests, and `extract secret/…` for client certs.
- Keep the per-requirement format: a level-3 heading `### Req NN — short title`, then `**Goal:**` (optional), `**Backend (curl):**`, `**Frontend (PoC console):**`, `**Expected result:**`. Separate requirements with `---`.
- Group requirements under the existing phase headings (Phase A–G, Existing capabilities, Out-of-scope) and add a row to the TOC table at the top so the README links keep working.
- When a new requirement is added to the `apps/README.md` coverage matrix, add a matching subsection here in the same revision.
- Frontend references must match the actual PoC console tabs: Chaos, Streaming, AI, Auth, Observability, WebSocket, gRPC-Web. Do not invent tabs.
- Prefer the gateway-fronted Route for tests; only fall back to `oc port-forward` when the protocol cannot traverse the Route (e.g. plaintext gRPC, direct-to-Pod mTLS).

## Test pages under `tests/reqXX/`

Each requirement that ships an interactive PoC console lives under
`tests/reqXX/index.html`, derived from `tests/templates/template.html` and
served by the static container in `tests/Dockerfile`. When creating or
editing one of these pages:

- **Section order is fixed**: `Scenario` -> `Controls` -> `Log` -> any extra
  sections (per-call result panels, matrices, YAML snippets, shell command
  blocks, etc.). The Log panel must sit immediately after Controls so the
  user sees the trigger and its output on the same fold; new sections go
  *after* the Log block, never between Controls and Log.
- **Reuse the template's helpers** (`logLine`, `escapeHtml`, the Red Hat
  CSS variables) instead of redefining them — keep visual parity across
  pages.
- **Runtime env**: pages can read deployment env vars by fetching
  `/env.json` (generated at container start by
  `tests/catalog/generate-env.sh`). Add a new variable to that script's
  whitelist before consuming it from a page; never hardcode lab-specific
  hostnames when an env var is available (e.g. `RHCL_ZONE_ROOT_DOMAIN`).
- **Cluster manifests** that the test depends on go under
  `tests/reqXX/manifests/` and should keep `${RHCL_ZONE_ROOT_DOMAIN}` (and
  similar) as `envsubst` placeholders rather than hardcoded values.

## Notes

- The PoC material references validation of LDAP, mTLS, WebSockets, multicloud routing, CoreDNS, MetalLB, and multi-cluster deployment patterns.
- The planning material indicates a four-environment target topology: `CCT1`, `CCT2`, `Azure`, and `Google Cloud`.
