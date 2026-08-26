# REQ 054 — Runbook: Consumir backends em HTTP/1.1, HTTP/2 e HTTP/3

Passo-a-passo completo para demonstrar o item 54 da POC: "Consumir backends em HTTP/1.1, HTTP/2 e HTTP/3".

---

## O que este item demonstra

O RHCL/Kuadrant (via Istio/Envoy) suporta comunicação com backends (upstream) usando **HTTP/1.1** e **HTTP/2**. A versão do protocolo utilizada na conexão **gateway → backend** é controlada pelo campo `appProtocol` do Kubernetes Service.

| Protocolo upstream | Configuração | Status |
|---|---|---|
| **HTTP/1.1** | Padrão (sem configuração adicional) | GA — totalmente suportado |
| **HTTP/2 (h2c)** | `appProtocol: kubernetes.io/h2c` no Service | GA — totalmente suportado |
| **HTTP/3 (QUIC)** | Não configurável | **Não suportado** para upstream |

### Direção avaliada

```text
                     req054 (este)                    req057
                  ┌───────────────┐              ┌───────────────┐
 Cliente ──────► │   Gateway     │ ──────────► │   Backend     │
                  │   (Envoy)     │              │   (Pod)       │
                  └───────────────┘              └───────────────┘
                     downstream                     upstream
                  (req057 avalia                  (req054 avalia
                   esta conexão)                  esta conexão)
```

---

## HTTP/3 — Limitação documentada

O HTTP/3 (baseado em QUIC/UDP) **não é suportado** para conexões upstream (gateway → backend):

1. **Arquitetura Istio:** O tráfego interno do mesh sempre usa TCP. O Envoy conecta-se aos backends via HTTP/1.1 ou HTTP/2 sobre TCP. QUIC é suportado **apenas no ingress** (cliente → gateway).

2. **OSSM 3.x — protocolos suportados oficialmente:**
   ```
   Protocols: HTTP1.1/HTTP2/HTTPS/gRPC/TCP/TLS
   ```
   HTTP/3 não está na lista de protocolos suportados pelo Red Hat OpenShift Service Mesh.

3. **Envoy proxy:** Não implementa QUIC como protocolo upstream. Mesmo upstream Istio só suporta QUIC no listener do ingress gateway.

4. **Justificativa técnica:** HTTP/3 foi projetado para redes instáveis (mobile, alta latência). Em rede interna de data center, HTTP/2 sobre TCP já oferece multiplexing e compressão de headers sem o overhead de estabelecimento de conexão QUIC.

**Conclusão para a POC:** O RHCL atende **parcialmente** este requisito — HTTP/1.1 e HTTP/2 são totalmente suportados para comunicação com backends. HTTP/3 não é suportado para conexões upstream por limitação arquitetural do Istio/Envoy e não consta na matriz de suporte do OSSM.

---

## Pré-requisitos

| Componente | Verificação |
|---|---|
| OpenShift 4.21+ | `oc version` |
| RHCL / Kuadrant instalado | `oc get kuadrant -n kuadrant-system` |
| Gateway do RHCL ativo | `oc -n openshift-ingress get gateway` |
| Pods banking-api-v1 running | `oc -n rhcl-apps get pods -l app=banking-api-v1` |
| Acesso cluster-admin | `oc whoami` |
| `curl` (qualquer versão recente) | `curl --version` |

---

## Variáveis de ambiente

```bash
# O hostname é detectado automaticamente pelo script.
# Para override manual:
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export HOST="req054-backend.${CLUSTER_DOMAIN}"
```

---

## Abordagem técnica

Os backends de req054 **reutilizam os pods `banking-api-v1`** já existentes no namespace `rhcl-apps`. A demonstração cria apenas **Services adicionais** com `appProtocol` diferente:

| Service | appProtocol | Protocolo upstream |
|---|---|---|
| `req054-backend-http11` | (vazio) | HTTP/1.1 — padrão do Envoy |
| `req054-backend-h2c` | `kubernetes.io/h2c` | HTTP/2 cleartext |

Ambos apontam para os mesmos pods (`selector: app: banking-api-v1`). A diferença é exclusivamente no `appProtocol`, que instrui o Envoy a usar protocolos diferentes no upstream.

---

## Deploy (via scripts)

### Método recomendado

```bash
# Aplica automaticamente (detecta domínio, cria Services, listener, HTTPRoute, AuthPolicy)
bash tests/req054/scripts/apply.sh
```

O script:
1. Detecta o domínio do cluster (`CLUSTER_DOMAIN`)
2. Cria os Services `req054-backend-http11` e `req054-backend-h2c` no namespace `rhcl-apps`
3. Adiciona um listener `req054-http` ao gateway com hostname `req054-backend.<CLUSTER_DOMAIN>`
4. Aplica o HTTPRoute com path routing (`/http11` → http11, `/h2` → h2c)
5. Aplica uma AuthPolicy `req054-allow-public` para permitir acesso público

### Override do domínio

```bash
export CLUSTER_DOMAIN="apps.ocp.xxx.sandboxNNNN.opentlc.com"
bash tests/req054/scripts/apply.sh
```

---

## Deploy (via automação Ansible)

O req054 está integrado na automação e é habilitado por padrão. O Ansible:
- Resolve o hostname automaticamente (`req054-backend.<apps_effective_dns_suffix>`)
- Adiciona o listener condicional ao gateway
- Cria os Services e HTTPRoute
- Aplica a AuthPolicy

```bash
cd automation
ansible-playbook playbooks/apps-install.yml
```

Variáveis de controle (em `group_vars/all.yml` ou via env):
- `APPS_REQ054_ENABLED` — habilita/desabilita (default: `true`)
- `APPS_REQ054_ROUTE_HOSTNAME` — override do hostname (default: `req054-backend.<domain>`)
- `APPS_REQ054_ROUTE_NAME` — nome da rota (default: `req054-backend`)

---

## Validação

### 1. Backend HTTP/1.1

O Envoy conecta ao backend usando HTTP/1.1 (comportamento padrão quando o Service não tem `appProtocol`).

```bash
curl -sv http://$HOST/http11/api/v1/accounts/summary 2>&1 | grep -E "HTTP/|< "
```

**Resultado esperado:**
- Resposta 200 do backend.
- A conexão gateway→backend usa HTTP/1.1.

### 2. Backend HTTP/2 (h2c)

O Envoy conecta ao backend usando HTTP/2 cleartext porque o Service tem `appProtocol: kubernetes.io/h2c`.

```bash
curl -sv http://$HOST/h2/api/v1/accounts/summary 2>&1 | grep -E "HTTP/|< "
```

**Resultado esperado:**
- Resposta 200 do backend.
- O gateway se comunica com o backend via HTTP/2 (h2c) internamente.

### 3. Verificar appProtocol nos Services

```bash
echo "=== Service HTTP/1.1 (sem appProtocol) ==="
oc -n rhcl-apps get svc req054-backend-http11 -o jsonpath='{.spec.ports[*]}' | python3 -m json.tool

echo ""
echo "=== Service HTTP/2 (com appProtocol: kubernetes.io/h2c) ==="
oc -n rhcl-apps get svc req054-backend-h2c -o jsonpath='{.spec.ports[*]}' | python3 -m json.tool
```

**Resultado esperado:**
```json
// req054-backend-http11 — sem appProtocol
{"name": "http", "port": 8080, "protocol": "TCP", "targetPort": 8080}

// req054-backend-h2c — com appProtocol
{"name": "http2", "port": 8080, "protocol": "TCP", "targetPort": 8080, "appProtocol": "kubernetes.io/h2c"}
```

### 4. Verificar configuração do Envoy (cluster upstream)

Para confirmar que o Envoy realmente usa HTTP/2 para o cluster do backend-h2c:

```bash
GW_NS="openshift-ingress"
GW_NAME=$(oc -n "$GW_NS" get gateway -o custom-columns=NAME:.metadata.name --no-headers | head -1)
GW_POD=$(oc -n "$GW_NS" get pods -l "gateway.networking.k8s.io/gateway-name=$GW_NAME" -o name | head -1)

oc -n "$GW_NS" exec $GW_POD -c istio-proxy -- \
  pilot-agent request GET /config_dump 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for config in data.get('configs', []):
    if 'dynamic_active_clusters' in config:
        for cluster in config['dynamic_active_clusters']:
            name = cluster.get('cluster', {}).get('name', '')
            if 'req054' in name and 'h2c' in name:
                proto = cluster.get('cluster', {}).get('typed_extension_protocol_options', {})
                print(f'Cluster: {name}')
                print(f'Protocol options: {json.dumps(proto, indent=2)}')
                print()
" 2>/dev/null || echo "(aguarde o pod do gateway estar pronto)"
```

**Resultado esperado:** O cluster upstream do `req054-backend-h2c` terá `typed_extension_protocol_options` configurado com `envoy.extensions.upstreams.http.v3.HttpProtocolOptions` indicando HTTP/2.

### 5. Verificar via access log do gateway

```bash
curl -s http://$HOST/http11/api/v1/accounts/summary > /dev/null
curl -s http://$HOST/h2/api/v1/accounts/summary > /dev/null
sleep 2

GW_NS="openshift-ingress"
GW_DEPLOY=$(oc -n "$GW_NS" get deploy -l "gateway.networking.k8s.io/gateway-name" --no-headers -o custom-columns=NAME:.metadata.name | head -1)
oc -n "$GW_NS" logs "deploy/$GW_DEPLOY" -c istio-proxy --tail=50 | grep "req054-backend" | tail -5
```

### 6. Script de validação automatizada

```bash
bash tests/req054/scripts/validate.sh
```

---

## Resumo da demonstração

| Teste | Path | Backend Service | Protocolo upstream | Evidência |
|-------|------|---------|-------------------|-----------|
| HTTP/1.1 | `/http11/*` | `req054-backend-http11` | HTTP/1.1 | Service sem `appProtocol`; Envoy config dump mostra HTTP/1.1 |
| HTTP/2 (h2c) | `/h2/*` | `req054-backend-h2c` | HTTP/2 | Service com `appProtocol: kubernetes.io/h2c`; Envoy config dump mostra HTTP/2 |
| HTTP/3 | — | — | Não suportado | Documentação OSSM; não há configuração possível |

---

## Notas técnicas

- **appProtocol vs nome da porta:** O Istio usa duas formas para detectar o protocolo upstream:
  1. `appProtocol` no Service (preferido, padrão Kubernetes)
  2. Prefixo no nome da porta (ex: `http2-xxx`, `grpc-xxx`) — método legado

- **h2c vs h2:** `h2c` = HTTP/2 cleartext (sem TLS). `h2` = HTTP/2 com TLS. Para comunicação interna no mesh (gateway → pod), usa-se `h2c` porque o mTLS é gerenciado pelo sidecar/waypoint, não pela aplicação.

- **DestinationRule alternativa:** Em vez de `appProtocol`, pode-se usar um `DestinationRule` com `trafficPolicy.connectionPool.http.h2UpgradePolicy: UPGRADE`. O efeito é o mesmo, mas `appProtocol` é o método preferido por ser nativo do Kubernetes.

- **HTTP/3 somente no ingress:** Se o requisito for demonstrar HTTP/3 no sentido **cliente → gateway**, veja o [req057](../req057.md) que cobre esse cenário com `alt-svc` header e QUIC no listener.

- **Reutilização de pods:** Os Services req054 apontam para os pods `banking-api-v1` existentes. Não há Deployments dedicados — a demonstração se concentra no `appProtocol` do Service.

---

## Troubleshooting

### HTTPRoute não aceito (Accepted=False)

1. Verificar se o listener `req054-http` existe no gateway:
```bash
oc -n openshift-ingress get gateway -o jsonpath='{.items[0].spec.listeners[*].name}' | tr ' ' '\n' | grep req054
```

2. Verificar se o hostname do listener corresponde ao HTTPRoute:
```bash
oc -n openshift-ingress get gateway -o jsonpath='{.items[0].spec.listeners[?(@.name=="req054-http")].hostname}'
```

### Backend retorna 503

Os pods banking-api-v1 podem não estar prontos:
```bash
oc -n rhcl-apps get pods -l app=banking-api-v1
```

### Envoy não usa HTTP/2 para o backend h2c

Verificar se o `appProtocol` está setado:
```bash
oc -n rhcl-apps get svc req054-backend-h2c -o yaml | grep appProtocol
```

Se estiver correto mas o Envoy não está respeitando, aguardar o xDS sync (~15s) e verificar o config_dump.

### Timeout nas requisições

Verificar se o gateway pod está Running:
```bash
GW_NS="openshift-ingress"
oc -n "$GW_NS" get pods -l "gateway.networking.k8s.io/gateway-name"
```

Verificar DNS/resolução:
```bash
nslookup "$HOST"
# Se DNS não resolve, testar com --resolve:
GW_IP=$(oc -n openshift-ingress get svc -l "gateway.networking.k8s.io/gateway-name" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
  oc -n openshift-ingress get svc -l "gateway.networking.k8s.io/gateway-name" \
  -o jsonpath='{.items[0].spec.clusterIP}')
curl -sv --resolve "${HOST}:80:${GW_IP}" "http://${HOST}/http11/api/v1/accounts/summary"
```

---

## Limpeza

```bash
bash tests/req054/scripts/cleanup.sh
```

Ou manualmente:
```bash
oc -n rhcl-apps delete authpolicy req054-allow-public --ignore-not-found
oc -n rhcl-apps delete httproute req054-http-versions --ignore-not-found
oc -n rhcl-apps delete svc req054-backend-http11 req054-backend-h2c --ignore-not-found
# Remover listener do gateway (ver cleanup.sh para lógica completa)
```

---

## Referências

- [Kubernetes — Service appProtocol](https://kubernetes.io/docs/concepts/services-networking/service/#application-protocol)
- [Istio — Protocol Selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/)
- [RHCL 1.3 — Gateway Policies](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3/html/configuring_and_deploying_gateway_policies/rhcl-config-deploy-gateway-policies)
- [OSSM 3.x — Feature Support Tables](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/release_notes/ossm-release-notes-feature-support-tables)
- [Istio Wiki — HTTP/3 experimental (ingress only)](https://github.com/istio/istio/wiki/Experimental-QUIC-and-HTTP-3-support-in-Istio-gateways)
- [Envoy — HTTP/2 upstream](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_connection_management)
