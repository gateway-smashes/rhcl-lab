# RHCL 1.4.1 — EnvoyFilter reconcile churn OOM-kills the gateway

## Summary

On **RHCL / `rhcl-operator` 1.4.1** (AWS cluster `mycluster`, 2026-07-08), the
`kuadrant-operator-controller-manager` rewrote the
`openshift-ingress/kuadrant-rhcl-apps-gateway` EnvoyFilter **~2×/second,
indefinitely** (generation reached 766k+, istiod logged 107k+ debounced pushes
for that single resource). Every write triggered a full xDS push; Envoy
re-instantiated the Kuadrant wasm plugin (remote code fetch) on each push and
accumulated memory until the gateway pod hit its 1Gi limit and was
**OOMKilled ~37s after start** — a permanent `CrashLoopBackOff` (206 restarts
over 19h). Result: the whole `rhcl-apps-gateway` data plane down (TLS
handshake timeouts on the ELB).

## Root cause (two layers)

1. **Loop trigger — invalid OPA rego in an AuthPolicy.** The
   `rhcl-apps/ipfilter-ip-acl` AuthPolicy (item 72 PoC) declared
   `default allow := false` in its `rego`. Authorino already injects its own
   `default allow` into the compiled policy, so the AuthConfig failed with
   `rego_type_error: multiple default rules … .allow` and never became Ready.
   The AuthPolicy stayed `Enforced=False ("waiting for components to sync")`
   and the kuadrant-operator retried in a hot loop, rewriting the AuthPolicy
   status + EnvoyFilter + topology ConfigMap on every pass.

2. **Loop sustainer — non-deterministic wasm config ordering.** Each reconcile
   serializes the wasm shim config with the 47 `actionSets` in a **different
   order** (content is byte-identical per set; only ordering flaps — verified
   by structural diff). Since the operator also *watches* EnvoyFilters, every
   self-write triggers the next reconcile: the loop becomes **self-sustaining
   even after the AuthPolicy is fixed**. This is an operator bug in 1.4.1
   (no z-stream available on the `stable` channel as of 2026-07-08).

## Fixes / workarounds applied (AWS cluster)

1. **Fixed the rego** — removed the `default allow := false` line from
   `authpolicy/ipfilter-ip-acl` (Authorino provides the default; keep only
   `allow if not denied_match`). AuthConfigs then compiled, but stayed
   `HostsNotLinked` until an `oc rollout restart deploy/authorino -n
   kuadrant-system` cleared Authorino's index. AuthPolicy became `Enforced`.

2. **Paused the operator** — `oc scale deploy/kuadrant-operator-controller-manager
   -n kuadrant-system --replicas=0`. Churn stops instantly. Authorino,
   Limitador, dns-operator and the already-written EnvoyFilters keep the data
   plane fully functional (auth, rate-limit, DNS publishing all live).

3. **Kept `plugin.wasm` served** — the wasm binary is served *by the operator
   pod* (`kuadrant-operator-wasm` Service :8082), so with the operator at 0
   the gateway 503s with `wasm_fail_stream`. Deployed
   `kuadrant-system/kuadrant-wasm-static` (initContainer curls `plugin.wasm`
   while the operator is briefly up; `python3 -m http.server` serves it with
   the Service's selector labels). Verified sha256 identical
   (`7ac45a63…`).

4. **Dropped h2 from the wasm fetch cluster** — the EnvoyFilter's
   `kuadrant-operator-wasm` CLUSTER patch sets `http2_protocol_options`, which
   the python server can't speak. Removed that field from
   `envoyfilter/kuadrant-rhcl-apps-gateway` (sticks while the operator is
   paused) and restarted the gateway pod. Gateway loads the wasm and serves
   normally (200/401 as expected).

## Operating model while the workaround is active

- The kuadrant-operator on the AWS cluster is **scaled to 0**. Policy CR
  changes (AuthPolicy / RateLimitPolicy / DNSPolicy / TLSPolicy) will NOT
  propagate while it is down.
- To apply a policy change: scale the operator to 1, wait for the change to
  land (expect the churn/OOM to resume within ~40s), scale back to 0, then
  `oc delete pod -n openshift-ingress -l
  gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway` and re-remove
  `http2_protocol_options` from the EnvoyFilter (the operator will have
  re-added it).
- If the `kuadrant-wasm-static` pod restarts while the operator is down its
  initContainer cannot re-fetch the wasm; scale the operator to 1 briefly.

## Proper fix

- Escalate to Red Hat: operator reconcile loop caused by non-deterministic
  wasm `actionSets` ordering in RHCL 1.4.1 (plus hot status retry on
  never-enforced policies). Reference this doc's evidence.
- Never ship `default allow`/`default deny` rules inside AuthPolicy `rego` —
  Authorino injects its own defaults; declare only the positive rules.

## Related

- Sibling issue (1.4.0): [rhcl-14-gateway-wasm-incompat.md](rhcl-14-gateway-wasm-incompat.md)
- Diagnosed: 2026-07-08 on cluster `mycluster.sandbox546` (AWS, RHCL 1.4.1,
  Istio 1.27.3) while enabling multicluster DNS load balancing (items 008–010).
