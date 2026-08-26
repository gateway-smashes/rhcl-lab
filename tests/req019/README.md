# REQ 19 — Motor de políticas com expressões personalizadas (CEL)

Pacote de demonstração para o item 19 do PoC do RHCL. Demonstra o uso de **CEL (Common Expression Language)** como motor de expressões personalizadas no Kuadrant/RHCL para controle de acesso e rate limiting contextual.

## O que é CEL no Kuadrant?

O Kuadrant utiliza CEL como linguagem nativa de expressões nas policies. CEL permite escrever condições complexas que avaliam atributos da requisição em tempo real:

- **`when.predicate`** — expressões que determinam QUANDO uma regra se aplica (AuthPolicy, RateLimitPolicy)
- **`counters.expression`** — expressões que definem chaves de contagem dinâmica (RateLimitPolicy)

Referência: https://docs.kuadrant.io/dev/kuadrant-operator/doc/cel/introduction/

## Arquivos

| Arquivo | O que demonstra |
|---------|-----------------|
| [`manifests/01-cel-custom-expressions.yaml`](manifests/01-cel-custom-expressions.yaml) | `AuthPolicy` integrada: mantém API Key + adiciona regras de authorization com CEL |
| [`manifests/02-cel-ratelimit-expressions.yaml`](manifests/02-cel-ratelimit-expressions.yaml) | `RateLimitPolicy` com CEL em `when` e `counters` para rate limiting por contexto |
| [`index.html`](index.html) | Console PoC standalone para testar as expressões interativamente |

## Funcionalidades CEL demonstradas

| Funcionalidade CEL | Exemplo na policy | Onde |
|--------------------|-------------------|------|
| Operadores lógicos (`&&`, `\|\|`, `!`) | `request.method == 'POST' && request.path.startsWith(...)` | AuthPolicy authorization |
| Funções de string (`startsWith`) | `request.path.startsWith('/api/v1/transfers')` | AuthPolicy `cel-transfer-idempotency` |
| Funções de string (`contains`) | `request.headers['user-agent'].contains('bot')` | AuthPolicy `cel-bot-blocking` |
| Comparação direta de header | `request.headers['x-cel-strict'] == 'true'` | AuthPolicy `cel-transfer-idempotency` |
| Negação de condições (`!`) | `!request.path.startsWith('/api/echo')` | AuthPolicy `cel-bot-blocking` |
| Expressão em counter | `request.headers['x-idempotency-key']` | RateLimitPolicy |
| Predicates compostos em rate limit | `request.method == 'POST' && (path1 \|\| path2)` | RateLimitPolicy |

## Abordagem: integração na AuthPolicy principal

As regras CEL de authorization estão integradas diretamente na AuthPolicy
`banking-api-connectivity-apikey`, criada automaticamente pelo Ansible
(`automation/roles/apps/templates/connectivity-authpolicy-apikey.yml.j2`).

A AuthPolicy:

1. **Mantém** todas as regras de authentication inalteradas (API Key, CORS, WebSocket, etc.)
2. **Inclui** regras de authorization com expressões CEL
3. **Preserva** a compatibilidade com o PlanPolicy (`auth.identity` continua disponível)
4. **Não impacta** os demais testes — as regras CEL são ativadas por condições específicas

```
Pipeline Authorino:

  Request → Authentication (API Key / anônimo)  ← INALTERADO
          → Authorization  (CEL expressions)    ← NOVO
          → Response       (userid, plan-id)    ← INALTERADO
```

### Regras CEL adicionadas (authorization)

| Regra | Condição CEL (when) | Efeito | Impacto nos demais testes |
|-------|---------------------|--------|---------------------------|
| `cel-transfer-idempotency` | `request.method == 'POST' && request.path.startsWith('/api/v1/transfers')` **E** `request.headers['x-cel-strict'] == 'true'` | Exige `x-idempotency-key` | **Nenhum** — só ativa quando `x-cel-strict: true` está presente |
| `cel-bot-blocking` | `request.headers['user-agent'].contains('bot')` **E** `request.method != 'OPTIONS'` **E** `!request.path.startsWith('/api/echo')...` | Bloqueia com 403 | **Nenhum** — nenhum teste existente usa 'bot' como user-agent |

## Pré-requisitos

```bash
oc whoami

oc get httproute banking-api-connectivity -n rhcl-apps
oc get gateway rhcl-apps-gateway -n openshift-ingress
oc get authpolicy banking-api-connectivity-apikey -n rhcl-apps
oc get authorino authorino -n kuadrant-system
oc get limitador limitador-limitador -n kuadrant-system
```

## Cenário A — AuthPolicy com CEL (Controle de Acesso)

### Verificar pré-condição

A AuthPolicy já é criada pelo Ansible com as regras CEL integradas. Basta
confirmar que está Enforced:

```bash
oc get authpolicy banking-api-connectivity-apikey -n rhcl-apps \
  -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}'
# Esperado: True
```

> **Nota:** Não é necessário aplicar nenhum manifest manualmente para o Cenário A.
> O arquivo `manifests/01-cel-custom-expressions.yaml` serve como referência e
> pode ser usado para re-aplicar caso necessário com:
> `oc apply --server-side --force-conflicts -f manifests/01-cel-custom-expressions.yaml`

### Teste 1: Fluxo normal preservado — GET com API Key (200)

Confirma que o comportamento anterior continua intacto.

```bash
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps \
       -o jsonpath='{.spec.hostnames[0]}')

curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "api-key: <SUA_API_KEY>" \
  "https://$HOST/api/v1/accounts/summary"
```

**Esperado:** `200` — authentication por API Key funciona normalmente

### Teste 2: Fluxo normal preservado — POST transfer sem x-cel-strict (200)

Confirma que transferências sem o modo strict continuam funcionando.

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -X POST "https://$HOST/api/v1/transfers" \
  -H "api-key: <SUA_API_KEY>" \
  -H "content-type: application/json" \
  -d '{"fromBank":"Example Bank","toBank":"EXTERNAL","amount":100}'
```

**Esperado:** `200` — regra `cel-transfer-idempotency` NÃO é ativada (sem `x-cel-strict`)

### Teste 3: CEL bot-blocking — user-agent com 'bot' (403)

Demonstra CEL: `request.headers['user-agent'].contains('bot')`

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "api-key: <SUA_API_KEY>" \
  -H "user-agent: my-bot-scraper/1.0" \
  "https://$HOST/api/v1/accounts/summary"
```

**Esperado:** `403` — authorization rule `cel-bot-blocking` nega o request

### Teste 4: CEL bot-blocking — user-agent normal (200)

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "api-key: <SUA_API_KEY>" \
  -H "user-agent: Mozilla/5.0 RedHatBankApp/2.1" \
  "https://$HOST/api/v1/accounts/summary"
```

**Esperado:** `200` — user-agent não contém 'bot', authorization passa

### Teste 5: CEL idempotency (strict) — SEM x-idempotency-key (403)

Demonstra CEL: `request.method == 'POST' && request.path.startsWith('/api/v1/transfers')` + `request.headers['x-cel-strict'] == 'true'`

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -X POST "https://$HOST/api/v1/transfers" \
  -H "api-key: <SUA_API_KEY>" \
  -H "x-cel-strict: true" \
  -H "content-type: application/json" \
  -d '{"fromBank":"Example Bank","toBank":"EXTERNAL","amount":100}'
```

**Esperado:** `403` — modo strict ativado, `x-idempotency-key` ausente → OPA nega

### Teste 6: CEL idempotency (strict) — COM x-idempotency-key (200)

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -X POST "https://$HOST/api/v1/transfers" \
  -H "api-key: <SUA_API_KEY>" \
  -H "x-cel-strict: true" \
  -H "x-idempotency-key: txn-$(date +%s)-001" \
  -H "content-type: application/json" \
  -d '{"fromBank":"Example Bank","toBank":"EXTERNAL","amount":100}'
```

**Esperado:** `200` — modo strict ativado, `x-idempotency-key` presente → OPA permite

### Teste 7: Paths públicos continuam livres (200)

```bash
# /api/echo não exige API Key nem sofre CEL
curl -sk -o /dev/null -w "%{http_code}\n" \
  -X POST "https://$HOST/api/echo" \
  -H "content-type: application/json" \
  -H "user-agent: bot-test/1.0" \
  -d '{"test": true}'
```

**Esperado:** `200` — path público excluído do bot-blocking pelo predicate `!request.path.startsWith('/api/echo')`

## Cenário B — RateLimitPolicy com CEL (Rate Limiting contextual)

### Aplicar

```bash
oc apply -f manifests/02-cel-ratelimit-expressions.yaml

# Verificar status
oc get ratelimitpolicy req019-cel-ratelimit -n rhcl-apps -o yaml | yq '.status.conditions'
```

### Teste 8: Rate limit por idempotency-key (5 req/min)

```bash
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps \
       -o jsonpath='{.spec.hostnames[0]}')

for i in $(seq 1 8); do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    -X POST "https://$HOST/api/v1/transfers" \
    -H "api-key: <SUA_API_KEY>" \
    -H "content-type: application/json" \
    -H "x-idempotency-key: same-key-burst-test" \
    -d '{"fromBank":"Example Bank","toBank":"EXT","amount":10}'
done | sort | uniq -c
```

**Esperado:** ~5x `200` + ~3x `429` (limite 5/min compartilhado pela mesma chave)

### Teste 9: Chaves diferentes têm buckets independentes

```bash
for key in alpha beta gamma; do
  echo "--- key: $key ---"
  for i in $(seq 1 3); do
    curl -sk -o /dev/null -w "%{http_code} " \
      -X POST "https://$HOST/api/v1/transfers" \
      -H "api-key: <SUA_API_KEY>" \
      -H "content-type: application/json" \
      -H "x-idempotency-key: $key" \
      -d '{"fromBank":"Example Bank","toBank":"EXT","amount":10}'
  done
  echo ""
done
```

**Esperado:** todas `200` (3 req de cada chave, abaixo do limite de 5/min)

### Teste 10: Rate limit por consumer-id em leituras (60 req/min)

```bash
for i in $(seq 1 65); do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "api-key: <SUA_API_KEY>" \
    -H "x-consumer-id: consumer-alpha" \
    "https://$HOST/api/v1/accounts/summary"
done | sort | uniq -c
```

**Esperado:** ~60x `200` + ~5x `429`

## Inspecionando a decisão

```bash
# Logs do Authorino (AuthPolicy)
oc -n kuadrant-system logs deploy/authorino -f \
  | grep -E "rhcl-apps|cel|bot|idempotency"

# Status da AuthPolicy
oc -n rhcl-apps get authpolicy banking-api-connectivity-apikey -o yaml | yq '.status'

# Status da RateLimitPolicy
oc -n rhcl-apps get ratelimitpolicy req019-cel-ratelimit -o yaml | yq '.status'

# AuthConfig gerada (ver as regras de authorization)
oc -n rhcl-apps get authconfig -o yaml | yq '.items[].spec.authorization'
```

## Limpeza

A AuthPolicy com CEL é parte permanente do ambiente (criada pelo Ansible),
portanto não necessita de restauração. Apenas a RateLimitPolicy do Cenário B
precisa ser removida após os testes:

```bash
oc delete ratelimitpolicy req019-cel-ratelimit -n rhcl-apps --ignore-not-found
```

Se por algum motivo a AuthPolicy precisar ser recriada no estado padrão:

```bash
cd automation
ansible-playbook playbooks/apps-install.yml --tags connectivity
```

## Troubleshooting

| Sintoma | Diagnóstico |
|---------|-------------|
| Policy fica "Accepted (Not Enforced)" | Há outra AuthPolicy com nome diferente no mesmo HTTPRoute. Verifique: `oc get authpolicy -n rhcl-apps`. Se existir `req019-cel-custom-expressions` (nome antigo), delete-a: `oc delete authpolicy req019-cel-custom-expressions -n rhcl-apps` |
| "Not Enforced" + log `multiple default rules ... allow` | O Authorino injeta `default allow = false` automaticamente no Rego. **Não declare** `default allow` no seu código Rego; use apenas `allow { condições }`. |
| "Not Enforced" + log `var cannot be used for rule name` | A sintaxe `allow if { ... }` requer `import future.keywords.if`. Use a sintaxe clássica Rego: `allow { condições }` (sem `if`). |
| "Not Enforced" + log `invalid argument to has() macro` | O Authorino não suporta `has()` com acesso por índice de mapa (`has(request.headers['x'])`). Use comparação direta: `request.headers['x'] == 'valor'`. Header ausente retorna string vazia. |
| AuthConfigs "stuck" em `false` (0/1) | AuthConfigs criados com Rego inválido ficam permanentemente em estado de erro. Delete todos (`oc delete authconfig -n kuadrant-system --all`) para forçar recriação com o Rego corrigido. |
| Todos os requests retornam 403 mesmo sem 'bot' | A regra de authorization pode estar mal avaliada. Verifique logs: `oc -n kuadrant-system logs deploy/authorino -f`. Confirme que o `when` predicate do `cel-bot-blocking` não está matchando erroneamente. |
| Teste de idempotency não bloqueia (sempre 200) | Verifique se o header `x-cel-strict: true` está sendo enviado. Sem ele, a regra `cel-transfer-idempotency` não é ativada (by design). |
| Rate limit não funciona (nunca 429) | Verificar se o Limitador está healthy: `oc get limitador -n kuadrant-system`. Verificar se a RateLimitPolicy está `Enforced`. |
| PlanPolicy parou de funcionar | A seção `response.success.filters.identity` deve manter os selectors de `userid` e `plan-id`. Confirme que não foram removidos acidentalmente. |
| Limitador entra em CrashLoop | Aspas duplas na expressão de counter quebram o parser. Use SEMPRE aspas simples: `request.headers['x-foo']` (nunca `request.headers["x-foo"]`). |

## Referências

- [Kuadrant CEL Introduction](https://docs.kuadrant.io/dev/kuadrant-operator/doc/cel/introduction/)
- [Kuadrant AuthPolicy API](https://docs.kuadrant.io/dev/kuadrant-operator/doc/reference/authpolicy/)
- [Kuadrant RateLimitPolicy API](https://docs.kuadrant.io/dev/kuadrant-operator/doc/reference/ratelimitpolicy/)
