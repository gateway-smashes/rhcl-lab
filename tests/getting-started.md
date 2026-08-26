# Getting Started — Declarando uma API dentro do RHCL

> **Objetivo:** em ~15 minutos, criar uma nova API autenticada
> (`banking-lite`) do zero, expor pelo gateway RHCL, plumbar autenticação
> por chave, rate limit por consumidor, catalogar no dev portal, testar
> ponta-a-ponta com um cliente real (o mobile-bank), e fazer o
> onboarding de um usuário pelo dev portal. Sem alterar nada da infra
> compartilhada (gateway existente, banking-api existente, dev portal
> existente).

## Requisito

| Item | O que este guide entrega |
|------|--------------------------|
| N/A  | Fluxo de onboarding — tutorial de uso da ferramenta. Não é uma req do PoC, é o hello-world. |

---

## TL;DR — Você vai criar

Uma API nova chamada **`banking-lite`** apontando pro backend
`banking-api-v1` (que já existe), acessível via nova hostname
(`banking-lite.<sua-zona>`), com:

- **7 recursos** no cluster (HTTPRoute + APIProduct + PlanPolicy +
  AuthPolicy + RateLimitPolicy + Secret + APIKey CR)
- **Auth por header `api-key`** — request sem chave → 401
- **Rate limit por tier** — 60 req/min por consumer no plano `demo`
- **Rate limit agregado** — 500 req/min no total da API
- **Aparece no dev portal** — usuário se cadastra e pega chave sozinho
- **Aparece no plugin do Console** (APIProducts → banking-lite)
- **Métricas por consumer** no Grafana (`RHCL API Metrics`)

Testa mudando a URL do mobile-bank pra apontar pra essa nova hostname —
a app funciona igualzinho, agora consumindo pelo novo perímetro RHCL.

---

## Pré-requisitos que você já tem

- Cluster com **RHCL 1.3.4** instalado, gateway `rhcl-apps-gateway` no
  namespace `openshift-ingress`, listener wildcard (qualquer
  `*.<zona>` cai nele)
- **banking-api-v1** já rodando em `rhcl-apps` (é o backend que vamos
  reaproveitar — não vamos deployar app nova)
- **Dev Portal** rodando em `rhcl-devportal` (opcional pro passo do
  onboarding, mas fortemente recomendado)
- **Plugin custom-rhcl-console** instalado (pra visualizar o produto
  na UI)
- **`oc`** logado como cluster-admin ou role com permissão de criar
  Gateway API resources em `rhcl-apps`

---

## O jogo de peças

Sete recursos, três camadas. Antes de aplicar entenda **por que cada
um existe** — assim quando o cliente pedir uma variação você sabe qual
mexer.

```
                          ┌────────────────────────────────────┐
                          │  RHCL Gateway (existente)          │
                          │  hostname wildcard *.<zona>        │
                          └──────────────┬─────────────────────┘
                                         │ parentRef
                                         ▼
        ┌────────────────────────────────────────────────────────┐
        │  HTTPRoute banking-lite                                │
        │  hostname: banking-lite.<zona>                         │
        │  → backendRef: banking-api-v1:8080                     │
        └────────────────────────────┬───────────────────────────┘
                                     │ targetRef (todas as policies)
        ┌────────────────────────────┴───────────────────────────┐
        │                                                        │
   ┌────▼───────────┐  ┌────────────────┐  ┌──────────────────┐  │
   │ AuthPolicy     │  │ PlanPolicy     │  │ RateLimitPolicy  │  │
   │ (api-key)      │  │ (60/min tier)  │  │ (500/min global) │  │
   └────┬───────────┘  └────────────────┘  └──────────────────┘  │
        │                                                        │
        │ selector.matchLabels                                   │
        ▼                                                        │
   ┌────────────────────────┐                                    │
   │ Secret (chave real)    │ ◄──── secretRef ──── ┌─────────────┴────────┐
   │ labels + annotations   │                      │  APIProduct + APIKey │
   │ data.api_key           │                      │  (dev portal / UI)   │
   └────────────────────────┘                      └──────────────────────┘
```

### Camada 1 — Roteamento (2 recursos)

| Recurso | O que faz | Arquivo |
|---------|-----------|---------|
| **HTTPRoute** | Diz "requests em `banking-lite.<zona>/api/*` vão pra Service `banking-api-v1:8080`". Anexa no gateway RHCL existente via `parentRefs`. | [`01-httproute.yaml`](getting-started/manifests/01-httproute.yaml) |
| **APIProduct** | Envelopa a HTTPRoute como um "produto" no catálogo do dev portal. Sem isso, a rota funciona mas o portal não sabe que existe. | [`02-apiproduct.yaml`](getting-started/manifests/02-apiproduct.yaml) |

### Camada 2 — Políticas (3 recursos, todos com `targetRef` → HTTPRoute)

| Recurso | O que faz | Arquivo |
|---------|-----------|---------|
| **PlanPolicy** | Define os planos comerciais (`gold`/`silver`/`demo`) e o rate limit **por consumer** de cada. O Kuadrant escolhe qual aplicar olhando a annotation `plan-id` na chave da request. | [`03-planpolicy.yaml`](getting-started/manifests/03-planpolicy.yaml) |
| **AuthPolicy** | Exige o header `api-key`. Sem chave → 401 no Authorino, backend nem sabe que veio request. | [`04-authpolicy.yaml`](getting-started/manifests/04-authpolicy.yaml) |
| **RateLimitPolicy** | Teto **agregado** de toda a API (soma de TODOS os consumers). Roda em paralelo à PlanPolicy — quem chegar no limite primeiro dispara 429. | [`05-ratelimitpolicy.yaml`](getting-started/manifests/05-ratelimitpolicy.yaml) |

### Camada 3 — Identidade (2 recursos, um par)

| Recurso | O que faz | Arquivo |
|---------|-----------|---------|
| **Secret** (com labels específicos) | A **chave real** que o Authorino usa pra autenticar em runtime. Labels `app=banking-lite-apikey` amarram este Secret à AuthPolicy do passo 4. Annotations `user-id` e `plan-id` viram metadata do consumer. | [`06-apikey-secret.yaml`](getting-started/manifests/06-apikey-secret.yaml) |
| **APIKey CR** | O objeto de **governança** que aparece no dev portal. NÃO autentica — só documenta "usuário X pediu acesso ao produto Y". O runtime de auth ignora este CR. | [`07-apikey-cr.yaml`](getting-started/manifests/07-apikey-cr.yaml) |

**Diferença crucial entre Secret e APIKey CR:**

- `Secret` = *chave que autentica*. Deletar o Secret quebra o request na hora.
- `APIKey CR` = *linha na tabela do portal*. Deletar o CR só some do portal — auth continua funcionando enquanto o Secret existir.

Em produção, o dev portal **cria os dois juntos** (Secret + CR) na hora que
o usuário clica "subscribe". Neste getting-started criamos manualmente pra
ver as peças separadas.

---

## Passo a passo

### 1. Escolher a hostname

O gateway RHCL do lab tem listener wildcard, então qualquer subdomínio
da zona já registrada resolve. Descubra a zona derivando do
banking-api existente:

```bash
BASE=$(oc get httproutes.gateway.networking.k8s.io banking-api-connectivity \
  -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}' | cut -d. -f2-)
export HOSTNAME="banking-lite.${BASE}"
echo "Vamos usar: $HOSTNAME"
```

Se o output for `banking-lite.apps.example.com` (ou similar),
tá certo — é uma hostname nova que cai no wildcard do gateway.

### 2. Aplicar os 7 manifests

```bash
cd tests/getting-started
HOSTNAME="$HOSTNAME" ./scripts/apply.sh
```

O script:
1. Aplica HTTPRoute (substitui `${HOSTNAME}` pelo valor real via `sed`)
2. Aplica APIProduct
3. Aplica PlanPolicy
4. Aplica AuthPolicy
5. Aplica RateLimitPolicy
6. Aplica Secret (chave real)
7. Aplica APIKey CR (o objeto do portal)
8. Espera 5 s pro Authorino sincronizar
9. Imprime a chave que você vai usar pra testar

### 3. Sanity check via curl

```bash
KEY=$(oc -n rhcl-apps get secret banking-lite-onboarding-key \
  -o jsonpath='{.data.api_key}' | base64 -d)

# Sem chave → 401
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  "https://${HOSTNAME}/api/v1/accounts/summary"
# esperado: HTTP 401

# Com chave → 200 + JSON
curl -sk -H "api-key: ${KEY}" \
  "https://${HOSTNAME}/api/v1/accounts/summary" | jq '.[0:2]'
# esperado: array com contas de banco
```

Se der 401 mesmo com chave, o Authorino não sincronizou ainda —
aguarda mais uns 10 s.

### 4. Validar tudo automaticamente

```bash
HOSTNAME="$HOSTNAME" ./scripts/validate.sh
```

8 checks: HTTPRoute Accepted, APIProduct existe, 3 policies Enforced,
curl sem key → 401, curl inválido → 401, curl válido → 200, rate limit
dispara depois de 60 requests, dev portal enxerga.

---

## Testar com o mobile-bank

O mobile-bank tem uma UI de settings onde você troca a URL do RHCL
Gateway e a API key — em runtime, sem redeploy.

### 5. Configurar mobile-bank pra usar banking-lite

1. Abre o mobile-bank no browser (a URL costuma ser
   `https://mobile-bank.<zona>` ou `https://mobile-bank-rhcl-apps.<apps-domain>`)
2. Clica no ícone de **engrenagem** (canto superior direito)
3. Muda **Endpoint profile** pra **RHCL Gateway**
4. Preenche:
   - **RHCL Gateway URL**: `https://<HOSTNAME>` (o mesmo do passo 1)
   - **RHCL API Key**: cola o valor de `$KEY` (do passo 3)
5. **Save**

Volta pra home. Fluxo esperado:
- Lista de bancos aparece normal
- Fazer uma transferência funciona
- Aba "Comprovantes" (streaming) funciona
- Nas tabs POC Console → Métricas: a URL bate `https://<HOSTNAME>/...`

Se a lista de bancos ficar vazia ou aparecer erro CORS, checa:
- Chave certa? (`echo $KEY | pbcopy` pra ter certeza)
- URL sem barra no final? (mobile-bank concatena `/api/...`)
- CORS: o passo 4 da AuthPolicy já libera `OPTIONS` como anônimo,
  então preflight passa; se ainda quebrar, checa o Network tab do browser.

---

## Onboarding via Dev Portal

Até agora criamos a chave manualmente. Em produção o usuário se
cadastra **sozinho** pelo dev portal e pega a chave dele. Vamos
demonstrar:

### 6. Login no dev portal como novo usuário

1. Abre o dev portal: `https://portal.<zona>` (ou a Route
   `portal-frontend`)
2. Faz login com um usuário do Keycloak (crie um novo se preferir —
   `setup-keycloak.sh --consumer-users=beto` (no repo do portal,
   hodrigohamalho/rhcl-developer-portal) cria o `beto` com role `api-consumer`)
3. Menu → **APIProducts** — você deve ver **Banking Lite** listado
   (com o `displayName` que colocamos no manifest 02)

Se não aparecer, o portal-backend pode ainda estar em cache —
espera ~30 s e refresh.

### 7. Subscribe + gerar chave

1. Clica em **Banking Lite** → aba **Details**
2. Botão **Subscribe** → escolhe o plano **`demo`**
3. Confirma → portal cria automaticamente:
   - Um **Secret** novo (com valor gerado aleatoriamente)
   - Um **APIKey CR** ligando o usuário logado a este produto
   - `approvalMode: auto` na APIProduct → chave já vem aprovada
4. Botão **Copy key** → chave nova (formato aleatório, tipo `bk_live_abc123...`)

### 8. Ver o consumer aparecer no plugin do Console

1. OpenShift Console → menu **Custom Connectivity Link → APIs**
2. Clica em **Banking Lite**
3. Aba **Consumers**: deve mostrar o `beto` (ou o user que logou no
   portal) com a chave dele
4. Se você gerar tráfego com essa chave nova, o card **Top consumers**
   deve rankear ele

### 9. Ver métricas por consumer no Grafana

1. Grafana → dashboard **RHCL API Metrics**
2. Filtra por `route_name = rhcl-apps.banking-lite.0` (nome
   determinístico do Istio)
3. Painel **Requests by consumer** deve separar `onboarding-user` (do
   getting-started) e `beto` (do portal)

---

## Cleanup

```bash
./scripts/cleanup.sh
```

Remove os 7 recursos criados pelo apply. **Não toca** no banking-api-v1
nem no gateway.

Depois disso:
- `banking-lite.<zona>` para de resolver (HTTPRoute foi removida do gateway)
- Chave onboarding-user vira lixo (Secret deletado)
- O portal deixa de mostrar Banking Lite
- Consumer que o portal criou no passo 7 também some se você deletar o
  Secret + APIKey CR dele (o portal tem uma tela pra isso, ou
  `oc delete secret <name>` direto)

---

## O que você aprendeu

Fazendo esse fluxo, você tocou nos **6 tipos de recurso** que declaram
o comportamento de qualquer API no RHCL:

1. **HTTPRoute** — roteamento
2. **APIProduct** — catálogo + governança
3. **PlanPolicy** — planos comerciais + rate limit por consumer
4. **AuthPolicy** — autenticação
5. **RateLimitPolicy** — proteção agregada
6. **Secret + APIKey CR** — identidade

Qualquer API futura no PoC vai ser variação disso: outra hostname,
outros paths, outros tiers, outros consumers. A estrutura é a mesma.

---

## Onde ir depois

- [`req018.md`](req018.md) — **Monitoração de custo** por consumer
  (Prometheus + tabela de preços em ConfigMap).
- [`req026.md`](req026.md) — **Streaming de arquivos** (cap em Envoy
  Lua chunk-a-chunk, sem buferizar).
- [`req030.md`](req030.md) — Interceptação e inspeção de request
  (ext_authz + mirror).
- [`req051.md`](req051.md) e [`req056.md`](req056.md) — casos
  avançados de policy composition.
- [`../automation/`](../automation/) — Ansible que faz TUDO isso pra
  o setup completo do PoC (não só banking-lite).

---

## Troubleshooting

### "HTTPRoute NOT Accepted" no validate

Provável: o listener do gateway não aceita rotas do namespace
`rhcl-apps`. Checa:

```bash
oc get gateway -n openshift-ingress rhcl-apps-gateway \
  -o jsonpath='{.spec.listeners[*].allowedRoutes}' | jq
```

Deve ter `namespaces.from: All` ou um selector que bata em `rhcl-apps`.

### "AuthPolicy NOT Enforced"

Provável: o Kuadrant ainda não sincronizou. Espera 30 s e roda
`validate.sh` de novo. Se persistir:

```bash
oc -n kuadrant-system logs -l app=kuadrant --tail=100 | grep banking-lite
```

### 401 mesmo com chave correta

Duas causas comuns:
- Authorino não descobriu o Secret. O selector espera as duas labels:
  `authorino.kuadrant.io/managed-by=authorino` + `app=banking-lite-apikey`.
  Cheque com `oc -n rhcl-apps get secret banking-lite-onboarding-key --show-labels`.
- Chave copiada com espaço no final. `KEY=$(... | tr -d '\n')` resolve.

### Rate limit não dispara

O Limitador (do Kuadrant) precisa estar rodando + a PlanPolicy
Enforced. Cheque:

```bash
oc -n kuadrant-system get pods -l app=limitador
oc -n rhcl-apps get planpolicy banking-lite-plans -o yaml | grep -A2 conditions
```

Se `Enforced: True`, o problema é ritmo — o script dispara 65 requests
serial (rápido), mas se o gateway tiver latência alta, pode não
ultrapassar 60 no minuto. Rode 100 em vez de 65.

### Dev portal não mostra Banking Lite

O portal-backend faz cache de 30-60 s. Depois disso:

```bash
oc -n rhcl-devportal delete pod -l app=portal-backend
```

Rebuild rápido do cache.

---

## Referências

- **Manifests deste guide:** [`getting-started/manifests/`](getting-started/manifests/)
- **Scripts:** [`getting-started/scripts/`](getting-started/scripts/)
- **APIProduct CRD:** [`devportal.kuadrant.io/v1alpha1`](../automation/roles/apps/templates/connectivity-apiproduct.yml.j2)
- **AuthPolicy CRD:** [`kuadrant.io/v1`](../automation/roles/apps/templates/connectivity-authpolicy-apikey.yml.j2)
- **PlanPolicy CRD:** [`extensions.kuadrant.io/v1alpha1`](../automation/roles/apps/templates/connectivity-planpolicy.yml.j2)
- **Templates Ansible completos** (com todos os knobs comerciais + JWT
  + WebSocket + auth por query param): [`automation/roles/apps/templates/`](../automation/roles/apps/templates/)
