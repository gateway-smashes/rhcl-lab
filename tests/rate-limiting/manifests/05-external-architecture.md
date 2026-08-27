# External rate-limit-service delegation

The RHCL / Kuadrant architecture **already delegates** rate limiting to an
external service by design. There is no rate limiting built into the gateway.

## How it works

Envoy (the Gateway data plane) implements the `envoy.filters.http.ratelimit`
filter, which for each request makes a gRPC call to the service configured in
`rate_limit_service.grpc_service`. The service replies `OK` or `OVER_LIMIT`, and
Envoy enforces it.

The contract is `envoy.service.ratelimit.v3.RateLimitService`
([proto](https://github.com/envoyproxy/envoy/blob/main/api/envoy/service/ratelimit/v3/rls.proto))
— any compatible implementation can plug in.

## Compatible implementations

| Implementation | Maintainer | Storage |
|---------------|------------|---------|
| **Limitador** (Kuadrant default) | Kuadrant / Red Hat | in-memory, disk, Redis, redis-cached |
| [Lyft `ratelimit`](https://github.com/envoyproxy/ratelimit) | Lyft / Envoy community | Redis |
| Stripe internal | Stripe (closed-source, reference) | DynamoDB |
| Commercial | Upstash, Aiven, AWS API Gateway, etc. | Vendor-specific |

## Verifying on the cluster

The effective Envoy config lives in the Gateway pod (Istio controller):

```bash
GATEWAY_POD=$(oc get pod -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway \
  -o jsonpath='{.items[0].metadata.name}')

# Dump the bootstrap; look for rate_limit_service
oc exec -n openshift-ingress $GATEWAY_POD -- \
  curl -s localhost:15000/config_dump | \
  python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps([c for c in d['configs'] if 'cluster' in str(c).lower()],indent=2))" \
  | grep -i -A 5 "limitador\|rate_limit"
```

The output shows an Envoy cluster named `rate_limit_cluster` pointing at the
`limitador-limitador.kuadrant-system.svc.cluster.local:8081` Service.

## Switching to Lyft `ratelimit` (high level)

> **For the lab**: this is a sketch only. Kuadrant maintains Limitador as part of
> the Red-Hat-supported product. Swapping in another implementation takes you off
> the supported path, but the contract is open.

1. Deploy Lyft `ratelimit` in a dedicated namespace (e.g. `external-ratelimit`),
   exposed via a `ratelimit:8081` Service.
2. Delete the `Limitador` CR (`oc delete limitador limitador -n kuadrant-system`).
3. Edit the `Kuadrant` CR to point at the alternative Service (there is no direct
   field on the public CR — it requires an operator patch or a custom EnvoyFilter).
4. Validate via `config_dump` that Envoy talks to the new cluster.

## Using Limitador with an external Redis (the supported path)

This is the **supported** option that satisfies "delegation to an external
rate-limit service" without replacing the Kuadrant component. See
[`02-limitador-redis.yaml`](02-limitador-redis.yaml) — Limitador remains the
service, but the **state** moves to an external Redis, which also covers the
multi-site case.

## Documentary evidence

The evidence for "rate limiting delegated to an external service" is the
`config_dump` output above, showing `rate_limit_cluster` pointing at the external
pod rather than a local Envoy filter. That output is sufficient as proof.
