# Itens 61–65 — Rate Limit

## Requisitos demonstrados

| Item | Requisito |
|------|-----------|
| **61** | Mecanismo de Rate Limit Global, considerando todas as instâncias de Gateway estando no mesmo site |
| **62** | Mecanismo de Rate Limit Global, considerando a possibilidade de Gateways em sites distintos |
| **63** | Customização de Rate Limit a partir de custom fields |
| **64** | Configuração de Rate Limit a nível de API e/ou de Gateway |
| **65** | Capacidade de delegar para serviço externo o serviço de rate limit |

---

## Visão geral da arquitetura

```
                                     ┌─────────────────┐
   client ──── HTTPS ──► Envoy ─gRPC─►   Limitador     │
                          │              (Kuadrant)    │
                          │           ┌────────────────┤
                          │           │ Storage:       │
                          │           │  • in-memory   │ (default — same-site only)
                          │           │  • disk (PVC)  │
                          │           │  • redis       │ ◄── multi-site / external state
                          │           │  • redis-cached│
                          │           └────────────────┘
                          ▼
                       backend
```

**Componentes**:

- **Envoy** (no Gateway, gerenciado pelo OpenShift Gateway API controller): ponto de policy enforcement. Para cada request, consulta o serviço externo de ratelimit via gRPC e bloqueia/passa baseado na resposta.
- **Limitador** (`limitador.kuadrant.io/v1alpha1`): serviço externo de ratelimit operado pelo Kuadrant. Implementa o contrato `envoy.service.ratelimit.v3.RateLimitService`.
- **Kuadrant Operator**: traduz `RateLimitPolicy` (alta-nível) em configuração Envoy + entradas no `Limitador` CR.
- **Storage backend**: onde os contadores ficam. Define o escopo do "global" — single-site (default in-memory) vs multi-site (redis compartilhado).

---

## Mapeamento por item

### Item 61 — Global, mesmo site

**Contexto**: vários replicas do Gateway (Envoy) consultando o mesmo Limitador. Já que o Limitador é um serviço único (1 ou mais replicas com storage compartilhado), os contadores são vistos por todas as instâncias do Gateway.

**Default do lab**: 1 replica de Limitador, storage `in-memory`. Funciona como global enquanto o número de Limitador estiver em 1 replica.

**Demo**: aplicar uma `RateLimitPolicy` simples com limite global e validar que múltiplas conexões compartilham o contador. Manifest em [`req061-65-RateLimit/manifests/01-global-same-site.yaml`](req061-65-RateLimit/manifests/01-global-same-site.yaml).

### Item 62 — Global, sites distintos

**Contexto**: dois (ou mais) clusters, cada um com seu Gateway/Envoy, precisam compartilhar contadores. Solução: trocar o storage do Limitador para **Redis compartilhado** (ou redis-cached).

**Pré-requisito**: instância Redis acessível pelos clusters (managed Redis, Redis no openshift-data-foundation, Aiven, Upstash etc.).

**Demo**: trocar `Limitador.spec.storage` para `redis` apontando pro Secret do endpoint, observar que dois clusters dividem o limite. Manifest em [`req061-65-RateLimit/manifests/02-limitador-redis.yaml`](req061-65-RateLimit/manifests/02-limitador-redis.yaml).

### Item 63 — Custom fields

**Contexto**: limites por atributo da requisição — header customizado, claim de JWT, query string, IP de origem, identidade autenticada, etc. Tudo via expressões CEL no `RateLimitPolicy.spec.limits.<name>.counters[].expression`.

**Demo**: limites separados por `auth.identity.userid` (já fazemos isso no `PlanPolicy`), por header `x-customer-id`, e por `request.remote_address`. Manifest em [`req061-65-RateLimit/manifests/03-custom-counters.yaml`](req061-65-RateLimit/manifests/03-custom-counters.yaml).

### Item 64 — API e/ou Gateway

**Contexto**: dois targets possíveis para `RateLimitPolicy.spec.targetRef`:

- `kind: HTTPRoute` → policy a nível de **API/rota** (granular, por path/método)
- `kind: Gateway` → policy a nível de **gateway** (coarse, aplica-se a tudo que passa)

As duas podem coexistir. Em conflito, a precedência segue o algoritmo do Gateway API: gateway-level **defaults** são sobrepostos por API-level; gateway-level **overrides** sobrepõem API-level. Isso permite ao operador do gateway impor um teto absoluto.

**Demo**: aplicar simultaneamente uma RLP no Gateway (limite global anti-DDoS) + RLP no HTTPRoute (limite por API). Manifest em [`req061-65-RateLimit/manifests/04-api-vs-gateway.yaml`](req061-65-RateLimit/manifests/04-api-vs-gateway.yaml).

### Item 65 — Delegação para serviço externo

**Contexto**: a arquitetura **já é** delegada por design. O Envoy não computa rate limit — chama um serviço externo via gRPC `envoy.service.ratelimit.v3.RateLimitService`. O Limitador é uma das implementações desse contrato, mantida pela Kuadrant. Outras implementações compatíveis: [Lyft `ratelimit`](https://github.com/envoyproxy/ratelimit), serviços comerciais (Upstash, AWS API Gateway).

**Demo**: explicar a arquitetura de delegação, mostrar a chamada gRPC no Envoy bootstrap (`rate_limit_service.grpc_service.envoy_grpc.cluster_name = limitador`), e documentar como apontar para um serviço alternativo. Detalhes em [`req061-65-RateLimit/manifests/05-external-architecture.md`](req061-65-RateLimit/manifests/05-external-architecture.md).

---

## Demonstração interativa

- **PoC Console** (frontend `mobile-bank` → aba **Rate Limiting**) com gerador de carga, visualização de 200 vs 429 ao longo do tempo, contador por bucket (header customizado, IP, user-id) e botões pra cada cenário.
- Página HTML standalone em [`req061-65-RateLimit/index.html`](req061-65-RateLimit/index.html) com a mesma funcionalidade independente do app Flutter.

Veja [`req061-65-RateLimit/README.md`](req061-65-RateLimit/README.md) para o passo-a-passo completo de aplicação dos manifests, validação via `curl` e troubleshooting.

---

## Apply rápido (todos os cenários)

```bash
export ROOT=tests/req061-65-RateLimit/manifests

# Item 61 — basic global
oc apply -f $ROOT/01-global-same-site.yaml

# Item 63 — custom counters
oc apply -f $ROOT/03-custom-counters.yaml

# Item 64 — gateway + api combined
oc apply -f $ROOT/04-api-vs-gateway.yaml

# Item 62/65 — Redis backend (requer endpoint Redis externo)
# oc apply -f $ROOT/02-limitador-redis.yaml   # editar Secret antes
```

Limpeza:

```bash
oc delete -f tests/req061-65-RateLimit/manifests/ --ignore-not-found
```
