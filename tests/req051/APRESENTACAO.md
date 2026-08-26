# REQ 051 + 056 — Apresentação: mTLS no Gateway (PoC)

## Visão Geral

Esta solução demonstra a imposição de **mutual TLS (mTLS)** no nível do Gateway
usando OpenShift Service Mesh 3.x (Istio) com Gateway API. Dois modelos de
confiança são validados simultaneamente no mesmo Gateway:

- **REQ 056** — Exposição de APIs via mTLS com validação por **CA única** (Intermediária)
- **REQ 051** — Fechamento de mTLS por **cadeia de certificados** (Root CA)

---

## Arquitetura

```
                        *.<dominio> (wildcard DNS)
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  Default OpenShift Router (HAProxy)                  │
│                                                                     │
│   Route: req056-mtls-passthrough  ──┐                               │
│   Route: req051-mtls-passthrough  ──┤  TLS Passthrough              │
│                                     │  (não inspeciona o TLS)       │
└─────────────────────────────────────┼───────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│              Gateway Pod (Envoy / Istio) — namespace req051-gateway  │
│                                                                     │
│   Listener: 0.0.0.0:443                                            │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │ Filter Chain [SNI: req056-mtls.*]  ← REQ 056             │ │
│   │   • require_client_certificate: true                          │ │
│   │   • trusted_ca: /etc/certs/intermediate-ca/ca.crt             │ │
│   │   • Aceita APENAS certs assinados pela CA Intermediária       │ │
│   ├───────────────────────────────────────────────────────────────┤ │
│   │ Filter Chain [SNI: req051-mtls.*]  ← REQ 051             │ │
│   │   • require_client_certificate: true                          │ │
│   │   • trusted_ca: /etc/certs/root-ca/ca.crt                    │ │
│   │   • Aceita certs cuja cadeia termina na Root CA               │ │
│   └───────────────────────────────────────────────────────────────┘ │
│                              │                                      │
│                              ▼ HTTPRoute                            │
│                     banking-api-v1:8080 (namespace rhcl-apps)       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Hierarquia de Certificados

```
Root CA (CN=RHCL PoC Root CA) — auto-assinada
 └── Intermediate CA (CN=RHCL PoC Intermediate CA) — assinada pela Root
      ├── Server cert (SAN=req051-mtls.*, req056-mtls.*)
      ├── client-chain.crt (CN=banking-client-chain, assinado pela Intermediária)
      ├── client-chain-bundle.crt (leaf + intermediate juntos no mesmo PEM)
      └── client-direct.crt (CN=banking-client-direct, assinado pela Root)

Untrusted CA (CN=Untrusted External CA) — auto-assinada, sem relação
 └── client-untrusted.crt (CN=untrusted-client)
```

---

## Descrição dos Arquivos

### `generate-certs.sh`

Gera toda a infraestrutura de chave pública (PKI) necessária para o PoC. Cria
a Root CA, a Intermediate CA, o certificado do servidor (com SANs para ambos os
hostnames), três certificados de cliente (um assinado pela Intermediária, um
assinado pela Root, e um de CA desconhecida) e as chaves privadas
correspondentes. Tudo é gerado localmente com `openssl` e depositado na pasta
`certs/`, que é git-ignored. A execução requer apenas a variável
`RHCL_ZONE_ROOT_DOMAIN` para definir os SANs.

### `00-namespace.yaml`

Cria o namespace `req051-gateway` onde todos os recursos do mTLS gateway serão
implantados (Gateway, Secrets, EnvoyFilter, HTTPRoutes). O namespace é isolado
do restante da aplicação para manter a separação de responsabilidades.

### `10-gateway.yaml`

Define o recurso Gateway (API `gateway.networking.k8s.io/v1`) com a
GatewayClass `openshift-default` (que é gerenciada pelo Istio no Service Mesh
3.x). Declara dois listeners HTTPS na porta 443 — um para cada hostname
(`req056-mtls` e `req051-mtls`). A terminação TLS do servidor é feita aqui
(referenciando o Secret `req051-server-tls`), porém a validação do certificado
de cliente **não** é configurada neste recurso — isso é delegado ao EnvoyFilter
porque o CRD do Gateway API na channel standard não inclui o campo experimental
`frontendValidation`.

### `deploy-envoyfilter.sh` (template: `15-envoyfilter-mtls.yaml`)

Gera e aplica dois recursos EnvoyFilter que fazem o patch do transport socket
TLS em cada filter chain do listener `0.0.0.0_443`. Cada EnvoyFilter é
direcionado a uma filter chain específica via match de SNI e configura:
`require_client_certificate: true` e `validation_context.trusted_ca` apontando
para o arquivo PEM da CA confiável (montado como volume a partir de um Secret).
O script usa Python para gerar JSON válido (evitando problemas com PEM
multi-linha em YAML) e aplica via `oc apply -f -`.

### `20-httproute.yaml`

Define dois HTTPRoutes — um para cada listener/hostname — que encaminham
requisições com prefixo `/api` para o Service `banking-api-v1` na namespace
`rhcl-apps`. Cada HTTPRoute referencia o listener correto via `sectionName` e
o hostname correspondente.

### `25-referencegrant.yaml`

Recurso ReferenceGrant implantado na namespace `rhcl-apps` que autoriza os
HTTPRoutes da namespace `req051-gateway` a referenciar Services na namespace
`rhcl-apps`. Sem este recurso, o Gateway API rejeita referências
cross-namespace por segurança.

### `30-passthrough-routes.yaml`

Cria duas OpenShift Routes com `tls.termination: passthrough`. O DNS wildcard
`*.<dominio>` aponta para o router default do OpenShift (HAProxy). Estas
Routes instruem o router a encaminhar a conexão TLS criptografada — sem
inspecionar ou terminar — diretamente para o nosso Service do Gateway. Assim,
o handshake mTLS completo é realizado pelo Envoy do nosso Gateway, não pelo
router.

### `deploy.sh`

Script orquestrador que executa todos os passos do deploy na ordem correta:
cria o namespace, os Secrets (servidor TLS + CAs), aplica o Gateway, aguarda o
deployment ficar pronto, faz o patch do deployment para montar os Secrets de CA
como volumes, aplica os EnvoyFilters, cria os HTTPRoutes, ReferenceGrant e as
passthrough Routes. É idempotente — pode ser executado múltiplas vezes sem
efeitos colaterais (usa `--dry-run=client -o yaml | oc apply`).

---

## Verificação

### Pré-requisitos

```bash
export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
CERTS=tests/req051/manifests/certs

# IP do router default do OpenShift (onde o hostname resolve)
# Obtenha via: dig +short *.$RHCL_ZONE_ROOT_DOMAIN | head -1
GW_IP=<informar_ip_aqui>
```

---

### REQ 056 — Single-CA (confia apenas na CA Intermediária)

#### Teste 1 — PASS: certificado assinado pela CA Intermediária

Este curl apresenta ao gateway um certificado de cliente que foi assinado
diretamente pela CA Intermediária. Como o listener `https-single-ca` confia
exclusivamente nessa CA (montada em `/etc/certs/intermediate-ca/ca.crt`), o
handshake TLS mútuo é bem-sucedido e o gateway encaminha a requisição ao
backend `banking-api-v1`, retornando HTTP 200.

```bash
HOST=req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-chain.crt --key $CERTS/client-chain.key \
  "https://$HOST/api/tls/info"
```

#### Teste 2 — FAIL: certificado assinado pela Root CA

Este curl apresenta um certificado de cliente que foi assinado diretamente pela
Root CA. Apesar de a Root CA ser "mãe" da Intermediária na hierarquia PKI, o
listener `https-single-ca` confia **apenas** na CA Intermediária — ele não sobe
a cadeia. Como o certificado não foi emitido pela CA configurada como trust
anchor, o Envoy rejeita o handshake TLS e a conexão é fechada.

```bash
HOST=req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://$HOST/api/tls/info"
```

#### Teste 3 — FAIL: certificado de CA desconhecida

Este curl apresenta um certificado emitido por uma CA completamente externa e
sem relação com a hierarquia do PoC ("Untrusted External CA"). O gateway não
reconhece essa CA em nenhum dos seus trust stores, então o handshake mTLS falha
imediatamente, provando que certificados de terceiros não autorizados são
barrados.

```bash
HOST=req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://$HOST/api/tls/info"
```

#### Teste 4 — FAIL: sem certificado de cliente

Este curl não envia nenhum certificado de cliente. Como o EnvoyFilter configurou
`require_client_certificate: true`, o gateway exige que o cliente se
identifique. Sem certificado, o Envoy rejeita a conexão durante o handshake
TLS, demonstrando que acesso anônimo (sem mTLS) é bloqueado.

```bash
HOST=req056-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  "https://$HOST/api/tls/info"
```

---

### REQ 051 — Chain-CA (confia na Root CA, aceita cadeia)

#### Teste 5 — PASS: certificado com cadeia completa (bundle)

Este curl apresenta o certificado de cliente (assinado pela CA Intermediária)
junto com o certificado da própria CA Intermediária no bundle — formando a
cadeia `leaf → intermediate → root`. O listener `https-chain-ca` confia na
Root CA, então o Envoy percorre a cadeia: valida que a Intermediária foi
assinada pela Root, e que o leaf foi assinado pela Intermediária. A cadeia é
válida, o handshake passa e a requisição chega ao backend com HTTP 200.

```bash
HOST=req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-chain-bundle.crt --key $CERTS/client-chain.key \
  "https://$HOST/api/tls/info"
```

#### Teste 6 — PASS: certificado assinado diretamente pela Root CA

Este curl apresenta um certificado que foi assinado diretamente pela Root CA
(sem intermediária no meio). Como o listener confia na Root CA e o certificado
foi emitido por ela, a validação é direta — não precisa percorrer cadeia
nenhuma. O handshake mTLS é aceito e o backend responde normalmente.

```bash
HOST=req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-direct.crt --key $CERTS/client-direct.key \
  "https://$HOST/api/tls/info"
```

#### Teste 7 — FAIL: certificado de CA desconhecida

Mesmo teste que o Teste 3, porém contra o listener da Root CA. O certificado
foi emitido por uma CA que não faz parte da hierarquia confiável (nem é a Root,
nem a Intermediária). A cadeia de confiança não pode ser construída até a Root
CA configurada, então o Envoy rejeita o handshake.

```bash
HOST=req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  --cert $CERTS/client-untrusted.crt --key $CERTS/client-untrusted.key \
  "https://$HOST/api/tls/info"
```

#### Teste 8 — FAIL: sem certificado de cliente

Mesmo cenário do Teste 4, agora contra o listener `https-chain-ca`. Sem
apresentar um certificado, o cliente é rejeitado porque o
`require_client_certificate: true` está ativo. Comprova que ambos os listeners
exigem autenticação mútua, independentemente do modelo de trust.

```bash
HOST=req051-mtls.${RHCL_ZONE_ROOT_DOMAIN}
curl -v --cacert $CERTS/root-ca.crt \
  --resolve "$HOST:443:$GW_IP" \
  "https://$HOST/api/tls/info"
```

---

## Matriz de Validação

| # | Listener | Certificado | Esperado |
|---|----------|-------------|----------|
| 1 | `https-single-ca` (REQ 056) | `client-chain.crt` (Intermediária) | **PASS** — HTTP 200 |
| 2 | `https-single-ca` (REQ 056) | `client-direct.crt` (Root) | **FAIL** — TLS rejeitado |
| 3 | `https-single-ca` (REQ 056) | `client-untrusted.crt` (externa) | **FAIL** — TLS rejeitado |
| 4 | `https-single-ca` (REQ 056) | (nenhum) | **FAIL** — TLS rejeitado |
| 5 | `https-chain-ca` (REQ 051) | `client-chain-bundle.crt` (cadeia) | **PASS** — HTTP 200 |
| 6 | `https-chain-ca` (REQ 051) | `client-direct.crt` (Root) | **PASS** — HTTP 200 |
| 7 | `https-chain-ca` (REQ 051) | `client-untrusted.crt` (externa) | **FAIL** — TLS rejeitado |
| 8 | `https-chain-ca` (REQ 051) | (nenhum) | **FAIL** — TLS rejeitado |

---

## Resposta Esperada (em caso de sucesso)

```json
{
  "instance": "banking-api-v1",
  "timestamp": "2026-06-30T19:50:08.010Z",
  "scheme": "http",
  "isSSL": false,
  "forwardedProto": "https",
  "alpn": "HTTP_1_1",
  "note": "Request was not TLS-terminated by this JVM (plain HTTP or TLS terminated upstream by the gateway)."
}
```

O campo `forwardedProto: "https"` confirma que a requisição atravessou TLS no
gateway. A imposição de mTLS é comprovada pela rejeição de clientes sem
certificado ou com certificado inválido.

---

## Script Interativo de Testes

Para executar os testes de forma guiada e visual:

```bash
cd tests/req051/manifests
./test-mtls.sh <GW_IP>           # menu interativo
./test-mtls.sh <GW_IP> 5         # executa apenas o teste 5
./test-mtls.sh <GW_IP> A         # executa todos os testes
```

O script mostra a descrição de cada teste, o comando que será executado, o
resultado esperado, e um veredicto colorido no terminal.
