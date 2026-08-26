# ledger-api

Microserviço downstream mínimo (Quarkus) usado pela POC do RHCL para demonstrar a
**propagação de traces** (REQ 038). É chamado pelo `banking-api` no endpoint
`/api/test/propagate`; o trace iniciado no gateway flui
`rhcl-gateway → banking-api → ledger-api` sob um único Trace ID.

## Por que não há código OpenTelemetry aqui

A propagação é **configuração RHCL/OTel, não código**:

- O `Deployment` recebe a anotação `instrumentation.opentelemetry.io/inject-java: "true"`,
  então o **OpenTelemetry Operator injeta o agente Java** no pod.
- O CR `Instrumentation` do namespace (`propagators: [tracecontext, baggage]`) faz o agente
  **extrair o `traceparent` de entrada** (propagado pelo banking-api) e **continuar o trace**,
  criando o span server do `ledger-api` automaticamente.

Por isso o `pom.xml` declara apenas `quarkus-rest-jackson` e `quarkus-smallrye-health` — nenhuma
dependência ou API OpenTelemetry.

## Endpoints

| Método | Caminho           | Descrição                                                              |
| ------ | ----------------- | ---------------------------------------------------------------------- |
| `POST` | `/ledger/record`  | Registra um lançamento (trabalho simbólico); ecoa `traceparent`/`traceId`. |
| `GET`  | `/ledger/info`    | Metadados do serviço/instância.                                        |
| `GET`  | `/q/health`       | Health (readiness/liveness) via smallrye-health.                       |

## Build / execução

```bash
# Local
mvn quarkus:dev

# Container (igual ao banking-api): build de imagem via OpenShift BuildConfig
oc start-build bc/ledger-api --from-dir=apps/backend/ledger-api -n rhcl-apps --wait
```

O deploy é feito pelo role Ansible `apps` (gated por `apps_ledger_enabled`, default `true`).
