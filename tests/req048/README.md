# REQ 048 — Runbook: Comunicar com o backend das APIs via gRPC

Passo-a-passo completo para demonstrar o item 48 da POC: "Comunicar com o backend das APIs via gRPC".

## O que este item demonstra

O RHCL/Kuadrant (via Istio/Envoy) suporta comunicação **gRPC** com backends através do gateway, utilizando o protocolo HTTP/2 como transporte. O gRPC é roteado por um **HTTPRoute** padrão da Gateway API — a abordagem principal deste item, integrada às políticas Kuadrant. O item inclui ainda um exemplo complementar com **GRPCRoute** `v1` (GA) — ver [Exemplo complementar: GRPCRoute](#exemplo-complementar-grpcroute) e a comparação em [HTTPRoute × GRPCRoute para gRPC](#httproute--grpcroute-para-grpc).

| Modalidade | Transporte | Como funciona |
|------------|-----------|---------------|
| **gRPC nativo (unary)** | HTTP/2 (h2c) | Cliente envia request para `/package.Service/Method`; Envoy conecta ao backend via HTTP/2 |
| **gRPC server-streaming** | HTTP/2 (h2c) | Múltiplas respostas em uma única conexão HTTP/2 |
| **gRPC bidirecional** | HTTP/2 (h2c) | Streams nos dois sentidos (client e server) |
| **gRPC-Web** | HTTP/1.1 ou HTTP/2 | Content-type `application/grpc-web+proto`; compatível com browsers |

### Arquitetura

```
┌──────────────┐       ┌─────────────────────┐       ┌──────────────────────────┐
│  grpcurl /   │       │   Gateway RHCL      │       │  req048-banking-api      │
│  curl        │──────▶│   (Envoy)           │──────▶│  :8080 (gRPC + REST)     │
│  (cliente)   │ HTTPS │   Listener:req048   │ H2C   │  appProtocol: h2c        │
└──────────────┘  H2   └─────────────────────┘       └──────────────────────────┘
                         hostname:                     Namespace: req048-grpc
                         req048-grpc.<domain>
```

### Serviço Protocol Buffers

O backend implementa o serviço `io.gatewaysmashes.rhcl.grpc.BankingService` com os seguintes RPCs:

| RPC | Tipo | Descrição |
|-----|------|-----------|
| `GetSummary` | Unary | Retorna resumo de contas bancárias |
| `StreamHealth` | Server streaming | Envia eventos de health periódicos |
| `EchoStream` | Bidirectional | Echo bidirecional para validar HTTP/2 framing |

---

## Pré-requisitos

| Componente | Verificação |
|---|---|
| OpenShift 4.21 | `oc version` |
| RHCL / Kuadrant instalado | `oc get kuadrant -n kuadrant-system` |
| Gateway configurado | `oc -n openshift-ingress get gateway` |
| ImageStream `banking-api` em `rhcl-apps` | `oc -n rhcl-apps get is banking-api` |
| `grpcurl` na workstation | `grpcurl --version` |
| `curl` e `jq` | `curl --version && jq --version` |

> **Nota:** Se `grpcurl` não estiver disponível, a validação gRPC-Web via `curl` ainda funciona. Para instalar: https://github.com/fullstorydev/grpcurl/releases

---

## Variáveis de ambiente

```bash
# Domínio do cluster (detectado automaticamente pelo script)
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Hostname do serviço gRPC
export HOST="req048-grpc.${CLUSTER_DOMAIN}"
```

---

## Abordagem técnica

O requisito é atendido pela combinação de:

1. **`appProtocol: kubernetes.io/h2c`** no Service — instrui o Envoy/Istio a usar HTTP/2 cleartext para conectar ao backend (obrigatório para gRPC nativo)
2. **HTTPRoute** com `PathPrefix: /` — roteia todo tráfego (incluindo paths gRPC como `/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary`) sem reescrita
3. **Gateway listener** dedicado com hostname `req048-grpc.<domain>` — isola o tráfego gRPC
4. **Backend Quarkus** com `use-separate-server=false` — gRPC e REST compartilham a porta 8080

---

## Arquivos

| Path | Propósito |
| --- | --- |
| [`manifests/00-namespace.yaml`](manifests/00-namespace.yaml) | Namespace `req048-grpc` |
| [`manifests/01-rolebinding-image-pull.yaml`](manifests/01-rolebinding-image-pull.yaml) | Permissão para pull de imagem cross-namespace |
| [`manifests/02-deployment.yaml`](manifests/02-deployment.yaml) | Deployment do banking-api com gRPC |
| [`manifests/03-service-grpc.yaml`](manifests/03-service-grpc.yaml) | Service com `appProtocol: kubernetes.io/h2c` |
| [`manifests/04-httproute.yaml`](manifests/04-httproute.yaml) | HTTPRoute para gRPC |
| [`manifests/05-grpcroute.yaml`](manifests/05-grpcroute.yaml) | GRPCRoute — exemplo complementar (matching por serviço gRPC) |
| [`manifests/06-envoyfilter-grpc-streaming.yaml`](manifests/06-envoyfilter-grpc-streaming.yaml) | Desabilita o buffer de request (req026) nos vhosts do req048 — necessário para reflexão/streaming gRPC |
| [`scripts/apply.sh`](scripts/apply.sh) | Script de deploy completo |
| [`scripts/validate.sh`](scripts/validate.sh) | Validação automatizada |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | Remoção de todos os recursos |
| [`scripts/apply-grpcroute.sh`](scripts/apply-grpcroute.sh) | Deploy do exemplo GRPCRoute (requer `apply.sh` antes) |
| [`scripts/validate-grpcroute.sh`](scripts/validate-grpcroute.sh) | Validação do exemplo GRPCRoute + coexistência |
| [`scripts/cleanup-grpcroute.sh`](scripts/cleanup-grpcroute.sh) | Remove somente o exemplo GRPCRoute |

---

## Deploy (via scripts)

```bash
# Deploy completo (detecta hostname automaticamente)
bash tests/req048/scripts/apply.sh

# Com domínio manual
export CLUSTER_DOMAIN="apps.ocp.xxx.sandboxNNNN.opentlc.com"
bash tests/req048/scripts/apply.sh
```

O script executa na ordem:
1. Cria namespace `req048-grpc`
2. Aplica RoleBinding para image-pull
3. Aplica Deployment e aguarda Ready
4. Aplica Service com `appProtocol: kubernetes.io/h2c`
5. Adiciona listener `req048-grpc` ao gateway
6. Aplica AuthPolicy (allow public) e HTTPRoute
7. Aplica EnvoyFilter que desabilita o buffer de request (instalado pelo req026 no gateway compartilhado) nos vhosts do req048 — sem isso, reflexão gRPC e RPCs de streaming travam no gateway

---

## Validação

### Validação automatizada

```bash
bash tests/req048/scripts/validate.sh
```

### Validação manual — gRPC nativo (unary)

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="req048-grpc.${CLUSTER_DOMAIN}"

# Listar serviços via reflexão
grpcurl -plaintext $HOST:80 list
# Esperado:
#   io.gatewaysmashes.rhcl.grpc.BankingService
#   grpc.health.v1.Health
#   grpc.reflection.v1alpha.ServerReflection

# Unary call — GetSummary
grpcurl -plaintext -d '{"api_version":"v1"}' \
  $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
# Esperado: JSON com campos apiVersion, instance, banks[], grandTotal
```

### Validação manual — gRPC server-streaming

```bash
# StreamHealth — recebe múltiplos eventos
grpcurl -plaintext -d '{"interval_ms":500,"max_events":3}' \
  $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth
# Esperado: 3 eventos com instance, mode, ready, timestamp, sequence crescente
```

### Validação manual — gRPC bidirecional

```bash
# EchoStream — envia mensagens e recebe eco
echo '{"text":"hello-1"}{"text":"hello-2"}{"text":"hello-3"}' | \
  grpcurl -plaintext -d @ \
    $HOST:80 io.gatewaysmashes.rhcl.grpc.BankingService/EchoStream
# Esperado: 3 respostas com text, serverRecvEpochMs, instance, sequence
```

### Validação manual — gRPC-Web via curl

```bash
# gRPC-Web (formato binário para GetSummary com api_version="v1")
printf '\x00\x00\x00\x00\x04\x0a\x02v1' | \
  curl -sS -X POST --data-binary @- \
    -H 'content-type: application/grpc-web+proto' \
    -H 'x-grpc-web: true' \
    "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary" -i
# Esperado: HTTP/1.1 200, headers incluindo grpc-status: 0
```

### Validação manual — appProtocol no Service

```bash
# Confirmar appProtocol configurado
oc -n req048-grpc get svc req048-grpc-backend -o jsonpath='{.spec.ports[0].appProtocol}'
# Esperado: kubernetes.io/h2c
```

### Validação manual — Envoy config (opcional)

```bash
# Verificar que o Envoy reconhece o cluster com HTTP/2
GW_NS="openshift-ingress"
GW_NAME=$(oc -n $GW_NS get gateway -o custom-columns=NAME:.metadata.name --no-headers | head -1)
GW_POD=$(oc -n $GW_NS get pods -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" -o name | head -1)

oc -n $GW_NS exec $GW_POD -c istio-proxy -- \
  pilot-agent request GET /config_dump 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for config in data.get('configs', []):
    for cluster in config.get('dynamic_active_clusters', []):
        name = cluster.get('cluster', {}).get('name', '')
        if 'req048' in name:
            print(f'Cluster: {name}')
            tp = cluster.get('cluster', {}).get('typed_extension_protocol_options', {})
            print(f'Protocol options: {json.dumps(tp, indent=2)}')
"
```

---

## Resumo da demonstração

| # | Evidência | Comando | Resultado esperado |
|---|-----------|---------|-------------------|
| 1 | gRPC unary via gateway | `grpcurl ... GetSummary` | Response com `apiVersion`, `banks`, `grandTotal` |
| 2 | gRPC streaming via gateway | `grpcurl ... StreamHealth` | Múltiplos `HealthEvent` com sequence crescente |
| 3 | gRPC bidirecional | `grpcurl ... EchoStream` | Eco de cada mensagem com `serverRecvEpochMs` |
| 4 | gRPC-Web via curl | `curl -H 'content-type: grpc-web+proto'` | HTTP 200, `grpc-status: 0` |
| 5 | Reflexão gRPC | `grpcurl ... list` | `io.gatewaysmashes.rhcl.grpc.BankingService` na lista |
| 6 | appProtocol h2c | `oc get svc ... -o jsonpath` | `kubernetes.io/h2c` |
| 7 | HTTPRoute aceito | `oc get httproute ... status` | `Accepted: True` |
| 8 | GRPCRoute aceito (exemplo complementar) | `oc -n req048-grpc get grpcroute req048-grpcroute` | `Accepted: True` |
| 9 | gRPC via GRPCRoute (matching por serviço) | `grpcurl ... req048-grpcroute.<domain>:80 ... GetSummary` | Mesma resposta do item 1 |

---

## Exemplo complementar: GRPCRoute

Demonstra o roteamento gRPC **idiomático** com `GRPCRoute` `v1` (GA na Gateway API), coexistindo com o exemplo principal. Reutiliza o mesmo backend do req048 (Deployment/Service em `req048-grpc`) e usa **hostname e listener dedicados** — obrigatório pela regra de interseção de hostnames da spec (ver [HTTPRoute × GRPCRoute para gRPC](#httproute--grpcroute-para-grpc)).

```
grpcurl ── req048-grpc.<domain> ──────▶ listener req048-grpc ────── HTTPRoute (PathPrefix /) ──┐
                                                                    + AuthPolicy (Kuadrant)    ├──▶ req048-grpc-backend:8080 (h2c)
grpcurl ── req048-grpcroute.<domain> ─▶ listener req048-grpcroute ─ GRPCRoute (method match) ──┘
                                                                    (fora do enforcement Kuadrant)
```

### Deploy

```bash
# Requer a base do req048 aplicada (apply.sh)
bash tests/req048/scripts/apply-grpcroute.sh
```

O script: verifica que o CRD `grpcroutes.gateway.networking.k8s.io` é servido em `v1` (aborta com orientação se não for); verifica a base do req048; adiciona o listener `req048-grpcroute` ao gateway; aplica [`manifests/05-grpcroute.yaml`](manifests/05-grpcroute.yaml); aguarda `Accepted`.

### Validação

```bash
bash tests/req048/scripts/validate-grpcroute.sh
```

Manual:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST_GRPCROUTE="req048-grpcroute.${CLUSTER_DOMAIN}"

# GRPCRoute aceito pelo gateway
oc -n req048-grpc get grpcroute req048-grpcroute \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Esperado: True

# Reflexão (roteada pela regra de infraestrutura do GRPCRoute)
grpcurl -plaintext $HOST_GRPCROUTE:80 list

# Unary — matching por serviço (rules.matches.method.service)
grpcurl -plaintext -d '{"api_version":"v1"}' \
  $HOST_GRPCROUTE:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary

# Server-streaming
grpcurl -plaintext -d '{"interval_ms":500,"max_events":3}' \
  $HOST_GRPCROUTE:80 io.gatewaysmashes.rhcl.grpc.BankingService/StreamHealth

# Coexistência — o exemplo HTTPRoute continua respondendo
grpcurl -plaintext -d '{"api_version":"v1"}' \
  req048-grpc.${CLUSTER_DOMAIN}:80 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
```

### Matching explícito por serviço

O GRPCRoute roteia **apenas** os serviços declarados nas `rules` (`io.gatewaysmashes.rhcl.grpc.BankingService`, reflexão e health). Uma chamada a um serviço não declarado é rejeitada pelo **gateway** (o cliente recebe `UNIMPLEMENTED`/HTTP 404) sem chegar ao backend. Com o HTTPRoute (`PathPrefix /`), todo path chega ao backend. Esse é o principal diferencial didático entre as duas abordagens.

### Limpeza (somente o exemplo GRPCRoute)

```bash
bash tests/req048/scripts/cleanup-grpcroute.sh
```

Remove o GRPCRoute e o listener `req048-grpcroute`; o exemplo HTTPRoute permanece ativo. O `cleanup.sh` completo também remove os recursos do GRPCRoute.

---

## Notas técnicas

### HTTPRoute × GRPCRoute para gRPC

> O `GRPCRoute` graduou para `v1` (GA) na Gateway API v1.1. Neste cluster (OpenShift 4.21, Gateway API bundle v1.3.0) o CRD é servido em `v1` e o controller do gateway (`openshift-default`/Istio) o suporta. Este item demonstra **as duas abordagens** — HTTPRoute como principal e GRPCRoute como complementar.

| Aspecto | HTTPRoute | GRPCRoute |
|---------|-----------|-----------|
| Matching | Path/método HTTP/headers/query — o método gRPC vira path manual (`/pacote.Servico/Metodo`) | Serviço/método gRPC (`matches.method.service`/`.method`) e metadata — idiomático |
| Semântica HTTP/2 (trailers com `grpc-status`, conexão sem upgrade) | Funciona no Envoy/Istio, mas é garantia da **implementação** | Garantia da **spec** da Gateway API |
| gRPC-Web (`application/grpc-web+proto`) | Sim (demonstrado neste item) | Fora do escopo da spec (voltado a gRPC nativo) |
| Filtros | requestHeaderModifier, redirect, mirror, URLRewrite (⚠ rewrite quebra gRPC) | requestHeaderModifier, mirror |
| **Políticas Kuadrant (AuthPolicy/RateLimitPolicy)** | **Sim** — `targetRef.kind: HTTPRoute` | **Não no RHCL 1.3.5** (ver limitação abaixo) |

**Quando usar cada um (em se tratando de gRPC):**

- **HTTPRoute** — quando a API gRPC precisa de governança Kuadrant (autenticação, rate limit), quando REST e gRPC compartilham o mesmo hostname, ou quando há clientes gRPC-Web.
- **GRPCRoute** — roteamento gRPC puro com intenção explícita: rotear serviços/métodos do mesmo backend de forma distinta (canary por método, split por serviço), manifests mais legíveis para catálogo/governança, e semântica HTTP/2 garantida pela API (não pela implementação).

**Limitação do RHCL 1.3.5 com GRPCRoute (verificada nesta POC):**

1. Os CRDs `authpolicies.kuadrant.io` e `ratelimitpolicies.kuadrant.io` restringem `targetRef.kind` a `HTTPRoute` ou `Gateway` (validação CEL) — **não é possível anexar políticas Kuadrant a um GRPCRoute**.
2. O plano de dados do Kuadrant (WasmPlugin `kuadrant-<gateway>`) deriva seus `actionSets` **apenas de HTTPRoutes**. Tráfego roteado por GRPCRoute não casa com nenhum actionSet e **não passa pelo enforcement — nem pelo AuthPolicy deny-all do gateway**. Trate isso como decisão de arquitetura: gRPC governado pelo RHCL ⇒ HTTPRoute.

**Coexistência (regra da spec Gateway API):** se um HTTPRoute e um GRPCRoute com hostnames intersectantes forem anexados ao mesmo listener, apenas a rota **mais antiga** é aceita. Por isso o exemplo GRPCRoute usa hostname e listener próprios (`req048-grpcroute.<domain>`).

### appProtocol vs. port name prefix

O Istio/Envoy suporta duas formas de detecção de protocolo:

| Método | Exemplo | Status |
|--------|---------|--------|
| `appProtocol` (recomendado) | `appProtocol: kubernetes.io/h2c` | GA, padrão Kubernetes |
| Port name prefix (legado) | `name: grpc-banking` | Funcional mas deprecated |

Este requisito usa `appProtocol` por ser o método recomendado e padrão.

### gRPC-Web vs gRPC nativo

| Aspecto | gRPC nativo | gRPC-Web |
|---------|-------------|----------|
| Transporte | HTTP/2 obrigatório | HTTP/1.1 ou HTTP/2 |
| Client | `grpcurl`, libs gRPC | Browser (fetch/XHR), `curl` |
| Framing | gRPC standard | gRPC-Web framing (5-byte header) |
| Streaming | Full bidi | Server-streaming apenas |
| Content-Type | `application/grpc` | `application/grpc-web+proto` |

---

## Troubleshooting

### Deployment não fica Ready

```bash
# Verificar eventos
oc -n req048-grpc get events --sort-by=.lastTimestamp | tail -20

# Verificar logs do pod
oc -n req048-grpc logs deployment/req048-banking-api

# Causa comum: imagem não encontrada → verificar RoleBinding
oc -n rhcl-apps get rolebinding req048-image-puller
```

### grpcurl trava (DeadlineExceeded) via gateway, mas funciona direto no backend

```bash
# Causa: o req026 instala o EnvoyFilter files-upload-max-body, que insere
# envoy.filters.http.buffer em TODO o gateway compartilhado. O buffer espera
# o corpo completo da requisição — RPCs com request de streaming (reflexão
# do grpcurl, EchoStream) nunca "completam" e travam. Unary não é afetado.
oc -n openshift-ingress get envoyfilter files-upload-max-body

# Correção (aplicada pelos scripts apply.sh/apply-grpcroute.sh):
# EnvoyFilter req048-grpc-streaming-no-buffer desabilita o buffer nos
# vhosts do req048 via BufferPerRoute (mesmo mecanismo usado pelo req026).
oc -n openshift-ingress get envoyfilter req048-grpc-streaming-no-buffer
```

### grpcurl retorna "connection refused"

```bash
# Verificar se o listener existe no gateway
oc -n openshift-ingress get gateway -o jsonpath='{.items[0].spec.listeners[*].name}' | tr ' ' '\n' | grep req048

# Verificar DNS
nslookup req048-grpc.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Testar de dentro do cluster (bypass DNS externo)
oc -n req048-grpc run grpc-test --rm -i --restart=Never \
  --image=fullstorydev/grpcurl:latest -- \
  -plaintext -d '{"api_version":"v1"}' \
  req048-grpc-backend.req048-grpc.svc:8080 io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary
```

### HTTPRoute não aceito (Accepted=False)

```bash
# Verificar condições
oc -n req048-grpc get httproute req048-grpc-route -o yaml | grep -A5 conditions

# Causas comuns:
# - Listener não existe → executar apply.sh novamente
# - Hostname conflita com outro HTTPRoute → verificar listeners
# - Namespace não permitido → verificar allowedRoutes no listener
```

### GRPCRoute não aceito (Accepted=False)

```bash
# Verificar condições
oc -n req048-grpc get grpcroute req048-grpcroute -o yaml | grep -A5 conditions

# Causas comuns:
# - Listener req048-grpcroute não existe → executar apply-grpcroute.sh novamente
# - Hostname intersecta com o de um HTTPRoute no mesmo listener → a spec
#   aceita apenas a rota mais antiga; use hostnames/listeners distintos
# - CRD grpcroutes não servido em v1 → verificar:
#   oc get crd grpcroutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'
```

### grpcurl retorna UNIMPLEMENTED via GRPCRoute

```bash
# O serviço chamado não casa com nenhuma regra do GRPCRoute (matching explícito).
# Conferir os serviços roteados:
oc -n req048-grpc get grpcroute req048-grpcroute \
  -o jsonpath='{range .spec.rules[*].matches[*]}{.method.service}{"\n"}{end}'
```

### gRPC-Web retorna 404 ou 415

```bash
# Verificar que o path está correto (case-sensitive)
curl -v -X POST \
  -H 'content-type: application/grpc-web+proto' \
  "http://${HOST}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary"

# Verificar que o backend suporta gRPC-Web
oc -n req048-grpc exec deployment/req048-banking-api -- \
  curl -s localhost:8080/q/health/ready
```

---

## Limpeza

```bash
bash tests/req048/scripts/cleanup.sh
```

O script remove:
- Listeners `req048-grpc` e `req048-grpcroute` do gateway
- EnvoyFilter `req048-grpc-streaming-no-buffer` em `openshift-ingress`
- Namespace `req048-grpc` (inclui Deployment, Service, HTTPRoute, GRPCRoute, AuthPolicy)
- RoleBinding `req048-image-puller` em `rhcl-apps`

Para remover **apenas** o exemplo GRPCRoute (mantendo o HTTPRoute): `bash tests/req048/scripts/cleanup-grpcroute.sh`

---

## Referências

- [RHCL 1.3 — Configuring and deploying gateway policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/configuring_and_deploying_gateway_policies/rhcl-config-deploy-gateway-policies)
- [Kubernetes — Service appProtocol](https://kubernetes.io/docs/concepts/services-networking/service/#application-protocol)
- [Istio — Protocol Selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/)
- [Gateway API — HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [Gateway API — GRPCRoute](https://gateway-api.sigs.k8s.io/api-types/grpcroute/)
- [gRPC — Core concepts](https://grpc.io/docs/what-is-grpc/core-concepts/)
- [gRPC-Web — Protocol specification](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md)
- [OSSM 3.x — Feature Support Tables](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/release_notes/ossm-release-notes-feature-support-tables)
- [Envoy — gRPC bridging](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/other_protocols/grpc)
