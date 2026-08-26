# REQ 13 — Timeout por endpoint/recurso (PoC)

Página HTML estática que demonstra como o RHCL / Gateway API impõe um
timeout de requisição por rota — independentemente do tempo que o backend
leva para responder. Usa o endpoint
`/api/test/echo-error?status=N&delay=N` do `banking-api` para forçar respostas
lentas e observar quando o gateway corta a chamada com `504 Gateway Timeout`.

Veja também `../README.md` (seção **Req 13 — Per-route timeouts**) para o
contexto completo do requisito.

## Arquivos

- [index.html](index.html) — console PoC em arquivo único (sem build).
- [manifests/httproute-timeout.yaml](manifests/httproute-timeout.yaml) —
  HTTPRoute pronto para aplicar, anexado ao gateway wildcard do lab,
  expondo `timeout.${RHCL_ZONE_ROOT_DOMAIN}` com timeouts diferentes por rota.

## Variável de ambiente `RHCL_ZONE_ROOT_DOMAIN`

A imagem de testes (`tests/Dockerfile`) gera, no boot, um `env.json` no
docroot do nginx a partir das variáveis de ambiente do pod. Hoje a lista
inclui apenas `RHCL_ZONE_ROOT_DOMAIN` (mapeado para `rhclZoneRootDomain`).

No deployment do app raiz `tests`, defina:

```yaml
env:
  - name: RHCL_ZONE_ROOT_DOMAIN
    value: apps.cluster1.poc.rhcl.com.br   # ajuste para seu lab
```

Quando a página `req013/index.html` carrega, ela faz `fetch('/env.json')`,
e — se `rhclZoneRootDomain` estiver preenchido — pré-popula:

- a **Base URL** com `https://timeout.<domínio>`;
- o **YAML** da `HTTPRoute` (substitui `${RHCL_ZONE_ROOT_DOMAIN}` pela hostname
  efetiva, então o YAML mostrado já fica pronto para `oc apply -f`).

Rodando localmente com `python3 -m http.server`, o `env.json` simplesmente
não existe e a página continua usando os valores padrão hardcoded.

## Aplicar a HTTPRoute no cluster

O manifesto usa `${RHCL_ZONE_ROOT_DOMAIN}` como placeholder. Exporte a
variável para o domínio do seu lab e aplique via `envsubst`:

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.cluster1.poc.rhcl.com.br   # ajuste

envsubst < tests/req013/manifests/httproute-timeout.yaml | oc apply -f -

oc -n rhcl-apps get httproute banking-api-timeout
```

A rota fica anexada ao Gateway wildcard `*.${RHCL_ZONE_ROOT_DOMAIN}` criado
pelo playbook (`rhcl-apps-gateway` em `openshift-ingress`) e expõe três
regras que apontam para o **mesmo** endpoint do backend
(`/api/v1/timeout`, que dorme 3 s):

| Path externo                   | `timeouts.request` | Filtro              | Resultado esperado          |
| ------------------------------ | ------------------ | ------------------- | --------------------------- |
| `/api/v1/timeout`              | `2s`               | —                   | **504** (gateway corta)     |
| `/api/v1/timeoutmaior`         | `30s`              | `URLRewrite` → `/api/v1/timeout` | **200** após ~3 s |
| `/api/v1` (PathPrefix)         | `30s`              | —                   | **200** para o resto da v1  |

A regra `/api/v1/timeoutmaior` usa `URLRewrite` (filtro nativo do Gateway
API) para reescrever o path antes de encaminhar ao backend. Isso prova,
contra o **mesmo recurso de upstream**, que o `timeouts.request` é amarrado
à rota e não ao endpoint do backend.

Para remover:

```bash
oc -n rhcl-apps delete httproute banking-api-timeout
```

## Como rodar

```bash
# a partir da raiz do repositório
python3 -m http.server 8080 --directory tests/req013
# abra http://localhost:8080
```

> Qualquer porta serve. Como esta página apenas dispara `fetch()` para a URL
> configurada, basta que o navegador consiga acessar o backend / gateway
> escolhido (cuidado com mixed-content se você expor a página em HTTPS e
> apontar para um backend HTTP).

## Como usar a página

1. Preencha **Base URL** com o endereço do backend (testes "diretos") ou do
   gateway com timeout aplicado (`https://timeout.<domínio>`).
2. Use **Path da rota** ou os presets para escolher qual rota chamar:
   - `/api/v1/timeout` (timeout 2 s — espera 504)
   - `/api/v1/timeoutmaior` (timeout 30 s — espera 200 após 3 s)
3. Informe o **timeout esperado da rota (ms)** — só serve para a página
   classificar o resultado como coerente. Os presets já preenchem este
   valor automaticamente.
4. Clique em **Disparar requisição**.
   - O cartão *Última requisição* mostra a URL chamada, duração medida e
     o HTTP status.
   - O cartão *Veredito* compara duração × timeout × delay (3 s fixo do
     backend) para indicar se o comportamento condiz com o esperado.
5. Para a demo simples, use a seção **/api/v1/timeout** — dois botões que
   chamam diretamente cada uma das duas rotas e exibem o JSON retornado
   (ou o 504) com a mensagem em destaque.
6. Use os blocos **curl** para reproduzir o teste no terminal e o bloco
   **oc logs** para conferir, no log do pod, que o backend continuou
   processando mesmo após o gateway ter respondido 504.

## Endpoint dedicado `/api/v1/timeout`

Adicionado no `banking-api` em [BankingResource.java](../../apps/backend/banking-api/src/main/java/io/gatewaysmashes/rhcl/api/BankingResource.java)
exclusivamente para esta demo:

- `GET /api/v1/timeout` → o backend dorme **3 s fixos** e responde com:
  ```json
  {
    "apiVersion": "v1",
    "instance": "...",
    "backendTag": "v1@...",
    "requestedDelayMs": 3000,
    "elapsedMs": 3001,
    "message": "Resposta do backend após 3001 ms (delay configurado: 3000 ms)",
    "timestamp": "2026-..."
  }
  ```
- O log do pod registra `timeout demo start` ao receber a chamada e
  `timeout demo end` ao terminar — útil para comprovar que o backend
  continuou processando mesmo quando o gateway já cortou com 504.

## URLs usadas neste PoC

| Preset | URL base | Comportamento esperado |
| --- | --- | --- |
| Backend direto (cluster1.poc) | `https://banking-api-v1-rhcl-apps.apps.cluster1.poc.rhcl.com.br` | Sempre responde após o `delay` solicitado (não há timeout no caminho). |
| Backend direto (mycluster) | `https://banking-api-v1-rhcl-apps.apps.mycluster.sandbox3066.opentlc.com` | Idem — sem timeout aplicado. |
| Via RHCL Gateway | configurado em runtime, persistido em `localStorage` | Retorna 504 quando `delay > timeout` da rota. |

A URL do gateway é informada no campo **URL base do gateway** + botão
**Salvar** (mantida em `localStorage` para sobreviver a recargas).

## O que conta como "sucesso"

**Backend direto:**
- 200 OK em ≈ `delay` ms, mesmo com `delay = 6000` ou `15000`.
- O log do pod registra a linha `test echo-error ... delayMs=...` com o
  delay completo.

**Via gateway com `timeouts.request: 2s`:**
- `delay ≤ 2000` → 200 OK em ≈ `delay` ms.
- `delay > 2000` → **504 Gateway Timeout** em ≈ 2000 ms.
- O log do pod ainda mostra a linha do backend processando — prova de que o
  corte foi do gateway.

## Configurando o timeout na `HTTPRoute`

A página inclui um YAML de exemplo com timeouts diferentes por rota
(`/api/v1/accounts/summary` 1s, `/api/test/echo-error` 2s, `/api/files` 30s).
Aplique no cluster e ajuste `parentRefs.name` / `backendRefs.name` /
`hostnames` conforme o lab. Em seguida, repita os testes apontando a página
para a URL do gateway para ver o 504 disparar conforme a regra.
