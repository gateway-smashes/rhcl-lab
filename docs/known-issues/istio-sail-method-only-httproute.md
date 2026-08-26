# HTTPRoute "method-only" trava o data plane do Istio Sail

**Componentes afetados (observado neste lab):**
- Red Hat Connectivity Link 1.3.3
- Istio Sail Operator (versão embarcada no RHCL 1.3.3)
- OpenShift 4.20.23
- Gateway API v1 (`gateway.networking.k8s.io/v1`)

**Status:** workaround estável aplicado no cluster. Causa raiz fica do lado do
data plane do Istio Sail — bug upstream a confirmar/abrir.

---

## Sintoma

HTTPRoute em que **todas** as `rules` declaram `matches:[{path, method}]`
(ou seja, sem nenhuma rule de fallback usando só `PathPrefix`) coloca o
Gateway num estado em que ~95% das conexões TLS travam: o handshake nunca
completa e o `curl` estoura no timeout (30s sem ACK), enquanto ~5% passam
de forma aparentemente aleatória.

Observado no cluster com:
- Gateway: `rhcl-apps-gateway` em `openshift-ingress` (3 réplicas do data plane)
- Hostname: `banking-api-connectivity.apps.<cluster>.<base-domain>`
- HTTPRoute com 7+ rules, todas method-específicas

O problema **persiste após** `oc rollout restart deployment/<gateway-pods>` —
restart do data plane sozinho não resolve. A correção é reconfigurar o
HTTPRoute (adicionar pelo menos uma rule fallback sem `method`).

### Pattern de timeout no `curl`

```
$ for i in 1 2 3 4 5; do
    curl -sk -o /dev/null \
      -w "try=$i  tls=%{time_appconnect}s  total=%{time_total}s  http=%{http_code}\n" \
      -m 30 https://banking-api-connectivity.<host>/api/v1/accounts/summary
  done
try=1  tls=0.000000s  total=30.001s  http=000
try=2  tls=0.000000s  total=30.001s  http=000
try=3  tls=0.243s     total=0.512s   http=200
try=4  tls=0.000000s  total=30.001s  http=000
try=5  tls=0.000000s  total=30.002s  http=000
```

`time_appconnect=0` indica que o handshake TLS **nem começou** — não é
backend lento nem 5xx; é o listener do gateway que para de aceitar a
conexão.

---

## Workaround

**Sempre incluir pelo menos uma rule fallback `PathPrefix` sem `method`** —
mesmo que outras rules cubram explicitamente os mesmos paths com `method`
específico. Estabiliza o gateway imediatamente após `oc apply`.

### Estrutura que QUEBRA

Todas as rules com `method` (exemplo simplificado):

```yaml
rules:
  - matches: [{ path: { type: PathPrefix, value: /api/v1/accounts/summary }, method: GET }]
    backendRefs: [{ name: banking-api-v1, port: 8080 }]
  - matches: [{ path: { type: PathPrefix, value: /api/v2/accounts/summary }, method: GET }]
    backendRefs: [{ name: banking-api-v2, port: 8080 }]
  - matches: [{ path: { type: PathPrefix, value: /api/v1/transfers }, method: POST }]
    backendRefs: [{ name: banking-api-v1, port: 8080 }]
  # ... mais N rules, todas com method
```

### Estrutura que FUNCIONA (10 rules — workaround aplicado)

7 rules method-específicas + **3 rules fallback sem method**:

| # | Path(s) | Method | Backend |
|---|---------|--------|---------|
| 0 | `/api/v1/accounts/summary` | GET | `banking-api-v1` |
| 1 | `/api/v2/accounts/summary` | GET | `banking-api-v2` |
| 2 | `/api/v1/accounts/reset`, `/api/v1/transfers` | POST | `banking-api-v1` |
| 3 | `/api/v2/transfers` | POST | `banking-api-v2` |
| 4 | `/api/v1/chat/completions`, `/api/v1/completions`, `/api/v1/embeddings`, `/api/v1/responses`, `/api/v1/models` | POST/GET | `banking-api-v1` |
| 5 | `/api/whoami`, `/api/echo`, `/api/tls/info`, `/api/test` | GET | `banking-api-v1` |
| 6 | `/api/lb-test` | GET | `banking-api-v1` + `banking-api-v2` (weighted) |
| **7** | `/api/v1` | **(sem method — fallback)** | `banking-api-v1` |
| **8** | `/api/v2` | **(sem method — fallback)** | `banking-api-v2` |
| **9** | `/ws`, `/mcp` | **(sem method — streaming)** | `banking-api-v1` |

YAML completo de referência (gerado durante a estabilização):
`/tmp/rhcl-provision/httproute-final-v2.json` no ambiente de provisão.
Não está versionado no repo porque foi aplicado direto via `oc apply` —
ver "Sequência de aplicação" abaixo.

---

## Caps e regras de design para HTTPRoute neste setup

1. **Sempre** incluir ao menos uma rule fallback `PathPrefix` por bloco
   funcional sem `method`. A regra prática: agrupar rules method-específicas
   sob um "guarda-chuva" PathPrefix mais largo, mesmo que pareça redundante.
2. **Máximo 16 rules por HTTPRoute** — limite duro da própria Gateway API
   (validation rejeita o objeto). Planeje a granularidade antes; consolide
   matches dentro da mesma rule via lista (`matches: [..., ...]`) quando
   compartilharem backend/filters.
3. Streaming (`/ws`, `/mcp`, SSE) **nunca** com method match — eles
   precisam de upgrade HTTP / requests longas que se beneficiam do
   roteamento por prefixo puro.
4. Após qualquer mudança estrutural em HTTPRoute do gateway, validar com a
   sequência de 5 curls acima. Se aparecer `tls=0.000000s` em qualquer
   tentativa, **reverter** e revisitar a presença de fallback rules.

---

## Sequência de aplicação (quando precisar replicar o fix)

```bash
# 1. Salvar o estado atual (rollback)
oc get httproute banking-api-connectivity -n rhcl-apps -o yaml \
  > /tmp/httproute-backup-$(date +%s).yaml

# 2. Aplicar o YAML com fallback rules
oc apply -f /tmp/rhcl-provision/httproute-final-v2.json

# 3. NÃO restartar o data plane — a aplicação do HTTPRoute por si só
#    reprograma os listeners. Restart pode mascarar o resultado.

# 4. Validar com a sequência de 5 curls (ver "Pattern de timeout")
#    Esperado: tls > 0 em todas as 5 tentativas, http=200/4xx (qualquer
#    coisa que não seja 000).
```

---

## Atualização da automação (`automation/roles/apps/templates/`)

O template atual da automação — [`connectivity-httproute.yml.j2`](../../automation/roles/apps/templates/connectivity-httproute.yml.j2)
— **já está seguro**: todas as rules são `PathPrefix` puro, sem `method`.

Ação requerida: **manter assim**. Antes de qualquer refactor que
introduza `method` matches no template:

1. Garantir que pelo menos uma rule `PathPrefix` sem method continue
   cobrindo cada prefixo de path do template (`/api/v1`, `/api/v2`,
   `/api/echo`, `/api/whoami` se JWT, `/api/lb-test` se lb_test,
   `/ws`, `/mcp`).
2. Rodar a sequência de validação dos 5 curls após o `oc apply` em lab.
3. Vincular este doc no PR.

Se a granularidade exigida pela feature passar de 13–14 rules, parar e
revisitar — o cap de 16 da Gateway API deixa pouca margem para crescer.

---

## Issue upstream

A abrir (ainda não verificado se já existe):
- Repositório candidato 1: https://github.com/istio-ecosystem/sail-operator
- Repositório candidato 2: https://github.com/istio/istio (caso a causa
  esteja no data plane do Istio puro, não no operator)
- Verificar antes em https://github.com/Kuadrant/kuadrant-operator se já
  há report relacionado a HTTPRoute method match no contexto RHCL.

Reprodução mínima a anexar no issue:
- Versões: Istio Sail Operator embarcado em RHCL 1.3.3 / OCP 4.20.23
- Manifesto Gateway + 2 HTTPRoutes (broken vs working) baseados na
  estrutura acima
- Output dos 5 curls em cada estado
- `kubectl get httproute -o yaml` de ambos
- Logs do gateway pod no momento da falha (sem nada útil no caso
  observado — daí a importância do test pattern do `curl`)
