# REQ 31 — Permitir criar e configurar completamente um produto de API via API administrativa

Demonstra que **a API do Kubernetes É a "API administrativa"** que o requisito pede:
qualquer cliente HTTP/SDK pode criar e configurar um produto de API ponta-a-ponta —
sem console, sem GitOps, sem Ansible — apenas chamando o API server com credenciais.

Esta demo cria um **produto novo `pix-api`** path-based no mesmo gateway, reusando o
backend `banking-api-v1` (o produto é controle puro: políticas + APIProduct + APIKey,
sem deploy novo).

## Modelo: o que compõe um "produto de API"

Em RHCL/Kuadrant, um produto é a composição destes CRs — todos manipuláveis via
`/apis/...` do API server:

| CR | Grupo / Versão | Papel |
|---|---|---|
| `HTTPRoute` | `gateway.networking.k8s.io/v1` | Roteamento, matches, filtros (URLRewrite, headers) |
| `APIProduct` | `devportal.kuadrant.io/v1alpha1` | Metadados do produto (displayName, version, publishStatus) |
| `PlanPolicy` | `extensions.kuadrant.io/v1alpha1` | Tiers + rate limit por plano (predicate CEL) |
| `AuthPolicy` | `kuadrant.io/v1` | Autenticação (api-key, jwt, anonymous) + headers de resposta |
| `Secret` (api-key) | `v1` (core) | Valor da chave, identidade da consumer |
| `APIKey` | `devportal.kuadrant.io/v1alpha1` | Request/approval de chave (governança) |
| `Role` + `RoleBinding` | `rbac.authorization.k8s.io/v1` | Permissões pra quem opera via API |

## Pré-requisitos

- Cluster com RHCL/Kuadrant instalado.
- Banking-api já deployado em `rhcl-apps` (a demo reusa o `banking-api-v1`).
- HTTPRoute `banking-api-connectivity` existindo (o script descobre o host a partir
  dele). Caso contrário, exporte `HOST=banking-api-connectivity.<sua-zone>`.
- `oc` autenticado com perm. pra criar RBAC no `rhcl-apps` (cluster-admin típico).
- `python3` (decode de JSON nos scripts) e `envsubst` (substituição de `${HOST}`).

## Arquivos

```
tests/req031/
├── manifests/
│   ├── 00-httproute.yaml      ← HTTPRoute pix-api-connectivity (/pix/v1 → rewrite /api/echo)
│   ├── 01-apiproduct.yaml     ← APIProduct pix-api (Published)
│   ├── 02-planpolicy.yaml     ← pix-gold (unlimited) + pix-bronze (5/min)
│   ├── 03-authpolicy.yaml     ← api-key obrigatório (label app=pix-api-keys)
│   ├── 04-apikey-secret.yaml  ← Secret com api_key=pix-tester-secret (plan=pix-bronze)
│   ├── 05-apikey-cr.yaml      ← APIKey CR (governança no dev portal)
│   └── 06-rbac.yaml           ← SA req031-product-admin + Role/RoleBinding
└── scripts/
    ├── create-via-oc.sh           ← Caminho declarativo (oc apply)
    ├── create-via-k8s-api.sh      ← Caminho REST cru (curl + Bearer token de SA)
    └── cleanup.sh
```

## Como rodar

### Caminho A — declarativo (`oc apply`)

```bash
cd tests/req031
./scripts/create-via-oc.sh
```

O script:
1. Descobre o `HOST` do `banking-api-connectivity` (ou usa `$HOST`).
2. `envsubst` no HTTPRoute + `oc apply` em cada manifest.
3. Aguarda `AuthPolicy.status.Enforced=True` (até 60s).
4. Smoke test: 401 sem key, 200 com key, e burst 7x (bronze=5/min → últimas 2 = 429).

### Caminho B — REST cru contra o API server

```bash
cd tests/req031
./scripts/create-via-k8s-api.sh
```

O script:
1. Aplica `06-rbac.yaml` via `oc` (único passo cluster-admin — cria a SA + permissões).
2. Gera token efêmero (1h) da SA `req031-product-admin`.
3. Cria CADA CR via `curl POST $APISERVER/apis/.../namespaces/rhcl-apps/<recurso>`
   autenticado **só pelo Bearer token** (zero `oc` daí pra frente).
4. Lista APIProducts via REST pra provar.
5. Smoke test 401/200.

> **O ponto do item 31**: o caminho B mostra que **qualquer cliente HTTP** (curl, Postman,
> Python `requests`, Go client-go, etc.) tem o mesmo poder que o `oc`. Não há "console
> admin"; é o K8s API direto, com RBAC granular.

## Validação manual

```bash
HOST=$(oc -n rhcl-apps get httproute banking-api-connectivity -o jsonpath='{.spec.hostnames[0]}')
KEY=$(oc -n rhcl-apps get secret pix-api-key-tester -o jsonpath='{.data.api_key}' | base64 -d)

# Sem auth → 401
curl -sk -o /dev/null -w "%{http_code}\n" "https://$HOST/pix/v1"
# Com auth → 200
curl -sk -o /dev/null -w "%{http_code}\n" -H "api-key: $KEY" "https://$HOST/pix/v1"
# Burst → vê 429 após 5 em 60s (plano bronze)
for i in $(seq 1 7); do curl -sk -o /dev/null -w "%{http_code} " -H "api-key: $KEY" "https://$HOST/pix/v1"; done; echo

# Listar o produto via REST puro com SA token
APISERVER=$(oc whoami --show-server)
TOKEN=$(oc -n rhcl-apps create token req031-product-admin --duration=10m)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/apis/devportal.kuadrant.io/v1alpha1/namespaces/rhcl-apps/apiproducts/pix-api" \
  | python3 -m json.tool | head -30
```

## O que esperar

| Comando | Esperado |
|---|---|
| `oc get apiproduct pix-api -n rhcl-apps` | `spec.publishStatus=Published` |
| `oc get authpolicy pix-api-apikey -n rhcl-apps` | `Accepted=True / Enforced=True` |
| `oc get planpolicy pix-api-plans -n rhcl-apps` | `Accepted=True / Enforced=True` |
| `curl /pix/v1` sem key | **401** |
| `curl /pix/v1` com key bronze | **200** (5x), depois **429** |
| Dev portal / custom console | "pix-api" listado como produto Published |

## Cleanup

```bash
./scripts/cleanup.sh
```

## Caveats

- **Dev portal precisa estar habilitado** pra `APIProduct` reconciliar (no `Kuadrant` CR:
  `spec.components.developerPortal.enabled=true`). Em ambiente sem dev portal, o CR fica
  criado, mas sem reconciliação — auth + rate limit funcionam mesmo assim (vêm de
  `AuthPolicy`/`PlanPolicy` direto).
- **Conflito de policies no mesmo HTTPRoute**: Kuadrant aceita 1 `AuthPolicy` + 1
  `RateLimitPolicy` por route. A `PlanPolicy` **substitui** a `RateLimitPolicy`
  (não use ambos no mesmo route).
- **Path-based**: o produto reusa o host do `banking-api`. Pra um produto em host
  separado, adicionar um listener no `Gateway` (não coberto aqui — fora do escopo
  do item 31).
- **Secret de api-key vs APIKey CR**: a auth real é via `Secret` (selecionado pela
  label da `AuthPolicy`). O `APIKey` CR é um objeto de governança (request/approve)
  que vive em paralelo — ao aprovar, o developer-portal-controller materializa um
  Secret próprio. Esta demo usa Secret de valor fixo pra reprodutibilidade.
