# REQ 038 — Runbook: OpenTelemetry traces e métricas

Passo-a-passo completo para demonstrar o item 38 da POC: "Expor trace e métricas nos padrões OpenTelemetry".

---

## Pré-requisitos

| Componente | Verificação |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant instalado | `oc get kuadrant -n kuadrant-system` |
| Sail Operator (Service Mesh 3) | `oc api-resources \| grep sailoperator` |
| Tempo Operator | `oc get namespace openshift-tempo-operator` |
| Red Hat build of OpenTelemetry Operator | `oc get namespace openshift-opentelemetry-operator` |
| Cluster Observability Operator (COO) | `oc get namespace openshift-cluster-observability-operator` |
| Acesso cluster-admin | `oc whoami` → `kube:admin` ou similar |

### Instalar operators ausentes

Se os operators Tempo ou OpenTelemetry não estiverem instalados, instale-os via **OperatorHub** (Software Catalog) no console do OpenShift ou via CLI:

```bash
# Verificar operators instalados
oc get csv -A | egrep -i 'tempo|opentelemetry|sail'
```

---

## Aplicação rápida (script)

O script `apply.sh` aplica todos os manifests na ordem correta, com waits e verificações automáticas:

```bash
bash tests/req038/scripts/apply.sh
```

Para validar o estado final:

```bash
bash tests/req038/scripts/validate.sh
```

Para remover tudo:

```bash
bash tests/req038/scripts/cleanup.sh
```

---

## Aplicação manual — passo a passo

### Passo 1 — MinIO (object storage para Tempo)

MinIO é usado como backend S3-compatível para o TempoStack (apenas para POC/lab).

```bash
oc apply -f tests/req038/manifests/01-minio.yaml
```

Cria: namespace `minio`, Secret, PVC, Deployment, Service, Route, Job (bucket), namespace `tempo`, Secret `tempo-storage`.

**Validação:**

```bash
oc -n minio rollout status deployment/minio
oc -n minio logs job/minio-create-bucket
oc -n minio get route minio-console -o jsonpath='https://{.spec.host}{"\n"}'
```

Credenciais do console MinIO: `tempo` / `supersecret`

---

### Passo 2 — TempoStack

```bash
oc apply -f tests/req038/manifests/02-tempostack.yaml
```

Cria o `TempoStack` `tempo-rhcl` no namespace `tempo`, com gateway habilitado e Jaeger Query para visualização de traces.

**Validação:**

```bash
oc -n tempo get tempostack
oc -n tempo get pods
oc -n tempo get svc | egrep 'gateway|distributor|query'
```

Aguarde até o TempoStack ficar `Ready`:

```bash
oc -n tempo get tempostack tempo-rhcl -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

---

### Passo 3 — RBAC

```bash
oc apply -f tests/req038/manifests/03-rbac.yaml
```

Cria: namespace `observability`, ServiceAccount `otel-collector`, ClusterRoles e ClusterRoleBindings para:

- enriquecer spans com metadados Kubernetes/OpenShift (`k8sattributes`)
- escrever traces no tenant `dev` do TempoStack

---

### Passo 4 — OpenTelemetry Collector

```bash
oc apply -f tests/req038/manifests/04-opentelemetry.yaml
```

Cria o `OpenTelemetryCollector` `otel-rhcl` no namespace `observability`. O Collector:

- recebe traces via OTLP gRPC (porta 4317) e HTTP (porta 4318)
- enriquece com `k8sattributes` e `resourcedetection` (OpenShift)
- exporta para o gateway do TempoStack com autenticação bearer token

**Validação:**

```bash
oc -n observability get opentelemetrycollector
oc -n observability get pods
oc -n observability get svc | grep otel
```

O service do Collector será algo como:

```text
otel-rhcl-collector.observability.svc.cluster.local:4317
```

---

### Passo 5 — EnvoyFilter: tracing OpenTelemetry no gateway

> **Nota sobre o Istio CR**: A documentação OSSM 3.3 recomenda configurar `extensionProviders` no Istio CR. Neste cluster, o CR `openshift-gateway` é gerenciado pelo controller da GatewayClass e reverte qualquer patch. A solução é injetar o tracer OpenTelemetry diretamente no Envoy via `EnvoyFilter`.

```bash
oc apply -f tests/req038/manifests/05-envoyfilter-otel-tracing.yaml
```

O EnvoyFilter configura o tracer `envoy.tracers.opentelemetry` nos listeners do gateway, apontando para o Collector via gRPC (porta 4317), com 100% de sampling.

**Validação:**

```bash
# Verificar o EnvoyFilter
oc -n openshift-ingress get envoyfilter otel-tracing

# Confirmar que o tracer está ativo no Envoy do gateway
oc -n openshift-ingress exec deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
for cfg in d.get('configs',[]):
    if 'listeners' in cfg.get('@type','').lower():
        for l in cfg.get('dynamic_listeners',[]):
            active=l.get('active_state',{}).get('listener',{})
            for fc in active.get('filter_chains',[])[:1]:
                for f in fc.get('filters',[]):
                    tc=f.get('typed_config',{})
                    prov=tc.get('tracing',{}).get('provider',{})
                    if prov:
                        print(json.dumps(prov,indent=2))
                        break
            break
        break
"
```

---

### Passo 6 — Kuadrant observability e tracing

Usa `oc patch --type=merge` para adicionar **apenas** o campo `spec.observability` sem sobrescrever outros campos do CR Kuadrant existente:

```bash
oc -n kuadrant-system patch kuadrant kuadrant --type=merge -p '{
  "spec": {
    "observability": {
      "enable": true,
      "dataPlane": {
        "defaultLevels": [{"debug": "true"}],
        "httpHeaderIdentifier": "x-request-id"
      },
      "tracing": {
        "defaultEndpoint": "rpc://otel-rhcl-collector.observability.svc.cluster.local:4317",
        "insecure": true
      }
    }
  }
}'
```

O patch (referência YAML em [`07-kuadrant-observability.yaml`](manifests/07-kuadrant-observability.yaml)) habilita no CR `Kuadrant`:

- `observability.enable: true` — cria `ServiceMonitor` e `PodMonitor` para scrape via Prometheus
- `observability.tracing` — envia spans do Authorino, Limitador e wasm-shim para o Collector
- `observability.dataPlane.httpHeaderIdentifier: x-request-id` — correlaciona requests entre métricas, traces e logs

**Validação de métricas:**

```bash
oc get servicemonitor,podmonitor -A -l kuadrant.io/observability=true
```

**Validação de tracing:**

```bash
oc -n kuadrant-system get kuadrant kuadrant -o jsonpath='{.spec.observability.tracing}'
```

---

### Passo 7 — UIPlugin: Distributed Tracing no console OpenShift

> **Nota:** A Jaeger UI é **deprecated** e será removida em releases futuros. O método recomendado para visualizar traces é via **Observe → Traces** no console do OpenShift, habilitado pelo Cluster Observability Operator (COO).

```bash
oc apply -f tests/req038/manifests/08-uiplugin-distributed-tracing.yaml
```

Cria o `UIPlugin` `distributed-tracing` que registra o plugin de distributed tracing no console do OpenShift. O plugin detecta automaticamente as instâncias `TempoStack` multi-tenant com gateway habilitado.

**Validação:**

```bash
# Verificar o UIPlugin
oc get uiplugin distributed-tracing

# Verificar que o deployment do plugin está rodando
oc -n openshift-cluster-observability-operator get deployment distributed-tracing

# Verificar o ConsolePlugin registrado
oc get consoleplugin distributed-tracing-console-plugin
```

---

## Demonstração

### Gerar tráfego

O endpoint `/api/echo` é público (não exige API Key) e retorna detalhes do request, incluindo headers de tracing (`traceparent`, `tracestate`):

```bash
curl -vk -H "x-request-id: poc-rhcl-otel-001" \
  https://banking-api.poc.rhcl.com.br/api/echo
```

> **Nota:** A flag `-k` (`--insecure`) é necessária porque o certificado TLS do cluster cobre apenas o domínio `*.apps.cluster1.sandbox1992.opentlc.com`, não o CNAME personalizado `banking-api.poc.rhcl.com.br`.

Para gerar múltiplos requests (útil para popular traces no Tempo):

```bash
for i in $(seq 1 10); do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    -H "x-request-id: poc-rhcl-otel-$(printf '%03d' $i)" \
    https://banking-api.poc.rhcl.com.br/api/echo
done
```

Para testar com endpoint protegido (exige `api-key`):

```bash
curl -vk -H "x-request-id: poc-rhcl-otel-auth-001" \
  -H "api-key: alice-gold-secret" \
  https://banking-api.poc.rhcl.com.br/api/v1/echo
```

### Propagação de traces backend→backend (ledger-api)

Esta demo mostra a **propagação** do contexto de trace entre microserviços: o `banking-api`
chama o microserviço **`ledger-api`**, e os spans aparecem encadeados sob um **único Trace ID**
(`rhcl-gateway → banking-api → ledger-api`). A propagação é feita pelo **agente Java injetado**
(CR `Instrumentation` com `propagators: [tracecontext, baggage]` + anotação `inject-java`) — sem
código de instrumentação nas aplicações. Detalhes e diagrama: ver `[../req038.md](../req038.md)`,
seção "Propagação de traces backend→backend".

**Pré-requisito:** o `ledger-api` é provisionado pelo role `apps` (gated por `apps_ledger_enabled`,
default `true`). Garanta a auto-instrumentação ligada (`apps_otel_instrumentation_enabled=true`,
default) e a observability já instalada:

```bash
# Deploy/atualização das apps (builda ledger-api + banking-api + frontend)
APPS_LEDGER_ENABLED=true ansible-playbook automation/playbooks/apps-install.yml

# Conferir o microserviço e o agente injetado (init container)
oc -n rhcl-apps get deploy ledger-api banking-api-v1
oc -n rhcl-apps get pod -l app=ledger-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}{"\n"}'   # opentelemetry-auto-instrumentation
```

**Gerar carga:** a chamada entra pela rota `banking-api-connectivity` (gateway), protegida por API
key → envie o header `api-key: alice-gold-secret`. O parâmetro `target` controla só o hop interno
`banking-api → ledger-api`:

```bash
# target=gateway (usado pela aba): banking-api → gateway RHCL (HTTPRoute) → ledger-api
curl -sk -H "api-key: alice-gold-secret" \
  "https://banking-api.<dominio>/api/test/propagate?target=gateway&calls=2" | jq

# target=direct (variação): banking-api → ledger-api via DNS de Service
curl -sk -H "api-key: alice-gold-secret" \
  "https://banking-api.<dominio>/api/test/propagate?target=direct&calls=2" | jq
```

Ou, sem CLI: PoC Console (app `mobile-bank`) → aba **Trace Propagation** → **Run load** (sempre via
gateway). Campos: `Requests` (chamadas ao gateway), `Downstream calls` (chamadas
`banking-api → ledger-api` por request, 1..20) e **API key** (pré-preenchido com `alice-gold-secret`,
editável; limpe-o para reproduzir o **401**). O painel exibe o **Trace ID** e um botão
"Open in trace UI", cujo campo de URL é **auto-preenchido com o Tempo do cluster atual** (editável).

A resposta traz `traceId` (use-o para localizar o trace) e, por chamada, `entryId`,
`downstreamTraceId` e `downstreamInstance` do `ledger-api`. Confirme em **Observe → Traces** que
os spans `rhcl-gateway`, `banking-api` e `ledger-api` compartilham o mesmo Trace ID.

### Evidências a coletar

| Evidência | Como demonstrar |
|---|---|
| **Métricas RHCL/gateway** | `ServiceMonitor`/`PodMonitor` criados, PromQL: `rate(istio_requests_total[1m])` |
| **Traces OpenTelemetry** | Console OpenShift: **Observe → Traces** → selecionar TempoStack e tenant `dev` → buscar por service ou `x-request-id` |
| **Correlação** | Request com `x-request-id`, mostrar métrica + trace + log com mesmo ID |
| **Policy observability** | Criar `RateLimitPolicy`, gerar `429`, mostrar métrica + trace do Limitador |
| **Propagação de traces** | `GET /api/test/propagate` (ou aba **Trace Propagation**); trace `rhcl-gateway → banking-api → ledger-api` sob um único Trace ID |

### Visualizar traces

#### Via console OpenShift (recomendado)

1. Acesse o console web do OpenShift
2. No menu lateral, navegue até **Observe → Traces**
3. No seletor de instância, escolha **tempo-rhcl** (namespace `tempo`)
4. No seletor de tenant, escolha **dev**
5. Defina o intervalo de tempo e clique em **Run Query**
6. O scatter plot exibe os traces com tempo de início, duração e quantidade de spans
7. Clique em um trace para ver o detail view com spans individuais

#### Via Jaeger UI (deprecated)

> **Aviso:** A Jaeger UI será removida em releases futuros. Prefira o console OpenShift.

```bash
oc -n tempo get route
```

Acesse a URL da route do gateway com o sufixo `/dev` (nome do tenant).

### PromQL úteis

```promql
# Requests por segundo no gateway
rate(istio_requests_total[1m])

# Latência p99
histogram_quantile(0.99, rate(istio_request_duration_milliseconds_bucket[5m]))

# Taxa de erro
sum(rate(istio_requests_total{response_code=~"5.."}[1m])) /
sum(rate(istio_requests_total[1m]))
```

---

## Troubleshooting

### TempoStack não fica Ready

```bash
oc -n tempo get tempostack tempo-rhcl -o yaml | grep -A5 conditions
oc -n tempo get events --sort-by='.lastTimestamp'
oc -n tempo logs -l app.kubernetes.io/instance=tempo-rhcl --tail=50
```

Causas comuns: bucket não criado, credenciais erradas no Secret `tempo-storage`, PVC não provisionado.

### Collector não recebe traces

```bash
oc -n observability logs -l app.kubernetes.io/name=otel-rhcl-collector --tail=50
```

Verifique se o exporter aponta para o gateway correto do Tempo:

```bash
oc -n observability get opentelemetrycollector otel-rhcl -o yaml | grep endpoint
```

### Telemetry não funciona

Verifique se o extensionProvider `otel` existe na config do Istio:

```bash
oc get istio default -o jsonpath='{.spec.values.meshConfig}' | python3 -m json.tool
```

Verifique se o istiod injetou a configuração nos sidecars:

```bash
oc -n <namespace-do-gateway> exec <pod-envoy> -c istio-proxy -- \
  pilot-agent request GET config_dump | grep -A5 opentelemetry
```

### Kuadrant não cria ServiceMonitors

```bash
oc -n kuadrant-system get kuadrant kuadrant -o yaml | grep -A10 observability
oc -n kuadrant-system logs deployment/kuadrant-operator-controller-manager --tail=50
```

---

## Arquitetura do stack

```text
Client
  │  curl -H "x-request-id: poc-rhcl-otel-001"
  ▼
Gateway / Envoy (istio-proxy)
  │  extensionProvider: otel → envia spans via OTLP
  ▼
RHCL policies: AuthPolicy / RateLimitPolicy
  │  Authorino / Limitador / wasm-shim → enviam spans
  ▼
OpenTelemetryCollector (otel-rhcl, ns: observability)
  │  Recebe OTLP, enriquece (k8sattributes), exporta
  ▼
TempoStack (tempo-rhcl, ns: tempo)
  │  Armazena traces no MinIO (S3)
  ▼
OpenShift Console — Observe → Traces (via COO UIPlugin)
  │  Visualização e busca de traces (substitui Jaeger UI)
  ▼
Prometheus / OpenShift Monitoring
     Métricas via ServiceMonitor/PodMonitor
```

---

## Limpeza

```bash
bash tests/req038/scripts/cleanup.sh
```

Ou manualmente, na ordem inversa (7 → 1):

```bash
# 7. UIPlugin
oc delete uiplugin distributed-tracing --ignore-not-found

# 6. Kuadrant
oc -n kuadrant-system patch kuadrant kuadrant --type=json \
  -p='[{"op": "remove", "path": "/spec/observability"}]'

# 5. EnvoyFilter
oc -n openshift-ingress delete envoyfilter otel-tracing --ignore-not-found

# 4. Collector
oc -n observability delete opentelemetrycollector otel-rhcl

# 3. RBAC
oc delete clusterrolebinding tempostack-traces-write otel-collector-k8s
oc delete clusterrole tempostack-traces-write otel-collector-k8s
oc -n observability delete sa otel-collector

# 2. TempoStack
oc -n tempo delete tempostack tempo-rhcl

# 1. MinIO
oc delete namespace minio tempo observability
```
