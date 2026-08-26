# REQ 61–65 — Rate Limit (PoC)

Pacote de demonstração para os itens 61–65 do PoC do RHCL. Veja [`../req061-65-RateLimit.md`](../req061-65-RateLimit.md) para o contexto e mapeamento item-a-item.

## Arquivos

| Arquivo | Item | O que demonstra |
|---------|------|-----------------|
| [`manifests/01-global-same-site.yaml`](manifests/01-global-same-site.yaml) | 61 | RLP global simples, contadores compartilhados entre instâncias do Gateway |
| [`manifests/02-limitador-redis.yaml`](manifests/02-limitador-redis.yaml) | 62, 65 | Aponta o Limitador pro Redis do `shared-store` — externaliza contadores (multi-site + delegação a estado externo) |
| [`manifests/03-custom-counters.yaml`](manifests/03-custom-counters.yaml) | 63 | RLP com counters por header (`x-customer-id`) e IP de origem |
| [`manifests/04-api-vs-gateway.yaml`](manifests/04-api-vs-gateway.yaml) | 64 | RLP a nível de Gateway com `defaults` (e exemplo comentado de `overrides`) |
| [`manifests/05-external-architecture.md`](manifests/05-external-architecture.md) | 65 | Documentação da arquitetura de delegação Envoy → serviço externo |
| [`manifests/06-redis-shared-store.yaml`](manifests/06-redis-shared-store.yaml) | 62, 65 | Sobe um Redis no namespace `shared-store` (mesmo cluster) pra servir de backend de contadores |
| [`index.html`](index.html) | 61–63 | Console PoC standalone para gerar carga, visualizar 200 vs 429 ao longo do tempo, e alternar entre cenários |

> **Status de validação** (cluster sandbox AWS, OCP 4.20 / Kuadrant 1.3.3):
> Items **61, 63, 64, 62, 65** todos validados end-to-end. Item 64 confirmado nos
> dois sentidos: gateway-level `defaults` é sobrescrito por API-level; gateway-level
> `overrides` impõe teto inegociável. Item 62/65 com Redis no `shared-store` —
> contadores comprovadamente persistidos no Redis (via `redis-cli --scan`).

## Pré-requisitos

```bash
# Login no cluster
oc whoami

# Banking-api instalado (via apps-install playbook)
oc get httproute banking-api-connectivity -n rhcl-apps
oc get gateway rhcl-apps-gateway -n openshift-ingress
oc get limitador limitador -n kuadrant-system
```

A rota `/api/echo` é pública (sem APIKey) — usada pra demos que não dependem de autenticação. Para os cenários que exercitam `auth.identity.userid` (counter `per-user` em 03), use `/api/v1/...` com a chave APIKey gold/silver/bronze (veja `req015.md`).

## Cenário 1 — Item 61 (global, mesmo site)

```bash
oc apply -f manifests/01-global-same-site.yaml

HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

# Disparar 60 requests EM PARALELO contra /api/echo (público)
# Sequencial não funciona — TLS handshake espalha pelo tempo e a janela
# 10s não é violada. Use ampersand + wait.
{ for i in $(seq 1 60); do
    curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/api/echo" &
  done; wait; } | sort | uniq -c
# Esperado com policy 20/10s: 20x 200 + 40x 429
```

Para provar que o limite é compartilhado entre múltiplas instâncias do gateway, escale o gateway:

```bash
# Encontrar o Deployment do Envoy do gateway
GW_DEPLOY=$(oc get deploy -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway -o jsonpath='{.items[0].metadata.name}')
oc scale deploy/$GW_DEPLOY -n openshift-ingress --replicas=3
oc rollout status deploy/$GW_DEPLOY -n openshift-ingress

# Repita o burst — deve cair no mesmo limite (20/10s) mesmo com 3 envoys
# servindo, porque os 3 falam com o mesmo Limitador.
```

## Cenário 2 — Item 63 (custom counters)

```bash
oc apply -f manifests/03-custom-counters.yaml

HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

# Cliente "alpha" — 10 reqs paralelos (limite 5/min)
{ for i in $(seq 1 10); do
    curl -sk -o /dev/null -w "alpha=%{http_code}\n" \
      -H "x-customer-id: alpha" "https://$HOST/api/echo" &
  done; wait; } | sort | uniq -c

# Cliente "beta" — counter independente
{ for i in $(seq 1 10); do
    curl -sk -o /dev/null -w "beta=%{http_code}\n" \
      -H "x-customer-id: beta" "https://$HOST/api/echo" &
  done; wait; } | sort | uniq -c
# Esperado: alpha 5/5, beta 5/5 — counters separados por valor de header
```

Counter por user autenticado: o lab já tem isso pronto via `PlanPolicy banking-api-plans` que gera uma RLP automática usando `auth.identity.metadata.annotations.secret\.kuadrant\.io/plan-id`. Limites por tier (gold=unlimited, silver=50/min, bronze=10/min). Para testar:

```bash
# bronze trava em 10/min
{ for i in $(seq 1 15); do
    curl -sk -o /dev/null -w "bronze=%{http_code}\n" \
      -H "api-key: carol-bronze-secret" "https://$HOST/api/v1/accounts/summary" &
  done; wait; } | sort | uniq -c
# Esperado: 10x 200 + 5x 429
```

> **Nota sobre composição**: ter `req063-custom-counters` enforced (target HTTPRoute) faz com que `banking-api-plans` (mesmo target) entre como Overridden. Para coexistirem, considere usar `sectionName` para diferenciar regras targetadas, ou aplicar PlanPolicy/RLP em recursos diferentes.

## Cenário 3 — Item 64 (Gateway + API simultâneos)

```bash
# Apply ambos
oc apply -f manifests/01-global-same-site.yaml      # API-level (HTTPRoute)
oc apply -f manifests/04-api-vs-gateway.yaml        # Gateway-level

# Ver as policies
oc get ratelimitpolicy -A -l app.kubernetes.io/part-of=rhcl-req61-65-ratelimit

# A request precisa passar nos dois limites; o mais restritivo prevalece.
```

Para forçar que o gateway-level seja **inegociável**, edite [`manifests/04-api-vs-gateway.yaml`](manifests/04-api-vs-gateway.yaml) trocando `defaults:` por `overrides:`. Após isso, mesmo um time de API que coloque `100000/s` na sua policy não consegue ultrapassar o teto.

## Cenário 4 — Item 62/65 (Redis compartilhado, estado externalizado)

O Limitador, por default, guarda os contadores **em memória** no próprio pod.
Pra rate limit global de verdade (e multi-site), o estado precisa sair pra um
store externo. Aqui usamos um **Redis no próprio cluster**, num namespace
dedicado `shared-store`.

### Passo 1 — Subir o Redis no `shared-store`

```bash
oc apply -f manifests/06-redis-shared-store.yaml
oc -n shared-store rollout status deploy/redis

# Sanity check
POD=$(oc -n shared-store get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')
oc -n shared-store exec $POD -- sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'   # PONG
```

### Passo 2 — Apontar o Limitador pro Redis

```bash
oc apply -f manifests/02-limitador-redis.yaml
oc -n kuadrant-system rollout status deploy/limitador-limitador

# Confirma o storage
oc -n kuadrant-system get limitador limitador -o jsonpath='{.spec.storage}'; echo
```

### Passo 3 — Validar (contadores agora vivem no Redis)

```bash
oc apply -f manifests/01-global-same-site.yaml
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')

{ for i in $(seq 1 60); do curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/api/echo" & done; wait; } | sort | uniq -c
# Esperado com 01 (20/10s): 20x 200 + 40x 429

# PROVA de que o estado está no Redis (não na memória do pod):
POD=$(oc -n shared-store get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')
oc -n shared-store exec $POD -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --scan' | grep -i counter
# namespace:{rhcl-apps/banking-api-connectivity},counter:{"limit":{...limit.global_burst...}}
```

### Multi-site (VALIDADO — 2 clusters AWS compartilhando contadores)

Cada cluster roda seu próprio Limitador, mas **todos apontam pro mesmo Redis**.
Validado entre dois clusters OpenShift independentes (sandboxes AWS distintas,
ambos `us-east-2`):

- **Cluster A** (`x5xfd`) hospeda o Redis no `shared-store` e o expõe via Service
  `LoadBalancer` (ELB classic, TCP 6379) **restrito por `loadBalancerSourceRanges`
  ao IP de egress do cluster B**. O Redis demo não tem TLS nem ACL forte, então o
  source-range é a trava de rede.
- **Cluster B** (`lpv5p`) recebe a stack completa (Gateway API + Kuadrant + app
  `banking-api`) e o `URL` do Secret `limitador-redis` aponta pro ELB do cluster A.

Pré-requisito de rede: o Redis precisa ser alcançável de todos os clusters —
Service via LoadBalancer/Route TCP (como aqui), VPC peering, ou um Redis
gerenciado central (ElastiCache/Azure Cache/Memorystore).

```bash
# (Cluster B) descobrir o IP de egress — vai virar o source-range do LB:
oc --kubeconfig=$KCFG_B run egress --image=registry.access.redhat.com/ubi9/ubi-minimal \
   --restart=Never --rm -i -- curl -s ifconfig.me                       # ex.: 18.188.159.202

# (Cluster A) expor o Redis SÓ pra esse IP (Service LoadBalancer com sourceRanges):
#   spec.type: LoadBalancer / spec.loadBalancerSourceRanges: ["18.188.159.202/32"]
REDIS_LB=$(oc -n shared-store get svc redis-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# (Cluster B) URL do Secret limitador-redis = redis://default:<senha>@$REDIS_LB:6379/0
```

#### De onde vem o limite — a RateLimitPolicy

O `20/10s` não é config de infra: é declarado numa **RateLimitPolicy** anexada à
HTTPRoute. É a MESMA policy (`manifests/01-global-same-site.yaml`) dos cenários
anteriores — e é exatamente ela que precisa existir **idêntica nos dois
clusters**:

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: req061-global-same-site
  namespace: rhcl-apps
spec:
  targetRef:                      # anexa à HTTPRoute (não ao Gateway)
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: banking-api-connectivity
  limits:
    global-burst:
      rates:
        - limit: 20               # ← O LIMITE: 20 requests…
          window: 10s             # ← …por janela de 10s
```

Mostre-a viva **em cada cluster** antes do teste — o `spec.limits` tem que ser
idêntico dos dois lados (é o que garante a mesma chave de contador):

```bash
# rode em CADA cluster (A e B) — deve imprimir exatamente a mesma coisa:
oc get ratelimitpolicy req061-global-same-site -n rhcl-apps \
  -o jsonpath='{.spec.limits}{"\n"}'
#   {"global-burst":{"rates":[{"limit":20,"window":"10s"}]}}

# e confirme que o Kuadrant aceitou E está impondo a policy nos dois:
oc get ratelimitpolicy req061-global-same-site -n rhcl-apps \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
#   Accepted=True Enforced=True
```

O Kuadrant Operator compila `limits.global-burst` numa entrada do **Limitador** +
um descritor no Envoy. A **chave de contador** resultante é derivada do conteúdo
da RLP + a identidade da route — `limit.global_burst__69c1664f` no namespace
`{rhcl-apps/banking-api-connectivity}`. Como os dois clusters aplicam esta policy
idêntica contra a mesma HTTPRoute (mesmo nome/namespace), os dois derivam **a
mesma chave** → apontando pro mesmo Redis, incrementam **um único contador**. É
por isso que o `20/10s` vale pro par de sites, não por site.

#### ⚠️ `redis` vs `redis-cached` — escolha que define o multi-site

O `02-limitador-redis.yaml` usa `redis-cached`, que mantém um **cache local de
contadores em cada site** e sincroniza com o Redis em lote (`flush-period`). Isso
otimiza latência/disponibilidade, mas **NÃO garante limite global estrito**: um
site com cache "frio" admite requests antes de enxergar o consumo dos outros.

| storage        | Teste sequencial (A:18 → B:18, limite 20/10s) | Comportamento |
|----------------|------------------------------------------------|---------------|
| `redis-cached` | A=18×200, **B=18×200** (36 no total)           | Cache local por site → over-admite. Eventualmente consistente. |
| `redis`        | A=18×200, **B=5×200 + 13×429** (≈23 no total)  | Toda checagem bate no Redis → limite global **estrito**. |

Pra limite global **estrito** entre sites, troque o storage pra `redis` puro nos
**dois** clusters:

```bash
oc -n kuadrant-system patch limitador limitador --type=json \
  -p '[{"op":"replace","path":"/spec/storage","value":{"redis":{"configSecretRef":{"name":"limitador-redis"}}}}]'
oc -n kuadrant-system rollout status deploy/limitador-limitador
```

Validação cross-cluster (com `redis` estrito):

```bash
# Consome a maior parte do budget no cluster A, depois ataca o B:
for i in $(seq 1 18); do curl -sk -o /dev/null "https://$HOST_A/api/echo" & done; wait   # ~18x 200
sleep 1
for i in $(seq 1 18); do curl -sk -o /dev/null "https://$HOST_B/api/echo" & done; wait   # maioria 429
# O cluster B enxerga o consumo do A pelo contador compartilhado → trava no mesmo 20/10s.

# PROVA do contador único: a MESMA chave no Redis sobe com tráfego de QUALQUER site
POD=$(oc -n shared-store get pod -l app=redis -o jsonpath='{.items[0].metadata.name}')
oc -n shared-store exec $POD -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern "*global_burst*"'
# 0 → 5 (após 5x no cluster A) → 10 (após 5x no cluster B): um contador, dois sites.
```

> Pequenos overages (ex.: 23 em vez de 20) são normais sob concorrência contra
> qualquer contador distribuído — `check`-then-`increment` não é atômico no burst.

> **Produção**: o Redis do `06-redis-shared-store.yaml` usa `emptyDir` (volátil)
> e sem TLS (tráfego intra-cluster). Pra produção: PVC + replicação/Sentinel ou
> Redis gerenciado, e `rediss://` (TLS) no `URL`.

## Validação visual (PoC Console)

Abra o frontend `mobile-bank` → **PoC Console → Rate Limiting**:

1. Escolher cenário (Item 61, 63 ou 64)
2. Configurar header customizado (apenas Item 63)
3. Clicar **Run** — dispara N reqs e plota:
   - Histograma 200 vs 429 ao longo do tempo
   - Latência média
   - Distribuição por bucket (alpha/beta/...)

## Limpeza

```bash
# RLPs de teste (mantém banking-api-plans do install)
oc delete -f manifests/01-global-same-site.yaml -f manifests/03-custom-counters.yaml \
          -f manifests/04-api-vs-gateway.yaml --ignore-not-found

# Voltar Limitador pra in-memory
oc -n kuadrant-system patch limitador limitador --type=merge -p '{"spec":{"storage":null}}'
oc -n kuadrant-system delete secret limitador-redis --ignore-not-found

# Derrubar o Redis do shared-store (apaga o namespace inteiro)
oc delete -f manifests/06-redis-shared-store.yaml --ignore-not-found
```

> Não use `oc delete -f manifests/` sem listar os arquivos: o glob inclui o
> `05-external-architecture.md` (que não é manifest) e dá erro. Liste os YAMLs
> explicitamente como acima.

## Troubleshooting

| Sintoma | Diagnóstico |
|---------|-------------|
| Sem 429 mesmo após muitos requests sequenciais | `curl` sequencial introduz ~200ms entre reqs por causa do TLS handshake. Janela de 10s pode não ser estourada. Use **paralelo**: `{ for i in ...; do curl … & done; wait; }` |
| 429 demais (todos os requests) | Counter está bloqueando. Conferir window — janelas curtas (`1s`) somadas a delays podem confundir. Usar `1m` no demo. |
| Limitador em CrashLoop após apply de RLP com `request.headers["..."]` | Bug de quoting: aspas duplas dentro da CEL aninham na chave do descriptor sem escape. Use **aspas simples**: `request.headers['x-customer-id']`. |
| RLP com 3+ entradas em `limits` não aplica nada | Bug observado quando uma das entradas usa `auth.identity` e outra usa só `request.*`. Limite a **2 entradas** em `limits` por RLP, ou compose RLPs separadas com `sectionName` diferentes. |
| Limites diferentes entre clusters apesar de Redis | Verificar conectividade do Limitador ao Redis: `oc logs deploy/limitador-limitador -n kuadrant-system \| grep -i redis`. Latência > timeout (350ms) faz fallback ao cache local, divergindo contadores. |
| RLP do Gateway não afeta nada | Quando ambas (Gateway-level com `defaults` e API-level) coexistem, a API-level vence. Para teto absoluto use `overrides:` no Gateway-level. |
| Multiple RLPs Enforced=False/Overridden | Apenas **uma RLP por target** é enforced. Se quiser composição, use targets distintos (HTTPRoute + Gateway com `overrides`) ou `sectionName` para targetar regras específicas. |
