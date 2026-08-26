# Sail Istio CR — custom `meshConfig.extensionProviders` vs Kuadrant operator

## Background

On the PoC combo (RHCL 1.3.x/1.4.0 + OSSM 3.x), custom
`spec.values.meshConfig.extensionProviders` entries added to the Sail
`Istio` CR (e.g. req030's `envoyExtAuthzHttp` interceptor) shared the
list with the Kuadrant operator, which also managed providers there for
Authorino ext-authz. Reconciles could clobber user-added entries — which
is why `automation/roles/apps/tasks/install.yml` does the defensive
query → reject-same-name → append → merge-patch dance for req030.

## Validation on RHCL 1.4.1 (2026-07-08, cluster `cluster-mck9f`)

Environment: OCP 4.20.27 · OSSM 3.3.5 · Istio v1.26.4 · RHCL 1.4.1.

1. **Kuadrant 1.4.1 no longer touches `meshConfig.extensionProviders` at
   all.** Fresh install with an enforced AuthPolicy shows an empty
   provider list — the auth data path is wired exclusively through
   EnvoyFilters (`kuadrant-auth-<gw>` → wasm-shim → `kuadrant-auth-service`).
   The shared-ownership conflict source is gone.
2. A custom `envoyExtAuthzHttp` provider patched into the Istio CR
   **propagates to the istiod ConfigMap** (`istio-system/istio`,
   `data.mesh`) within seconds.
3. The provider **survives Kuadrant reconciles**: operator pod restart +
   AuthPolicy annotation touch left both the Istio CR entry and the
   istiod mesh config intact, and gateway enforcement (401/403/429)
   kept working throughout.

## Guidance

- The req030 merge dance in Ansible remains correct defensive practice
  (merge, never replace, the provider list), but on 1.4.1 it is no
  longer load-bearing against Kuadrant.
- Keep treating the `Istio` CR as the single source of truth for custom
  providers; never edit the istiod ConfigMap directly (Sail reconciles
  it from the CR).

## References

- Sibling issue: [rhcl-14-gateway-wasm-incompat.md](rhcl-14-gateway-wasm-incompat.md) (RESOLVED)
- req030 runbook: `tests/req030/README.md`
