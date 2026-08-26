# REQ 035 — Runbook: Logging de toda requisição com erro no gateway

Passo-a-passo completo para demonstrar o item 35 da PoC:

> *"Solução deverá logar / enviar log de todo e qualquer evento / requisição
> onde o erro ocorrer no gateway."*

---

## O que esta solução entrega

| Capacidade | Onde fica |
|---|---|
| Captura **100%** de toda request com status ≥ 400 (4xx **e** 5xx) | Envoy access log do data plane do `rhcl-apps-gateway` |
| Filtra fora os 2xx/3xx **no Envoy** (zero overhead pro happy path) | `status_code_filter` no EnvoyFilter |
| Mesma fonte cobre **auth denial (401/403)**, **rate limit (429)**, **backend error (5xx)** e **timeout/network (Envoy response flags)** | Authorino e Limitador retornam pelo Envoy — uma rota canônica |
| Correlação **log ↔ trace** | OTLP record carrega `traceId`/`spanId` matching com Tempo |
| Identidade de **consumer** (alice/bob/carol) e **denial reason** detalhado do Authorino | Atributos `consumer.id` e `auth.reason` (via header injetado pelo Authorino) |
| Mascaramento de **PII** (Authorization, api-key, cookies) | Processador `attributes/scrub` no OTel Collector |
| Tag de **cluster/gateway** para agregadores multi-cluster | Processador `resource/rhcl-tag` |
| Saída em **JSON Lines** apend-only (PoC) ou pluggable pra Loki/Splunk | Exporter `file/audit` (default) ou `otlphttp/loki|splunk` (configurável) |

---

## Arquitetura

```
┌──────────────────────────────────────────────────────────────────────┐
│  rhcl-apps-gateway (Envoy/Istio data plane)                          │
│                                                                      │
│  Cada request HTTP gera 1 access log record. EnvoyFilter:            │
│    • status_code_filter ≥ 400  (só erro)                             │
│    • OpenTelemetryAccessLogConfig (OTLP/gRPC)                        │
│    • body + atributos: method, path, status, flags, durations,       │
│      trace_id, x-request-id, x-consumer-id, x-ext-auth-reason        │
└──────────────────────────┬───────────────────────────────────────────┘
                           │ OTLP gRPC :4317
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  OTel Collector (observability/otel-rhcl)                            │
│                                                                      │
│  pipeline.logs:                                                      │
│    receivers:    [otlp]                                              │
│    processors:                                                       │
│      • memory_limiter        (reuso da pipeline traces)              │
│      • filter/errors         (defesa em profundidade: code ≥ 400)    │
│      • attributes/scrub      (drop Authorization, api-key, cookies)  │
│      • resource/rhcl-tag     (cluster.name, gateway.name)            │
│      • k8sattributes         (enriquece com pod/namespace/etc.)      │
│      • batch                                                         │
│    exporters:                                                        │
│      • file/audit  → /var/log/rhcl-errors.json  (PoC)                │
│      • otlphttp/loki   (descomentar para LokiStack)                  │
│      • otlphttp/splunk (descomentar para SIEM corporativo)           │
└──────────────────────────────────────────────────────────────────────┘
```

### Por que EnvoyFilter e não Telemetry CR?

A forma "K8s-native" seria criar uma `Telemetry` CR apontando para um
`extensionProvider` registrado no `meshConfig.extensionProviders` do Istio.
Em RHCL 1.3 (Sail Operator) testamos esse caminho e o Sail descarta
silenciosamente qualquer patch no `meshConfig.extensionProviders` do CR
`Istio` — o reconciler reverte a chave antes da próxima leitura.

**`EnvoyFilter`** é o mesmo mecanismo que `kuadrant-tracing-rhcl-apps-gateway`
(já shipado pela role `observability`/req038) usa, então adotamos o mesmo
padrão. Trade-off: low-level, mas funciona com 100% de certeza neste stack.

---

## Pré-requisitos

| Componente | Verificação |
|---|---|
| OTel Collector instalado (req038) | `oc get opentelemetrycollector -n observability otel-rhcl` |
| Gateway `rhcl-apps-gateway` no ar | `oc get gateway -A \| grep rhcl-apps-gateway` |
| Sail Operator (Service Mesh 3) com Istio CR `openshift-gateway` | `oc get istio openshift-gateway` |
| Acesso cluster-admin | `oc whoami` → `kube:admin` ou similar |

---

## Aplicação rápida (script)

```bash
bash tests/req035/scripts/apply.sh
```

Para validar:

```bash
bash tests/req035/scripts/validate.sh
```

Para remover:

```bash
bash tests/req035/scripts/cleanup.sh
```

---

## Aplicação manual — passo a passo

### Passo 1 — Patch no OTel Collector (pipeline `logs`)

```bash
oc apply -f tests/req035/manifests/02-otel-collector-logs-pipeline.yaml
oc rollout status deploy/otel-rhcl-collector -n observability --timeout=180s
```

Cria a pipeline `logs` no mesmo Collector que serve a pipeline `traces` —
sem novo pod, sem nova porta. Monta um `emptyDir` em `/var/log` para o
exporter `file/audit` escrever `rhcl-errors.json`.

**Validação:**

```bash
oc get opentelemetrycollector -n observability otel-rhcl \
  -o jsonpath='{.spec.config.service.pipelines.logs}' | python3 -m json.tool
```

### Passo 2 — EnvoyFilter no gateway

```bash
oc apply -f tests/req035/manifests/01-envoyfilter-otel-access-logs.yaml
```

Injeta um `access_log` do tipo `envoy.access_loggers.open_telemetry` no
HTTP connection manager dos listeners do `rhcl-apps-gateway`. O
`status_code_filter` com `GE 400` garante que **só requests com erro**
saem do data plane.

**Validação:**

```bash
oc get envoyfilter -n openshift-ingress otel-access-logs-rhcl-apps-gateway
```

### Passo 3 — Reload do data plane

```bash
oc rollout restart deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress
oc rollout status   deploy/rhcl-apps-gateway-openshift-default -n openshift-ingress --timeout=180s
```

O EnvoyFilter é distribuído via xDS; o restart força os pods a re-pull
da config nova. Em produção isso pode ser feito sem downtime (rolling
update já garante).

---

## Teste end-to-end

Gere um mix de tráfego (200 OK + 401 + 404) e acompanhe ao vivo:

```bash
# Terminal 1 — tail do audit
COL=$(oc get pods -n observability -l app.kubernetes.io/name=otel-rhcl-collector \
        -o jsonpath='{.items[0].metadata.name}')
oc exec -n observability "$COL" -- tail -F /var/log/rhcl-errors.json

# Terminal 2 — tráfego
URL=https://$(oc get httproute -n rhcl-apps banking-api-connectivity \
                 -o jsonpath='{.spec.hostnames[0]}')
ALICE=$(oc get secret -n rhcl-apps banking-api-key-alice \
          -o jsonpath='{.data.api_key}' | base64 -d)

# 5x 200 — devem NÃO aparecer no audit
for _ in {1..5}; do curl -sk -o /dev/null -H "api-key: $ALICE" "$URL/api/v1/accounts/summary"; done

# 5x 401 — devem aparecer com auth.reason="credential not found"
for _ in {1..5}; do curl -sk -o /dev/null "$URL/api/v1/accounts/summary"; done

# 3x 404 — devem aparecer com response.flags="NR" (No Route)
for _ in {1..3}; do curl -sk -o /dev/null -H "api-key: $ALICE" "$URL/api/v9/no-route"; done
```

Exemplo de **uma entry** no audit file (após parse):

```json
{
  "body":  "GET /api/v1/accounts/summary 401 flags=- duration_ms=2 upstream=-",
  "trace_id": "ad09689010fd7026f20a9588a44f3bc0",
  "http.method":   "GET",
  "http.path":     "/api/v1/accounts/summary",
  "response_code": "401",
  "response.flags": "-",
  "auth.reason":   "{\"api-key-header\":\"credential not found\",\"api-key-query\":\"credential not found\"}",
  "consumer.id":   "-",
  "request.id":    "0d47efab-1de0-9608-abbf-4aa92eae0daf"
}
```

---

## Atributos capturados (referência)

| Atributo | Origem (Envoy) | Para que serve |
|---|---|---|
| `http.method` | `%REQ(:METHOD)%` | Análise por verbo |
| `http.path` | `%REQ(:PATH)%` | Endpoint específico em falha |
| `http.host` | `%REQ(:AUTHORITY)%` | Discriminar hostnames |
| `response_code` | `%RESPONSE_CODE%` | Classificação 4xx vs 5xx |
| `response.flags` | `%RESPONSE_FLAGS%` | Códigos do Envoy (NR=no route, UF=upstream failure, UT=upstream timeout, etc.) |
| `duration.ms` | `%DURATION%` | Triagem de timeouts |
| `upstream.host` / `upstream.cluster` | `%UPSTREAM_HOST/CLUSTER%` | Qual backend foi tentado |
| `bytes.received` / `bytes.sent` | `%BYTES_*%` | Detecção de payload anômalo |
| `request.id` | `%REQ(X-REQUEST-ID)%` | Correlation com Tempo + métricas Prometheus |
| `request.flow_trace_id` | `%REQ(X-FLOW-TRACE-ID)%` | Trace de fluxo de negócio (customizável pelo cliente) |
| `consumer.id` | `%REQ(X-CONSUMER-ID)%` | Quem foi (alice/bob/carol, ou `-` se anonymous) |
| `user.agent` | `%REQ(USER-AGENT)%` | Identificação do cliente |
| `auth.reason` | `%RESP(X-EXT-AUTH-REASON)%` | Motivo do denial do Authorino |
| `traceId` / `spanId` | OTel SDK do Envoy | Join nativo com Tempo |
| `k8s.pod.name`, `k8s.node.name`, etc. | k8sattributes processor | Onde rolou |
| `cluster.name`, `gateway.name`, `signal.kind` | resource/rhcl-tag processor | Agregação multi-cluster |

---

## Mudança para LokiStack ou SIEM (produção)

O exporter `file/audit` é PoC. Para produção:

1. **LokiStack** (instale o Logging Operator):
   ```yaml
   otlphttp/loki:
     endpoint: https://lokistack-gateway-http.openshift-logging.svc:8080/api/logs/v1/application/otlp
     tls:
       ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
   ```

2. **Splunk HEC** (SIEM corporativo):
   ```yaml
   otlphttp/splunk:
     endpoint: https://splunk-hec.internal.example.com:8088/services/collector
     headers:
       Authorization: "Splunk ${env:SPLUNK_HEC_TOKEN}"
   ```

3. **Datadog / Elastic / qualquer destino OTLP-compatível** — basta
   substituir `endpoint` + auth. Ambos podem coexistir com `file/audit`
   no mesmo `exporters[]` (multi-destination é nativo do Collector).

---

## Toggle no playbook

O role `observability` honra a variável:

```bash
OBSERVABILITY_ACCESS_LOGS_ENABLED=true|false  # default: true
```

Setar `false` desliga o EnvoyFilter e a pipeline `logs` sem afetar
traces ou métricas. Útil para troubleshooting em ambientes onde o
exporter está sob suspeita.

---

## Operação

| Ação | Comando |
|---|---|
| Stream ao vivo | `oc exec -n observability <col-pod> -- tail -F /var/log/rhcl-errors.json` |
| Contar 5xx última hora | `oc exec -n observability <col-pod> -- grep -c '"response_code".*"5' /var/log/rhcl-errors.json` |
| Encontrar trace de um request | grepar `request.id` no audit, depois abrir `traceId` no Tempo / Distributed Tracing UI |
| Desabilitar temporariamente o filtro 400 | `oc patch envoyfilter -n openshift-ingress otel-access-logs-rhcl-apps-gateway --type=merge -p '...'` (mudar `default_value: 0`) — útil para capturar 100% durante triagem |

---

## Compliance & hardening checklist

- [ ] **PII**: confirmar com o time de segurança a lista final de headers/atributos a fazer scrub. Default cobre `Authorization`, `Cookie`, `Set-Cookie`, `api-key`, `x-api-key`.
- [ ] **Retenção**: configurar destino de log (LokiStack / SIEM) com política de retenção compatível com o requisito regulatório (BACEN, LGPD).
- [ ] **Imutabilidade**: destino com WORM (LokiStack S3 backend, ou tier dedicado no SIEM).
- [ ] **Disponibilidade**: `OpenTelemetryCollector` com `replicas: 2+` e `mode: deployment` para HA. Caso o Collector caia, o data plane bufferiza temporariamente e re-tenta; `memory_limiter` evita OOM.
- [ ] **Time sync**: NTP nos nodes obrigatório para correlação log/trace/metric.
- [ ] **Audit do próprio audit**: mudanças no `EnvoyFilter` e no `OpenTelemetryCollector` devem ir via GitOps (ArgoCD) — toda mudança é PR auditável.

---

## Limpeza

```bash
bash tests/req035/scripts/cleanup.sh
```

Remove o EnvoyFilter, a pipeline `logs` do Collector e o volume `emptyDir`.
A pipeline `traces` (req038) segue funcionando intacta.
