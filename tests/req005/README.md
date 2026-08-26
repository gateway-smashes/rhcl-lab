# REQ 05 — Balanceamento de carga por peso (PoC)

Página HTML estática que demonstra o componente nativo de balanceamento de
carga por peso da Gateway API
(`HTTPRoute.spec.rules[].backendRefs[].weight`). O alvo são os dois
backends que o playbook do lab já entrega lado a lado:

- `banking-api-v1` em `rhcl-apps`
- `banking-api-v2` em `rhcl-apps`

Os dois Deployments rodam **a mesma imagem** do Quarkus
(`apps_backend_image_name:latest`); o que diferencia um do outro é o env
`APP_INSTANCE_NAME`, exposto pelo backend no campo `instance` de toda
resposta. Esse campo é a fonte da verdade sobre qual Service o gateway
escolheu em cada chamada.

Veja `../req005.md` para o contexto do requisito.

## Arquivos

- [index.html](index.html) — console PoC em arquivo único, com gerador de
  burst no navegador, tabulação por `instance` (e eco de
  `x-route-version`) e blocos `oc`/`curl`/`yq` prontos para copiar.
- [manifests/httproute-weighted.yaml](manifests/httproute-weighted.yaml)
  — a `HTTPRoute` em si: hostname dedicado
  (`weighted.${RHCL_ZONE_ROOT_DOMAIN}`), uma rule `Exact` em
  `/api/whoami` com dois `backendRefs` ponderados (90/10 por default) e
  um filtro `RequestHeaderModifier` por backend que injeta
  `x-route-version: v1|v2` antes do envio. Inclui ainda dois atalhos
  sem peso (`/api/v1`, `/api/v2`) para sanity check.

## Por que `/api/whoami` como path neutro

`/api/whoami` existe nos dois pods (mesma imagem), é leve, retorna o
campo `instance` (= valor de `APP_INSTANCE_NAME` no Deployment, ou seja,
`banking-api-v1` ou `banking-api-v2`) e ecoa todos os headers da
requisição em `allHeaders`. Isso dá dois sinais ortogonais sobre qual
backend foi escolhido pelo gateway:

| Sinal | Origem | Para que serve |
| --- | --- | --- |
| `data.instance` | Backend (env do Deployment) | Confirma qual pod respondeu, do ponto de vista do código que rodou. |
| `data.allHeaders["x-route-version"]` | Gateway (filtro `RequestHeaderModifier`) | Confirma a decisão do gateway, sem depender do backend. |

Se os dois sinais discordarem, há roteamento errado entre Service e Pod
— então a tabela "Distribuição por `instance`" mostra os dois lado a
lado.

## Por que NÃO usar `URLRewrite` por backendRef

A primeira versão deste demo tentou um path "100% neutro"
(`/api/accounts/summary`) com um filtro `URLRewrite` por `backendRef`,
reescrevendo para `/api/v1/accounts/summary` ou
`/api/v2/accounts/summary` antes do envio ao backend. Isso falha no
controller do OpenShift Gateway API:

```text
status:
  parents:
    - controllerName: openshift.io/gateway-controller/v1
      conditions:
        - type: ResolvedRefs
          status: 'False'
          reason: InvalidFilter
          message: unsupported filter type "URLRewrite"
```

O controller (Istio) declara `URLRewrite` apenas em
`HTTPRouteRule.filters`, **não** em `HTTPBackendRef.filters`.
`RequestHeaderModifier`, em contraste, é "core" em ambos os pontos da
spec — daí a escolha pela injeção de header.

## Pré-requisitos

1. **Gateway API + RHCL/Kuadrant ativos** — o lab já provisiona o
   gateway wildcard `rhcl-apps-gateway` em `openshift-ingress`. O
   hostname `weighted.${RHCL_ZONE_ROOT_DOMAIN}` é casado pela listener
   wildcard `*.${RHCL_ZONE_ROOT_DOMAIN}`.
2. Deployments `banking-api-v1` e `banking-api-v2` já criados pelo
   playbook em `automation/roles/apps` (namespace `rhcl-apps`), ambos
   prontos (`oc -n rhcl-apps get deploy`).
3. `oc` autenticado com permissão para criar `HTTPRoute` em
   `rhcl-apps`.
4. `envsubst` disponível (vem em `gettext` na maioria das distros).

## Aplicar no cluster

```bash
export RHCL_ZONE_ROOT_DOMAIN=apps.cluster1.poc.rhcl.com.br   # ajuste para seu lab

envsubst < tests/req005/manifests/httproute-weighted.yaml | oc apply -f -

# Verificações iniciais — Accepted=True E ResolvedRefs=True
oc -n rhcl-apps get httproute banking-api-weighted \
  -o jsonpath='{.status.parents[0].conditions}' | jq

# Pesos efetivamente aceitos
oc -n rhcl-apps get httproute banking-api-weighted -o yaml \
  | yq '.spec.rules[0].backendRefs[] | {name: .name, weight: .weight, filters: .filters}'
```

`Accepted=True` indica que o gateway anexou a rota ao parent.
`ResolvedRefs=True` indica que os `backendRefs` e os filtros foram
todos aceitos pelo controller — em particular, sem o erro
`unsupported filter type "URLRewrite"` que esta versão do manifesto
contorna.

## Ajustar pesos sem recriar

```bash
# 50 / 50
oc -n rhcl-apps patch httproute banking-api-weighted --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}
]'

# 0 / 100 (promoção total para v2)
oc -n rhcl-apps patch httproute banking-api-weighted --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":0},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":100}
]'
```

O gateway recalcula o split em tempo real — o próximo burst contra
`/api/whoami` já reflete a nova proporção sem reiniciar pods.

## Como rodar a página

A página apenas dispara `fetch()` contra o backend, então qualquer porta
local funciona:

```bash
# da raiz do repo
python3 -m http.server 8080 --directory tests/req005
# abra http://localhost:8080
```

Quando publicada via container de testes (`tests/Dockerfile`), o
`env.json` expõe `RHCL_ZONE_ROOT_DOMAIN` e a página pré-popula a Base
URL com `https://weighted.<domínio>`.

## Como usar a página

1. **Configure os pesos esperados** (por default 90/10) — esses valores
   só servem para que o veredito compare a observação com o esperado.
   Eles **não** alteram o cluster: para mudar de fato a proporção,
   aplique o `oc patch` (ou edite o YAML e reaplique).
2. **Defina N e concorrência.** O default (`N=100`, `conc=8`) leva
   ~poucos segundos e já expõe um sinal estatístico decente. Para
   evidência forte do canary 90/10, use `N≥200`.
3. **Clique em "Disparar amostra".** A página chama
   `GET /api/whoami` `N` vezes através do gateway, tabula
   `instance` (e o eco de `x-route-version`) de cada resposta e
   atualiza:
   - **Distribuição observada** — barra empilhada v1/v2 (e "outro/erro"
     em vermelho se algum hit falhar).
   - **Veredito** — compara observado × esperado com tolerância
     `±max(5, 30/√N) pp` (mais frouxa em amostras pequenas).
   - **Resultado da amostra** — tabela com esperado %, observado %,
     hits e desvio em pontos percentuais.
   - **Distribuição por `instance`** — uma linha por valor de
     `instance` retornado, com o eco de `x-route-version` ao lado para
     conferência.
4. **Atalhos `/api/v1` e `/api/v2`** — antes de tirar conclusões, use
   os dois botões de sanity check para confirmar que ambos os Services
   estão respondendo. Esses dois paths não passam por weighting: vão
   direto a um único backend.
5. **YAML inline** — a seção *HTTPRoute com pesos por backendRef*
   atualiza o YAML em tempo real conforme você muda os pesos esperados.
   Copie e aplique com `oc apply`.
6. **Comandos shell** — os blocos *curl burst*, *eco do header*,
   *oc apply*, *oc patch* e *oc logs* são equivalentes em terminal aos
   widgets da página.

## O que conta como sucesso

Com `N=100` e pesos `v1=90, v2=10`, uma amostra típica fica em algo
como:

```text
v1   88  88.0%   esperado 90.0%   desvio  −2.0 pp
v2   12  12.0%   esperado 10.0%   desvio  +2.0 pp
```

Veredito: **coerente com pesos** (a tolerância em N=100 é
`max(5, 30/√100) = 5 pp`).

Aumentando N para 500 e mantendo o mesmo split, espera-se `v1` cair
para a faixa de 87–93% e `v2` subir para 7–13%. Trocando para 50/50, o
mesmo experimento converge para ~50% em cada lado em poucos segundos.

Por shell, o equivalente é:

```bash
N=200
URL="https://weighted.${RHCL_ZONE_ROOT_DOMAIN}/api/whoami"
for i in $(seq 1 $N); do
  curl -s "$URL" | jq -r '.instance'
done | sort | uniq -c | awk '{printf "%-4s %s (%s%%)\n", $1, $2, ($1*100)/'"$N"'}'
```

Saída esperada:

```text
180  banking-api-v1 (90%)
 20  banking-api-v2 (10%)
```

E para confirmar pelo lado do gateway (eco do header injetado pelo
`RequestHeaderModifier`):

```bash
for i in $(seq 1 $N); do
  curl -s "$URL" | jq -r '.allHeaders["x-route-version"][0] // "-"'
done | sort | uniq -c
```

## Limpeza

```bash
oc -n rhcl-apps delete httproute banking-api-weighted
```

Remove apenas a rota com peso. Os Services e Deployments
`banking-api-v1` / `banking-api-v2` continuam disponíveis pelas demais
HTTPRoutes do lab.

## Notas

- **Soma dos pesos não precisa ser 100.** A Gateway API normaliza em
  tempo de avaliação — `weight: 9` + `weight: 1` é equivalente a
  `90` + `10`. Manter em base 100 só facilita ler o canary.
- **Peso `0` zera o backend.** É a forma idiomática de tirar a v1 (ou
  v2) do circuito sem deletá-la do recurso, útil para "drenagem" antes
  de uma promoção definitiva.
- **Por que não usar `mirroring` em vez de pesos?** O filtro
  `RequestMirror` é fire-and-forget e a resposta espelhada é descartada
  — não serve para canary. `weight` é a primitiva certa para dividir
  *tráfego real* entre versões.
- **`instance` reflete o Deployment, não o pod.** Como
  `APP_INSTANCE_NAME` é fixo no manifesto do Deployment, várias
  réplicas do mesmo Deployment retornam o mesmo `instance`. Isso é
  bom para esta PoC (basta v1 vs v2), mas significa que esta página
  não distingue réplicas — para isso, ajuste o env do Deployment para
  `valueFrom.fieldRef: metadata.name` ou mude o backend para reportar
  o hostname.
