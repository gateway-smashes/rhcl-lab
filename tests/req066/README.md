# REQ 066 — Runbook: Auditoria e rastreabilidade de chamadas

Passo-a-passo completo para demonstrar o item 66 da POC: "Auditoria e rastreabilidade de chamadas".

---

## O que este item demonstra

O RHCL registra **cada chamada** que passa pelo gateway em um **access log estruturado (JSON)** no stdout do pod Envoy. Este log contém campos de auditoria que respondem:

| Pergunta de auditoria | Campo no access log |
|---|---|
| **Quando?** | `timestamp` |
| **Quem chamou?** (IP) | `client_ip`, `x_forwarded_for` |
| **Quem é o consumidor?** | `consumer_id` (injetado pelo Authorino via `x-consumer-id`) |
| **O que foi chamado?** | `method`, `path`, `authority` |
| **Qual foi o resultado?** | `response_code`, `response_flags` |
| **Quanto tempo levou?** | `duration_ms` |
| **Qual rota/política deu match?** | `route_name` |
| **Foi negado? Por quê?** | `auth_reason` (motivo do Authorino) |
| **Como correlacionar com o trace?** | `request_id` (gerado pelo Envoy), `traceparent` |
| **Qual a segurança do canal?** | `downstream_tls_version`, `downstream_tls_cipher` |
| **Como correlacionar pelo lado do cliente?** | `flow_trace_id` (header `x-flow-trace-id` enviado pelo cliente) |

### Onde ver a evidência

> **IMPORTANTE:** A evidência do req066 aparece nos **logs do pod do gateway** (`oc logs`), **NÃO** na UI de Traces (Observe → Traces). A UI de Traces é funcionalidade do **req038** (distributed tracing com spans OTLP no Tempo).

```bash
# Access log do req066 — JSON estruturado no stdout do gateway
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=10
```

Cada request produz **duas linhas** no log:

1. **Formato texto** (padrão Envoy/Istio — já existia antes do req066):
```
[2026-06-11T13:45:16.371Z] "GET /api/v1/accounts/summary HTTP/2" 200 - via_upstream ...
```

2. **Formato JSON** (adicionado pelo req066 — é a evidência de auditoria):
```json
{"timestamp":"2026-06-11T13:45:16.371Z","method":"GET","path":"/api/v1/accounts/summary","response_code":200,"client_ip":"100.64.0.17","consumer_id":"alice","request_id":"c414857e-3edc-9743-a5c7-0024455afc55","traceparent":"00-5a9427f8c25d56a40fc3d9a92a223bc2-ec368a4d739e18d5-01","downstream_tls_version":"TLSv1.3","downstream_tls_cipher":"TLS_AES_256_GCM_SHA384","route_name":"rhcl-apps.banking-api-connectivity.0",...}
```

---

## Diferença entre req038, req035 e req066

| Aspecto | req038 | req035 | req066 |
|---|---|---|---|
| **Função** | Traces e métricas OpenTelemetry | Log de erros do gateway | **Auditoria e rastreabilidade** |
| **O que captura** | Spans OTLP (timing de cada componente) | Apenas requests com erro (≥400) | **Todas as requests (100%)** |
| **Destino** | Tempo (via OTel Collector) | Arquivo JSON no OTel Collector | **stdout do pod gateway** |
| **Onde ver** | Observe → Traces | `oc exec` no Collector | **`oc logs` do gateway** |
| **Consumer ID** | Não | Sim | **Sim** |
| **Auth reason** | Não | Sim | **Sim** |
| **TLS info** | Não | Não | **Sim** |
| **PII scrub** | N/A | Sim (no Collector) | Não (stdout bruto) |

Os três são **complementares**:
- **req038** = rastreabilidade de performance (quanto tempo cada componente levou)
- **req035** = auditoria de erros centralizada (4xx/5xx em arquivo dedicado)
- **req066** = auditoria completa no gateway (todas as chamadas, com identidade e TLS)

---

## Pré-requisitos

| Componente | Verificação |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant instalado | `oc get kuadrant -n kuadrant-system` |
| Gateway do RHCL ativo | `oc -n openshift-ingress get deploy -l gateway.networking.k8s.io/gateway-name=rhcl-apps-gateway` |
| **req038 aplicado** (recomendado) | `oc -n observability get opentelemetrycollector otel-rhcl` |
| Acesso cluster-admin | `oc whoami` |

> O req038 é recomendado (não obrigatório) para a demonstração completa de rastreabilidade (correlação access log ↔ trace distribuído). O access log do req066 funciona independentemente.

---

## Aplicação rápida (script)

```bash
bash tests/req066/scripts/apply.sh
```

Para validar:

```bash
bash tests/req066/scripts/validate.sh
```

Para remover:

```bash
bash tests/req066/scripts/cleanup.sh
```

---

## Aplicação manual — passo a passo

### Passo 1 — EnvoyFilter: access log estruturado (JSON)

```bash
oc apply -f tests/req066/manifests/01-envoyfilter-access-log-json.yaml
```

**Validação:**

```bash
# Confirmar que o EnvoyFilter existe
oc -n openshift-ingress get envoyfilter access-log-json

# Aguardar 5s para o Envoy recarregar via xDS
sleep 5

# Gerar um request de teste com flow trace ID customizado
curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "x-flow-trace-id: req066-test-001" \
  https://banking-api.poc.rhcl.com.br/api/echo

# Verificar que o access log JSON aparece (usar --tail=20 pois cada request gera 2 linhas)
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=20 | grep "req066-test-001"
```

### Passo 2 (opcional) — Filtro de health checks

Se o volume de logs for muito alto, aplique o filtro **no lugar** do passo 1:

```bash
# Remover o access log sem filtro
oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found

# Aplicar versão com filtro de health checks
oc apply -f tests/req066/manifests/02-envoyfilter-access-log-filter.yaml
```

---

## Demonstração

### 1. Cenário: chamada pública (sem autenticação)

```bash
FLOW_ID="audit-public-$(date +%s)"
echo "Flow Trace ID: $FLOW_ID"

curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  -H "x-flow-trace-id: $FLOW_ID" \
  https://banking-api.poc.rhcl.com.br/api/echo

sleep 1

echo "--- Access Log (auditoria) ---"
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=50 | grep "$FLOW_ID" | \
  python3 -m json.tool 2>/dev/null || echo "(formato texto — JSON não encontrado)"
```

**Resultado esperado:** Entrada JSON com `flow_trace_id` igual ao valor enviado e `consumer_id: null` (rota pública, sem AuthPolicy).

### 2. Cenário: chamada autenticada (com API Key)

```bash
FLOW_ID="audit-auth-$(date +%s)"
echo "Flow Trace ID: $FLOW_ID"

curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  -H "x-flow-trace-id: $FLOW_ID" \
  -H "api-key: alice-gold-secret" \
  https://banking-api.poc.rhcl.com.br/api/v1/echo

sleep 1

echo "--- Access Log (auditoria) ---"
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=50 | grep "$FLOW_ID" | \
  python3 -m json.tool 2>/dev/null || echo "(formato texto — JSON não encontrado)"
```

**Resultado esperado:** Entrada JSON com `flow_trace_id` igual ao valor enviado e `consumer_id: alice` (identidade do consumidor injetada pelo Authorino).

### 3. Cenário: chamada negada (401 — sem credencial)

```bash
FLOW_ID="audit-denied-$(date +%s)"
echo "Flow Trace ID: $FLOW_ID"

curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  -H "x-flow-trace-id: $FLOW_ID" \
  https://banking-api.poc.rhcl.com.br/api/v1/accounts/summary

sleep 1

echo "--- Access Log (auditoria) ---"
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=50 | grep "$FLOW_ID" | \
  python3 -m json.tool 2>/dev/null || echo "(formato texto — JSON não encontrado)"
```

**Resultado esperado:** Entrada JSON com `flow_trace_id` igual ao valor enviado, `response_code: 401` e `auth_reason` com motivo do denial (ex: `credential not found`).

### 4. Correlação access log ↔ trace distribuído

Este cenário demonstra a **rastreabilidade de ponta a ponta**: o `flow_trace_id` (enviado pelo cliente) localiza a entrada JSON no access log, e de lá extraímos o `request_id` (gerado pelo Envoy) e o `traceparent` para correlacionar com traces e logs de outros componentes.

> **Nota:** O Envoy **sobrescreve** o header `x-request-id` com um UUID próprio. Por isso usamos `x-flow-trace-id` para correlação pelo lado do cliente. O `request_id` no access log é o UUID gerado pelo Envoy e pode ser usado para correlação com traces (req038), Authorino e Limitador.

```bash
FLOW_ID="audit-trace-$(date +%s)"
echo "========================================="
echo " CORRELAÇÃO: Access Log ↔ Trace"
echo " Flow Trace ID: $FLOW_ID"
echo "========================================="

# Enviar request
curl -sk -o /dev/null -w "HTTP %{http_code}\n" \
  -H "x-flow-trace-id: $FLOW_ID" \
  -H "api-key: alice-gold-secret" \
  https://banking-api.poc.rhcl.com.br/api/v1/echo

sleep 2

# 1. Access log (req066) — JSON no stdout do gateway
echo ""
echo "--- 1. ACCESS LOG (req066) ---"
ENVOY_REQUEST_ID=$(oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=100 | grep "$FLOW_ID" | \
  python3 -c "
import sys,json
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        print(json.dumps(d,indent=2,sort_keys=True))
        print()
        print('  → flow_trace_id:', d.get('flow_trace_id','(vazio)'))
        print('  → request_id (Envoy):', d.get('request_id','(vazio)'))
        print('  → traceparent:', d.get('traceparent','(vazio)'))
        print('  → consumer_id:', d.get('consumer_id','(vazio)'))
        import sys as s2; s2.stderr.write(d.get('request_id',''))
    except: pass
" 2>&1 1>/dev/tty)
echo ""
echo "  Envoy request_id capturado: $ENVOY_REQUEST_ID"

# 2. Log do Authorino — correlação via request_id do Envoy
echo ""
echo "--- 2. AUTHORINO LOG (correlação auth) ---"
if [ -n "$ENVOY_REQUEST_ID" ]; then
  oc -n kuadrant-system logs -l app=authorino --tail=200 2>/dev/null | \
    grep "$ENVOY_REQUEST_ID" | head -3 || echo "(não encontrado ou rota sem AuthPolicy)"
else
  echo "(request_id não capturado — busque manualmente)"
fi

# 3. Log do Limitador — correlação rate limit
echo ""
echo "--- 3. LIMITADOR LOG (correlação rate limit) ---"
if [ -n "$ENVOY_REQUEST_ID" ]; then
  oc -n kuadrant-system logs -l app=limitador --tail=200 2>/dev/null | \
    grep "$ENVOY_REQUEST_ID" | head -3 || echo "(não encontrado ou rota sem RateLimitPolicy)"
else
  echo "(request_id não capturado — busque manualmente)"
fi

echo ""
echo "========================================="
echo " Para ver o TRACE distribuído:"
echo " Console OpenShift → Observe → Traces"
echo " TempoStack: tempo-rhcl | Tenant: dev"
echo " Buscar pelo request_id: $ENVOY_REQUEST_ID"
echo "========================================="
```

### 5. Gerar tráfego em massa

```bash
echo "Gerando 20 requests para popular access logs..."
for i in $(seq 1 20); do
  curl -sk -o /dev/null -w "%{http_code} " \
    -H "x-flow-trace-id: audit-batch-$(printf '%03d' $i)" \
    https://banking-api.poc.rhcl.com.br/api/echo
done
echo ""
echo ""
echo "Verificando access logs JSON:"
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=50 | grep "audit-batch" | wc -l
echo "entradas JSON encontradas"
```

---

## Campos do access log (referência)

| Campo | Variável Envoy | Finalidade para auditoria |
|---|---|---|
| `timestamp` | `%START_TIME%` | Data/hora do evento |
| `method` | `%REQ(:METHOD)%` | Verbo HTTP |
| `path` | `%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%` | Endpoint chamado |
| `protocol` | `%PROTOCOL%` | HTTP/1.1 ou HTTP/2 |
| `response_code` | `%RESPONSE_CODE%` | Resultado (200, 401, 429, 5xx) |
| `response_flags` | `%RESPONSE_FLAGS%` | Flags Envoy (NR, UF, UT, etc.) |
| `duration_ms` | `%DURATION%` | Duração total em ms |
| `client_ip` | `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%` | IP do chamador |
| `x_forwarded_for` | `%REQ(X-FORWARDED-FOR)%` | IP original (se via proxy/LB) |
| `user_agent` | `%REQ(USER-AGENT)%` | Identificação do cliente |
| `request_id` | `%REQ(X-REQUEST-ID)%` | **UUID gerado pelo Envoy** (correlação com traces/Authorino) |
| `authority` | `%REQ(:AUTHORITY)%` | Host/domínio chamado |
| `upstream_host` | `%UPSTREAM_HOST%` | Pod que atendeu |
| `upstream_cluster` | `%UPSTREAM_CLUSTER%` | Cluster/service upstream |
| `route_name` | `%ROUTE_NAME%` | HTTPRoute que deu match |
| `traceparent` | `%REQ(TRACEPARENT)%` | **W3C Trace Context — link com trace** |
| `downstream_tls_version` | `%DOWNSTREAM_TLS_VERSION%` | Versão TLS (1.2, 1.3) |
| `downstream_tls_cipher` | `%DOWNSTREAM_TLS_CIPHER%` | Cipher suite negociada |
| `consumer_id` | `%REQ(X-CONSUMER-ID)%` | **Identidade do consumidor** (Authorino) |
| `auth_reason` | `%RESP(X-EXT-AUTH-REASON)%` | **Motivo de denial** (Authorino) |
| `flow_trace_id` | `%REQ(X-FLOW-TRACE-ID)%` | **Trace de negócio** (enviado pelo cliente, não sobrescrito) |

---

## Evidências da POC

| Evidência | Como demonstrar |
|---|---|
| **Access log JSON estruturado** | `oc logs` do gateway mostra entradas JSON para cada request |
| **Identidade do consumidor** | Campo `consumer_id` com nome do consumer (alice, bob, etc.) para rotas autenticadas |
| **Motivo de denial** | Campo `auth_reason` com mensagem do Authorino para requests negados (401/403) |
| **Correlação log ↔ trace** | `request_id` (Envoy UUID) no access log e no trace (Observe → Traces) |
| **Correlação cross-component** | `request_id` (Envoy UUID) nos logs do gateway, Authorino e Limitador |
| **Link W3C Trace Context** | Campo `traceparent` permite saltar diretamente para o trace no Tempo |
| **Auditoria TLS** | Campos `downstream_tls_version` e `downstream_tls_cipher` |
| **Correlação pelo cliente** | `flow_trace_id` — header `x-flow-trace-id` enviado pelo cliente, preservado pelo Envoy |

---

## Troubleshooting

### Access logs JSON não aparecem

1. Verificar se o EnvoyFilter existe:
```bash
oc -n openshift-ingress get envoyfilter access-log-json
```

2. Verificar se o Envoy rejeitou a configuração:
```bash
oc -n openshift-ingress logs deploy/rhcl-apps-gateway-openshift-default \
  -c istio-proxy --tail=20 | grep -i "rejected\|error\|warning"
```

3. Se houver erro `Not supported field in StreamInfo`, o campo referenciado não é suportado nesta versão do Envoy. Remova-o do `json_format`.

### Grep pelo x-request-id customizado não retorna nada

- O Envoy **sobrescreve** o header `x-request-id` com um UUID próprio, mesmo que o cliente envie um valor customizado.
- O campo `request_id` no access log contém o UUID gerado pelo Envoy, **não** o valor enviado pelo cliente.
- Para correlação pelo lado do cliente, use o header `x-flow-trace-id` — ele **não** é sobrescrito pelo Envoy e aparece no campo `flow_trace_id` do access log.
- Para descobrir o `request_id` que o Envoy gerou, capture o header `x-request-id` da **resposta** (`curl -v`).

### Consumer ID aparece como null

- O header `x-consumer-id` é injetado pelo **Authorino** apenas para rotas protegidas por `AuthPolicy`.
- Rotas públicas (sem AuthPolicy) não terão consumer ID.
- Verifique se a AuthPolicy está ativa: `oc -n rhcl-apps get authpolicy`.

### Auth reason aparece vazio

- O header `x-ext-auth-reason` é preenchido apenas quando o Authorino **nega** o request (401/403).
- Para requests autorizados (200), o campo será null/vazio — esperado.

---

## Relação com outros itens

| Item | Relação |
|---|---|
| **req038** | Infraestrutura de tracing (Tempo, Collector, Kuadrant observability) — recomendado para correlação completa |
| **req035** | Log de erros centralizado (complementar — erros via OTLP para arquivo/SIEM) |
| **req041** | Dashboards Grafana — métricas correlacionáveis com access logs |
| **req071** | OIDC/JWT — access logs registram chamadas autenticadas |
| **req072** | IP ACL — `client_ip` e `x_forwarded_for` nos access logs |

---

## Referências

- [Kuadrant — Envoy Access Logs](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/observability/envoy-access-logs/)
- [Kuadrant — Tracing](https://docs.kuadrant.io/1.4.x/kuadrant-operator/doc/observability/tracing/)
- [Envoy — Access Log Format Variables](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)
- [W3C Trace Context — traceparent](https://www.w3.org/TR/trace-context/#traceparent-header)

---

## Limpeza

```bash
bash tests/req066/scripts/cleanup.sh
```

Ou manualmente:

```bash
oc -n openshift-ingress delete envoyfilter access-log-json --ignore-not-found
oc -n openshift-ingress delete envoyfilter access-log-filter --ignore-not-found
```
