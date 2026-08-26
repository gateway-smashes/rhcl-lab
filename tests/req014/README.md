# REQ 14 — CORS no Gateway (PoC)

Página HTML estática que demonstra o problema de CORS quando o navegador
chama o backend a partir de outra origem e como rotear a mesma chamada por
um host dedicado do gateway resolve, via filtro `ResponseHeaderModifier`
da `HTTPRoute`.

Veja `../req014.md` para o contexto completo do requisito.

## Arquivos

- [index.html](index.html) — console PoC em arquivo único (sem build).
- [manifests/httproute-cors.yaml](manifests/httproute-cors.yaml) — `HTTPRoute`
  pronta, anexada ao gateway wildcard do lab, expondo
  `cors.${RHCL_ZONE_ROOT_DOMAIN}` com cabeçalhos
  `Access-Control-Allow-*` injetados pelo gateway.

## Endpoint dedicado `/api/v1/cors`

Adicionado no `banking-api` em
[BankingResource.java](../../apps/backend/banking-api/src/main/java/io/gatewaysmashes/rhcl/api/BankingResource.java):

- `GET /api/v1/cors` — retorna JSON com `instance`, `backendTag`,
  `message`, `origin` (eco do header `Origin` recebido), `referer`,
  `timestamp`. **Não emite** nenhum `Access-Control-Allow-*`.
- O log do pod registra `cors demo version=v1 instance=... origin=... referer=...`
  para evidenciar a origem que o backend recebeu.

A ausência de cabeçalhos CORS é o ponto da demo: chamadas vindas de outra
origem só funcionam quando o gateway injeta esses headers.

## Variável de ambiente `RHCL_ZONE_ROOT_DOMAIN`

A imagem de testes (`tests/Dockerfile`) gera `/env.json` no boot a partir
das variáveis do pod (whitelist em `tests/catalog/generate-env.sh`). Se
`RHCL_ZONE_ROOT_DOMAIN` estiver definida no Deployment, a página
pré-popula o preset "Via gateway" e o YAML mostrado com a hostname final
`cors.<domínio>`.

## Aplicar a HTTPRoute no cluster

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.cluster1.poc.rhcl.com.br   # ajuste

envsubst < tests/req014/manifests/httproute-cors.yaml | oc apply -f -

oc -n rhcl-apps get httproute banking-api-cors
```

A rota fica anexada ao Gateway wildcard `*.${RHCL_ZONE_ROOT_DOMAIN}` criado
pelo playbook (`rhcl-apps-gateway` em `openshift-ingress`). A única regra
casa `/api/v1/cors` (Exact) e injeta:

| Cabeçalho | Valor |
| --- | --- |
| `Access-Control-Allow-Origin` | `*` |
| `Access-Control-Allow-Methods` | `GET, POST, OPTIONS` |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type, Accept, X-Requested-With` |
| `Access-Control-Expose-Headers` | `x-instance, x-flow-trace-id` |
| `Access-Control-Max-Age` | `600` |
| `Vary` | `Origin` |

Para remover:

```bash
oc -n rhcl-apps delete httproute banking-api-cors
```

## Como rodar a página

A página precisa ser servida em uma **origem diferente** do backend para
disparar o CORS — abrir `index.html` direto via `file://` não reproduz o
mesmo cenário.

```bash
# da raiz do repo
python3 -m http.server 8080 --directory tests/req014
# abra http://localhost:8080
```

> Qualquer porta serve. O navegador só se importa que
> `http://localhost:8080` seja uma origem diferente do backend.

## Como usar a página

1. **Abra o DevTools antes** (F12 → Console + Network). A mensagem
   detalhada de erro de CORS é impressa pelo navegador, não pelo JS — o
   `fetch()` só vê um `TypeError: Failed to fetch` genérico.
2. Use os presets para escolher a Base URL e o path:
   - **Backend direto** (`https://banking-api-v1-rhcl-apps...`) — sem CORS,
     fetch deve falhar.
   - **Via gateway** (`https://cors.${RHCL_ZONE_ROOT_DOMAIN}`) — com CORS,
     fetch deve passar.
   - Path padrão: `/api/v1/cors`.
3. Clique em **Disparar GET**.
   - O cartão *Última requisição* mostra a duração, o status HTTP e a
     contagem de cabeçalhos CORS na resposta.
   - O cartão *Veredito* classifica o resultado.
4. **OPTIONS preflight** envia um `OPTIONS` manual para inspecionar o que
   o servidor retorna para um preflight (não é um preflight "real" — quem
   dispara isso de verdade é o navegador).
5. Os blocos **curl** reproduzem o teste no terminal. Lembre que `curl`
   ignora CORS (sempre retorna o corpo); o que muda é a presença ou
   ausência dos cabeçalhos `Access-Control-Allow-*` na resposta.

## O que conta como "sucesso"

**Backend direto:**
- *Disparar GET* registra `TypeError: Failed to fetch`.
- DevTools Console mostra algo como:
  `Access to fetch at 'http://...' from origin 'http://localhost:8080' has
  been blocked by CORS policy: No 'Access-Control-Allow-Origin' header is
  present on the requested resource.`
- *OPTIONS preflight* não traz nenhum `Access-Control-*` na resposta.

**Via `cors.${RHCL_ZONE_ROOT_DOMAIN}`:**
- *Disparar GET* retorna `200 OK` e o corpo JSON aparece no log.
- *OPTIONS preflight* mostra os cabeçalhos injetados pelo gateway:
  ```
  Access-Control-Allow-Origin: *
  Access-Control-Allow-Methods: GET, POST, OPTIONS
  Access-Control-Allow-Headers: Authorization, Content-Type, Accept, X-Requested-With
  ```

## Nota sobre mixed content

Se a página for servida em `https://` (ex.: GitHub Pages) e o backend
estiver em `http://`, o navegador também bloqueia por **mixed content**
antes mesmo do CORS. Para este PoC, servir em `http://localhost` deixa
o erro claramente atribuível ao CORS.
