# Tutorial template — standardization guide

> **This is not a tutorial itself** — it is the canonical structure that
> every `tests/reqNNN.md` must follow. Model file: [`req030.md`](req030.md).

---

## Style rules (apply to every runbook)

- **Language:** English. Portuguese content in existing runbooks must be translated.
- **Voice:** didactic. The reader is a customer engineer *learning what RHCL does*.
  Show **specifically what was configured** — the exact AuthPolicy field, the exact
  ConfigMap key, the exact HTTPRoute rule index. Not just "we added rate limiting".
- **Tone:** operator-first. Assume they have `oc` and will paste your commands.
- **Length:** 200-400 lines is typical. Shorter is fine if the surface is small;
  longer only if the mechanism has real depth (e.g. WasmPlugin, ext_authz).
- **Preserve technical accuracy.** Never invent defaults, dates, resource names,
  or behavior. Cross-check with the Ansible template if unsure.
- **Ansible + kubectl parity.** Give both paths for Apply/Cleanup so the reader
  can pick.

---

## Canonical section order (15 sections)

Sections in **bold** are mandatory. Others are optional per the notes.

1. **`# Item NN — <Short title>`**
2. **`## Requirement demonstrated`** — 1-row markdown table with the exact
   requirement text from the PoC scope document.
3. **`## Target service`** — which backend/service/hostname the demo uses,
   and whether it's shared or dedicated. Table of endpoints if multiple.
4. **`## Architecture overview`** — ASCII diagram showing
   `client → gateway → policies → backend` with the components involved,
   **followed by a Components list** naming each RHCL resource (Gateway,
   HTTPRoute, AuthPolicy, RateLimitPolicy, ConfigMap, EnvoyFilter, etc.)
   with 1-line purpose each.
5. `## <MechanismA> vs <MechanismB>` — **only when the req has more than
   one mechanism** (like req030's ext_authz vs mirror). If the req has
   one mechanism, skip this section — its content belongs in #6.
6. **`## How <X> is done`** — the walkthrough. Break down the mechanism
   in **tables** (data / step / decision / trade-off). This is where you
   name specific fields: "the AuthPolicy's `spec.rules.authentication.
   api-key-header.credentials.customHeader.name` is set to `api-key`".
7. `## Inputs / outputs (validation payload)` — the exact headers,
   body, and expected response codes. Include a JSON body example if
   the demo sends one. Skip only if the req is purely infra (no
   request-path demo).
8. **`## Known limitations`** — 2-column table (Topic | Limitation).
   Include the surprising gotchas discovered while implementing.
9. **`## Manifests (reference render)`** — table with 4 columns:
   File / Resource / Purpose / Automation source (the Ansible template
   that renders it). Note "Manual manifests only" if there's no Ansible.
10. **`## Apply`** — 2 code blocks:
    - Standalone `oc apply` sequence (numbered)
    - Ansible batch alternative (env var + `ansible-playbook` invocation)
11. **`## Validate`** — `validate.sh` invocation + a manual `curl` example
    that shows the exact headers/body/expected response.
12. **`## Expected evidence`** — what the reader should see when it
    works: HTTP code, response body shape, log lines to grep for,
    metrics that should populate. Include `oc logs` invocations.
13. **`## Success criteria`** — **numbered** list. Each item = one binary
    pass/fail check the reader can verify.
14. **`## Cleanup`** — reverse of Apply. Both kubectl and Ansible paths.
15. **`## Relationship with other requirements`** — cross-references to
    other reqs that share mechanism, backend, or scope. Bullet list.

---

## Section guidance

### Section 1 — Title
Follow `# Item NN — Short title` verbatim. For grouped items (like
req061-65) use `# Items NN–NN — Group name`.

### Section 2 — Requirement demonstrated
Use the exact PoC requirement wording. Example:

```
| Item | Requirement |
|------|-------------|
| **26** | File streaming with maximum and average size — byte flow. |
```

### Section 3 — Target service
Clarify:
- Is the backend shared (banking-api-v1 on the main hostname) or dedicated
  (a new hostname created for this req)?
- Which endpoints of the backend are exercised?
- What is the hostname format (e.g. `req030.${RHCL_ZONE_ROOT_DOMAIN}`)?

### Section 4 — Architecture overview
Diagram MUST include the RHCL flow. Typical shape:

```
                  ┌─────────────────────────┐
    client ─TLS─► │  rhcl-apps-gateway      │
                  └───────────┬─────────────┘
                              │
                              ▼
                  ┌──────────────────────────┐
                  │  <policy/filter chain>   │
                  │  <what the req adds>     │
                  └───────────┬──────────────┘
                              │
                              ▼
                  ┌──────────────────────────┐
                  │  banking-api-v1 or other │
                  └──────────────────────────┘
```

After the diagram, a **Components** subsection listing every RHCL
resource the req touches, one bullet each with a 1-sentence purpose.

### Section 5 — Vs comparison (optional)
Use when there are two mechanisms doing the same job with different
trade-offs (like req030). Two subsections + a merged decision table:

- `### <A>` — how it works, when to use
- `### <B>` — how it works, when to use
- `### Both together` (if applicable)

### Section 6 — How X is done
This is the didactic core. Show specifically:
- Which CR was created / patched
- Which field controls the behavior (name it — `spec.rules.authentication...`)
- Why that choice (link the field to the requirement)

Use tables to compare inputs/outputs when possible.

### Section 7 — Inputs / outputs
For a request-path demo: what headers does the request carry, what body,
what is the expected response envelope. Concrete examples over abstract.

### Section 8 — Known limitations
Include the non-obvious gotchas — the things that would take a customer
engineer hours to discover on their own. Examples from req030:
- "ext_authz body size only sends first 8192 bytes"
- "`openshift-gateway` Istio CR is operator-managed; extension provider
  patches may be reconciled away"

### Section 9 — Manifests
4-column table. Include ALL manifests, not just the interesting ones.
Format:

```
| File | Resource | Purpose | Automation source |
|------|----------|---------|-------------------|
| [`reqNN/manifests/01-foo.yaml`](reqNN/manifests/01-foo.yaml) | AuthPolicy | Enforces API key auth on the route | `automation/roles/apps/templates/reqNN-authpolicy.yml.j2` |
```

If no Ansible template exists (manual-only req), write `Manual manifests only`
in the last column.

### Section 10 — Apply
Two subsections. First: `cd tests/reqNN/manifests && oc apply -f ...`
with each command commented (`# what this does`). Second: the env-var-guarded
Ansible playbook invocation.

### Section 11 — Validate
Reference to the script FIRST (`bash tests/reqNN/scripts/validate.sh`),
then a manual `curl` block for readers who want to poke without a script.

### Section 12 — Expected evidence
What visible-state to check after Apply. Include:
- `oc get` commands with expected output shape
- `oc logs` grep patterns
- Metric names to query in Grafana/Prometheus
- HTTP response codes/headers on the validate request

### Section 13 — Success criteria
Numbered, binary, verifiable. Example:

```
1. `banking-api-v1` pod is Ready in `rhcl-apps`.
2. AuthPolicy is `Enforced`.
3. `POST /api/echo` returns `200` with echoed body.
```

### Section 14 — Cleanup
Reverse of Apply — both paths.

### Section 15 — Relationship
Bullet list, format `**Item NN** — reason for cross-ref`.

---

## Cross-cutting checklist (verify before commit)

- [ ] Title matches `# Item NN — <title>` (or `Items NN–NN` for grouped)
- [ ] All 15 sections present (or #5 justified skip)
- [ ] Language is English throughout
- [ ] ASCII arch diagram shows gateway + policies + backend
- [ ] Every RHCL resource named in `Components` also in `Manifests` table
- [ ] Every claim about defaults / limits verifiable in the Ansible template
- [ ] `Apply` has both kubectl and Ansible paths
- [ ] `Validate` references `validate.sh` if it exists in `reqNN/scripts/`
- [ ] `Success criteria` are binary, not "should mostly work"
- [ ] `Relationship` cross-refs are correct req numbers
