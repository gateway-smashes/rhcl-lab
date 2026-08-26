# Item 65 — Delegação para serviço externo

A arquitetura RHCL/Kuadrant **já delega** rate limiting para um serviço externo por design. Não há rate limiting embutido no gateway.

## Como funciona

O Envoy (data plane do Gateway) implementa o filtro `envoy.filters.http.ratelimit`, que pra cada requisição faz uma chamada gRPC ao serviço configurado em `rate_limit_service.grpc_service`. O serviço responde `OK` ou `OVER_LIMIT`, e o Envoy aplica.

O contrato é o `envoy.service.ratelimit.v3.RateLimitService` ([proto](https://github.com/envoyproxy/envoy/blob/main/api/envoy/service/ratelimit/v3/rls.proto)) — qualquer implementação compatível pode plugar.

## Implementações compatíveis

| Implementação | Mantenedor | Storage |
|---------------|------------|---------|
| **Limitador** (default no Kuadrant) | Kuadrant / Red Hat | in-memory, disk, Redis, redis-cached |
| [Lyft `ratelimit`](https://github.com/envoyproxy/ratelimit) | Lyft / Envoy community | Redis |
| Stripe internal | Stripe (closed-source, referência) | DynamoDB |
| Comerciais | Upstash, Aiven, AWS API Gateway etc. | Vendor-specific |

## Verificando no cluster

A configuração efetiva do Envoy fica no Pod do Gateway (controller Istio):

```bash
GATEWAY_POD=$(oc get pod -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway \
  -o jsonpath='{.items[0].metadata.name}')

# Dump do bootstrap; procure por rate_limit_service
oc exec -n openshift-ingress $GATEWAY_POD -- \
  curl -s localhost:15000/config_dump | \
  python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps([c for c in d['configs'] if 'cluster' in str(c).lower()],indent=2))" \
  | grep -i -A 5 "limitador\|rate_limit"
```

A saída mostra um cluster Envoy chamado `rate_limit_cluster` apontando para o Service `limitador-limitador.kuadrant-system.svc.cluster.local:8081`.

## Como trocar pro Lyft `ratelimit` (alto nível)

> **Pra PoC**: este é só um esquema. A Kuadrant mantém o Limitador como parte do produto suportado pela Red Hat. Trocar por outra implementação tira você do caminho suportado, mas o contrato é aberto.

1. Deployar o `ratelimit` da Lyft num namespace dedicado (ex: `external-ratelimit`), expor via Service `ratelimit:8081`.
2. Apagar o `Limitador` CR (`oc delete limitador limitador -n kuadrant-system`).
3. Editar o `Kuadrant` CR para apontar pro Service alternativo (não há campo direto na CR pública — exigirá patch no operator ou EnvoyFilter custom).
4. Validar via `config_dump` que o Envoy fala com o novo cluster.

## Configurando o Limitador para usar Redis externo (caminho suportado)

Esta é a opção **suportada** que satisfaz "delegação para serviço externo de rate limit" sem trocar o componente Kuadrant. Veja [`02-limitador-redis.yaml`](02-limitador-redis.yaml) — o Limitador continua sendo o serviço, mas o **estado** vai pro Redis externo, atendendo também o item 62 (multi-site).

## Validação documental para o cliente

Para o auditor do RHCL, a evidência de "delega rate limit a serviço externo" é o output do `config_dump` (acima) mostrando `rate_limit_cluster` apontando pro Pod externo, não para um filtro local do Envoy. Esse output é suficiente como artefato de comprovação.
