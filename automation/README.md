# RHCL Ansible Automation

Ansible automation for installing **Red Hat Connectivity Link (RHCL / Kuadrant)** on OpenShift `4.19+`. Cobre Gateway API, cert-manager, ClusterIssuer (Let's Encrypt ou auto-emitido), DNS provider (AWS / Azure / GCP), monitoring opcional, MCP Gateway, e a sample app (`banking-api` + `mobile-bank`).

> ✅ **Esta automação instala a última RHCL do canal `stable` (1.4.1+) por
> padrão.** O 1.4.0 foi depreciado pela Red Hat (regressão no data plane do
> gateway — todo request retornava `000`); o **1.4.1 corrige o problema**,
> validado em 2026-07-08 em cluster limpo (detalhes em
> [`docs/known-issues/rhcl-14-gateway-wasm-incompat.md`](../docs/known-issues/rhcl-14-gateway-wasm-incompat.md)).
> O pin 1.3.4 continua disponível para reproduzir ambientes de cliente em
> 1.3.x — exporte `RHCL_PIN_V13_ENABLED=true` (procure `rhcl_pin_v13_enabled`
> em [`inventories/example/group_vars/all.yml`](inventories/example/group_vars/all.yml)).

---

## Quick reference

Pra ir direto pro ponto, escolhe o cenário:

| Cenário | Vai pra... |
|---|---|
| Instalação de cluster novo Red Hat (sandbox/AWS) com tudo | [Cenário A — Lab Red Hat com AWS Route53 + Let's Encrypt](#cenário-a-—-lab-red-hat-com-aws-route53--lets-encrypt) |
| Só preciso da lista completa de variáveis | [Referência completa de variáveis](#referência-completa-de-variáveis) |
| Quero entender a ordem dos playbooks | [Ordem de execução](#ordem-de-execução) |

---

## Discovery automático com `cluster-env.sh`

Em vez de exportar cada variável manualmente, use o script
[`scripts/cluster-env.sh`](scripts/cluster-env.sh) — ele descobre os valores do
cluster atual via `oc` e aplica os defaults corretos por perfil:

```bash
source automation/scripts/cluster-env.sh
```

**Auto-detecta o perfil:**

| Perfil | Sinais | Defaults aplicados |
|---|---|---|
| `aws-lab` | `Infrastructure.status.platform=AWS` ou cluster `*.opentlc.com` | `APPS_IMAGE_SOURCE=build`, `GATEWAY_SERVICE_TYPE=LoadBalancer`, `ELB_ANNOTATIONS=true`, `DNS_INGRESS=false` |
| `other` | Nada acima detectado | Só discovery, sem ajustes |

**Forçar perfil manualmente** (se a auto-detecção errar):

```bash
source automation/scripts/cluster-env.sh --profile=aws    # força AWS lab
```

**Credenciais** (chaves AWS, email LE, etc.) ficam num arquivo separado, **não commitado**:

```bash
# Template
cp automation/scripts/cluster-secrets.sh.example ~/cluster-secrets.sh
chmod 600 ~/cluster-secrets.sh
$EDITOR ~/cluster-secrets.sh    # descomenta seu provider, preenche creds

# Próximo source do cluster-env.sh carrega automaticamente
source automation/scripts/cluster-env.sh
```

O script procura `cluster-secrets.sh` em duas localizações (na ordem):
1. `~/cluster-secrets.sh` (user-scoped — vale pra qualquer repo)
2. `automation/cluster-secrets.sh` (project-scoped — já está no `.gitignore`)

**Output (cluster sandbox AWS, exemplo):**

```
[cluster-env] Cluster: cluster-xyz.sandbox.opentlc.com (user: kube:admin)
[cluster-env] Perfil: aws-lab (platform=AWS ou cluster .opentlc.com)
[cluster-env]   RHCL_ZONE_ROOT_DOMAIN=apps.cluster-xyz.sandbox.opentlc.com
[cluster-env]   APPS_CONNECTIVITY_TLS_ISSUER_NAME=letsencrypt-production-ec2
[cluster-env]   GATEWAY_API_GATEWAYCLASS_NAME=openshift-default
[cluster-env]   RHCL_DNS_PROVIDER=aws (region=us-east-2)
[cluster-env] === Aplicando defaults do perfil AWS LAB ===
[cluster-env]   APPS_IMAGE_SOURCE=build
[cluster-env]   ...
```

Depois é só `cd automation && ansible-playbook playbooks/...-install.yml` — todas as envs estão setadas.

---

## Pré-requisitos

- **Ansible** com a collection `kubernetes.core` instalada:
  ```bash
  cd automation
  ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ansible-galaxy collection install -r collections/requirements.yml
  ```
- `oc` (ou `kubectl`) com `kubeconfig` já autenticado contra o cluster destino
- **Cluster-admin** no OpenShift destino
- OpenShift `4.19+`
- Python 3 + libs Python pro `kubernetes.core`:
  ```bash
  python3 -m pip install --user kubernetes openshift jmespath pyyaml
  ```

---

## Layout do diretório

```
automation/
├── ansible.cfg                       # config local do Ansible
├── collections/requirements.yml      # collections necessárias
├── inventories/example/
│   ├── inventory.yml                 # inventário sample
│   └── group_vars/all.yml            # ★ TODOS os defaults (~155 vars)
├── playbooks/                        # entrypoints (install/remove/test por componente + aggregate)
├── roles/                            # gateway_api, cert_manager, rhcl, coredns,
│                                       dns, letsencrypt, apps, monitoring, mcp_gateway
└── README_TEST_INSTALLATION_*.md     # guias por componente
```

---

## Ordem de execução

Cada playbook depende dos anteriores. Em **clusters limpos**, rodar nessa sequência:

```
gateway_api-install  →  cert_manager-install  →  rhcl-install  →  coredns-install
                                                                       ↓
            (opcional) dns-install  →  (opcional) letsencrypt-install
                                                                       ↓
                       (opcional) monitoring-install
                                                                       ↓
                                  apps-install
                                                                       ↓
                       (opcional) mcp_gateway-install
```

### Quando rodar cada opcional

| Playbook | Condição |
|---|---|
| `dns-install.yml` | Vai criar `DNSPolicy` da Kuadrant (registra records DNS em provider externo) |
| `letsencrypt-install.yml` | Quer HTTPS no Gateway via cert-manager + DNS01 challenge ACME |
| `monitoring-install.yml` | Quer Prometheus do OpenShift coletando `ServiceMonitor`/`PodMonitor` (UWM) |
| `mcp_gateway-install.yml` | Quer expor MCP servers no Gateway (item 59 do PoC) |
| `ocp_ai-install.yml` | Installs OpenShift AI 3.4 lab profile (KServe, Models as a Service, llm-d, Ray/distributed workloads, Llama Stack). Toggle `OCP_AI_ENABLED=true`. See [README_TEST_INSTALLATION_OCP_AI.md](README_TEST_INSTALLATION_OCP_AI.md). |

> ⚠️ **`letsencrypt-install.yml` precisa rodar ANTES de `apps-install.yml`** quando `APPS_CONNECTIVITY_TLS_ENABLED=true`. Caso contrário a TLSPolicy fica em loop esperando o issuer.

### Aggregate

```bash
cd automation
ansible-playbook playbooks/install-all.yml    # tudo em ordem (recomendado)
ansible-playbook playbooks/test-all.yml       # valida tudo em ordem
ansible-playbook playbooks/remove-all.yml     # remove em ordem reversa
```

`install-all.yml` aplica nesta ordem:
1. `gateway_api-install`
2. `cert_manager-install`
3. `rhcl-install`
4. `dns-install`           ← requer `RHCL_DNS_PROVIDER` + creds setadas
5. `letsencrypt-install`   ← requer `LETSENCRYPT_EMAIL` setado
6. `monitoring-install`
7. `apps-install`

Como `dns-install` e `letsencrypt-install` estão incluídos, **garanta antes
que `~/cluster-secrets.sh` tem suas credenciais** (AWS keys, email LE, etc.) —
ou o playbook trava em "secret obrigatório vazio".

`coredns-install` **NÃO** está incluso (é opcional, pra cluster sem DNS
manager externo). Rode separado quando precisar.

---

## Cenário A — Lab Red Hat com AWS Route53 + Let's Encrypt

Cluster novo numa sandbox da Red Hat (AWS), zone DNS gerenciada via Route53, cert válido emitido por Let's Encrypt.

### Variáveis mínimas (export antes de cada playbook)

```bash
# === DNS provider — AWS Route 53 ===
export RHCL_DNS_PROVIDER=aws
export RHCL_DNS_NAMESPACE=kuadrant-system        # onde fica o Secret de creds DNS
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_AWS_ACCESS_KEY_ID=AKIA...
export RHCL_DNS_AWS_SECRET_ACCESS_KEY=...
export RHCL_DNS_AWS_REGION=us-east-1
export RHCL_DNS_AWS_ZONE_ID=Z123ABC...           # opcional: força a zone específica

# === Domain da zone (usada em hostnames derivados) ===
export RHCL_ZONE_ROOT_DOMAIN=poc.example.com

# === Let's Encrypt ===
export LETSENCRYPT_EMAIL=ops@example.com
export LETSENCRYPT_PROD_ENABLED=true             # default false (= staging só)
export LETSENCRYPT_DNS_PROVIDER=aws              # default = RHCL_DNS_PROVIDER

# === Apps connectivity TLS ===
export APPS_CONNECTIVITY_TLS_ENABLED=true
export APPS_CONNECTIVITY_TLS_ISSUER_NAME=letsencrypt-prod   # default letsencrypt-prod
```

### Sequência (recomendada — `install-all`)

```bash
cd automation

# Tudo em 1 comando (gateway_api + cert_manager + rhcl + dns + letsencrypt + monitoring + apps)
ansible-playbook playbooks/install-all.yml

# (opcional) MCP Gateway — item 59, fora do install-all
ansible-playbook playbooks/mcp_gateway-install.yml
```

### Sequência granular (passo-a-passo, se quiser ver cada um separado)

```bash
cd automation

ansible-playbook playbooks/gateway_api-install.yml
ansible-playbook playbooks/cert_manager-install.yml
ansible-playbook playbooks/rhcl-install.yml
ansible-playbook playbooks/coredns-install.yml          # opcional
ansible-playbook playbooks/dns-install.yml              # cria Secret do DNS provider
ansible-playbook playbooks/letsencrypt-install.yml      # cria ClusterIssuer Let's Encrypt
ansible-playbook playbooks/monitoring-install.yml       # opcional (UWM)
ansible-playbook playbooks/apps-install.yml             # Gateway + HTTPRoute + Deployments
ansible-playbook playbooks/mcp_gateway-install.yml      # opcional (item 59)
```

### Pós-install: validação

```bash
# Cluster Kuadrant pronto
oc get kuadrant -A
oc get pods -n kuadrant-system

# ClusterIssuer letsencrypt-prod Ready
oc get clusterissuer letsencrypt-prod

# Apps respondendo com cert válido
HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
curl -sI "https://$HOST/api/echo" | head -3
```

---

## Referência completa de variáveis

Todas as vars têm formato `lookup('ansible.builtin.env', 'VAR_NAME') | default(<sane-default>)`. Setar a env var em `export` antes do playbook sobrescreve o default em [`inventories/example/group_vars/all.yml`](inventories/example/group_vars/all.yml).

### 1) Kuadrant operator (`rhcl-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `RHCL_NAMESPACE` | `kuadrant-system` | Namespace do Kuadrant control plane |
| `RHCL_OPERATOR_CHANNEL` | `stable` | Canal do subscription |
| `RHCL_OPERATOR_NAME` | `rhcl-operator` | Nome do operator no OperatorHub |
| `RHCL_OPERATOR_SOURCE` | `redhat-operators` | CatalogSource |
| `RHCL_INSTANCE_NAME` | `kuadrant` | Nome do CR `Kuadrant` criado |
| `RHCL_OCP_MODE` | `native_gateway_api` | Modo de operação (único suportado) |
| `RHCL_CONSOLE_PLUGIN_ENABLED` | `true` | Habilita o plugin de console |
| `RHCL_CONSOLE_PLUGIN_NAME` | `kuadrant-console-plugin` | Nome do plugin |

### 2) Gateway API CRDs (`gateway_api-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `GATEWAY_API_GATEWAYCLASS_NAME` | `openshift-default` | GatewayClass utilizada. Usar `istio` em clusters com Sail/OSSM3 standalone |

### 3) cert-manager (`cert_manager-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `CERT_MANAGER_NAMESPACE` | `cert-manager-operator` | Namespace do operator |
| `CERT_MANAGER_CHANNEL` | `stable-v1` | Canal |
| `CERT_MANAGER_OPERATOR_NAME` | `openshift-cert-manager-operator` | Nome no OperatorHub |
| `CERT_MANAGER_DNS` | (vazio) | Lista de DNS servers customizados pro pod do cert-manager |

### 4) DNS provider (`dns-install.yml`) — para Kuadrant DNS Operator

| Variável | Default | Provider |
|---|---|---|
| `RHCL_DNS_PROVIDER` | (vazio) | `aws`, `azure`, ou `gcp` |
| `RHCL_DNS_NAMESPACE` | `kuadrant-system` | Onde o Secret é criado |
| `RHCL_DNS_SECRET_NAME` | `rhcl-dns-credentials` | Nome do Secret de credenciais |

**AWS Route 53:**

| Variável | Função |
|---|---|
| `RHCL_DNS_AWS_ACCESS_KEY_ID` | Access key da IAM user/role com permissão de manipular records |
| `RHCL_DNS_AWS_SECRET_ACCESS_KEY` | Secret key correspondente |
| `RHCL_DNS_AWS_REGION` | Região (`us-east-1`, etc.) |
| `RHCL_DNS_AWS_ZONE_ID` | (opcional) HostedZoneID específica. Quando vazio, a role auto-detecta a zona Route53 mais específica que cobre o FQDN do gateway (`<APPS_CONNECTIVITY_ROUTE_NAME>.<apps-domain>`) validando a delegação NS pública — evita escrever no parent zone errado em RHPDS sandboxes onde a sub-zona é delegada. |

**Azure DNS:**

| Variável | Função |
|---|---|
| `RHCL_DNS_AZURE_JSON` | Conteúdo JSON do azure.json (SP credentials) — inline |
| `RHCL_DNS_AZURE_JSON_FILE` | Path do arquivo azure.json (alternativa ao inline) |
| `AZ_DNS_ZONE` | Nome da DNS zone Azure |

**GCP Cloud DNS:**

| Variável | Função |
|---|---|
| `RHCL_DNS_GCP_PROJECT_ID` | Project ID |
| `RHCL_DNS_GCP_GOOGLE` | JSON da service account inline |
| `RHCL_DNS_GCP_GOOGLE_FILE` | Path do JSON da SA (alternativa) |

### 5) DNSPolicy (Kuadrant)

| Variável | Default | Função |
|---|---|---|
| `RHCL_DNS_POLICY_ENABLED` | `true` | Cria DNSPolicy atrelada ao Gateway |
| `RHCL_DNS_POLICY_NAME` | `<gateway-name>-dns` | Nome do CR |
| `RHCL_DNS_POLICY_TARGET_GATEWAY_NAME` | `<apps_connectivity_gateway_name>` | Target |
| `RHCL_DNS_POLICY_TARGET_GATEWAY_NAMESPACE` | `<apps_connectivity_gateway_namespace>` | Target ns |
| `RHCL_DNS_POLICY_LOAD_BALANCING_ENABLED` | `false` | Habilita LB inter-cluster |
| `RHCL_DNS_POLICY_DEFAULT_GEO` | `true` | Aceita qualquer geo como fallback |
| `RHCL_DNS_POLICY_GEO` | (vazio) | Geo string específica (`GEO-NA`, `GEO-EU`, etc.) |
| `RHCL_DNS_POLICY_WEIGHT` | `120` | Peso DNS pra split inter-cluster (req005) |
| `RHCL_ZONE_ROOT_DOMAIN` | (vazio) | Zone raiz pros hostnames derivados |

### 6) Let's Encrypt (`letsencrypt-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `LETSENCRYPT_EMAIL` | (vazio) | Email pro registro ACME |
| `LETSENCRYPT_PROD_ENABLED` | `false` | Cria o ClusterIssuer prod (true) ou só staging |
| `LETSENCRYPT_STAGING_NAME` | `letsencrypt-staging` | Nome do ClusterIssuer staging |
| `LETSENCRYPT_PROD_NAME` | `letsencrypt-prod` | Nome do ClusterIssuer prod |
| `LETSENCRYPT_SOLVER` | `dns01` | Tipo de challenge (único suportado) |
| `LETSENCRYPT_DNS_PROVIDER` | `<RHCL_DNS_PROVIDER>` | Provider do DNS solver |
| `LETSENCRYPT_SECRET_NAMESPACE` | `cert-manager` | Namespace pro Secret das creds DNS |
| `LETSENCRYPT_SECRET_NAME` | `letsencrypt-dns-credentials` | Nome do Secret |
| `LETSENCRYPT_AWS_HOSTED_ZONE_ID` | (vazio) | HostedZone ID (Route 53). Quando vazio, a role auto-detecta a zona Route53 mais específica que cobre o FQDN do gateway connectivity (longest-suffix + validação NS pública). Quando setado, é validado: se uma sub-zona delegada mais específica existe, a role aborta indicando o ID correto. |
| `LETSENCRYPT_AZURE_HOSTED_ZONE_NAME` | `<AZ_DNS_ZONE>` | Nome da zone Azure |

### 7) CoreDNS (`coredns-install.yml`) — opcional

| Variável | Default | Função |
|---|---|---|
| `COREDNS_ENABLED` | `false` | Pula o playbook quando false (default) |
| `COREDNS_NAMESPACE` | `kuadrant-coredns` | Namespace |
| `COREDNS_KUSTOMIZE_SOURCE` | github Kuadrant config | URL do kustomize base |
| `COREDNS_DNS_ENABLED` | `false` | Cria CoreDNS DNSPolicy stand-in |
| `COREDNS_DNS_ZONE` | (vazio) | Zone que o CoreDNS resolve |
| `COREDNS_DNS_POLICY_*` | vários | Similar ao DNSPolicy do Kuadrant |

### 8) Monitoring (`monitoring-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `MONITORING_ENABLE_USER_WORKLOAD` | `true` | Habilita User Workload Monitoring |
| `MONITORING_NAMESPACE` | `openshift-monitoring` | Namespace do stack |
| `MONITORING_USER_WORKLOAD_NAMESPACE` | `openshift-user-workload-monitoring` | Namespace UWM |
| `MONITORING_CONFIG_NAME` | `cluster-monitoring-config` | Nome da ConfigMap |

### 9) Apps — namespace + imagens (`apps-install.yml`)

| Variável | Default | Função |
|---|---|---|
| `APPS_NAMESPACE` | `rhcl-apps` | Namespace pros pods/services da app |
| `APPS_BACKEND_PRIMARY_NAME` | `banking-api-v1` | Nome do Deployment v1 |
| `APPS_BACKEND_SECONDARY_NAME` | `banking-api-v2` | Nome do Deployment v2 |
| `APPS_FRONTEND_NAME` | `mobile-bank` | Nome do frontend |
| `APPS_BACKEND_IMAGE_NAME` | `banking-api` | Tag base da imagem backend |
| `APPS_FRONTEND_IMAGE_NAME` | `mobile-bank` | Tag base da imagem frontend |
| `APPS_IMAGE_SOURCE` | `build` | `build` (BuildConfig + start-build) ou `quay` (pull do Quay) |
| `APPS_BACKEND_IMAGE_QUAY` | `quay.io/hodrigohamalho/red-bank-backend:backend` | Imagem backend (se source=quay) |
| `APPS_FRONTEND_IMAGE_QUAY` | `quay.io/hodrigohamalho/red-bank-backend:frontend` | Imagem frontend |
| `APPS_BACKEND_SOURCE_DIR` | `apps/backend/banking-api` | Path do source (se source=build) |
| `APPS_FRONTEND_SOURCE_DIR` | `apps/frontend/mobile-bank` | Path do source |
| `APPS_SKIP_BUILD` | `false` | Pula start-build mesmo com source=build |

#### RHOAI Assistant (optional)

Enable with `APPS_RHOAI_ENABLED=true`. Deploys `rhoai-assistant-backend` (Quarkus) and
`rhoai-assistant-frontend` (Flutter Web) into `APPS_NAMESPACE`. The frontend Route exposes
the UI; nginx proxies `/api` to the backend Service (same-origin, no CORS).

| Variável | Default | Função |
|---|---|---|
| `APPS_RHOAI_ENABLED` | `false` | Instala o app RHOAI Assistant |
| `APPS_RHOAI_MAAS_API_KEY` | (vazio) | **Obrigatório** quando enabled — Bearer do MaaS LiteLLM |
| `APPS_RHOAI_MAAS_BASE_URL` | `https://maas-rhdp.apps.maas.redhatworkshops.io/v1` | Base URL OpenAI-compatible |
| `APPS_RHOAI_MAAS_MODEL` | `qwen3-14b` | Modelo padrão |
| `APPS_RHOAI_BACKEND_NAME` | `rhoai-assistant-backend` | Deployment/Service backend |
| `APPS_RHOAI_FRONTEND_NAME` | `rhoai-assistant-frontend` | Deployment/Service/Route frontend |
| `APPS_RHOAI_BACKEND_SOURCE_DIR` | `apps/rhoai-assistant/backend` | Source do build backend |
| `APPS_RHOAI_FRONTEND_SOURCE_DIR` | `apps/rhoai-assistant/frontend` | Source do build frontend |
| `APPS_RHOAI_HISTORY_MAX_MESSAGES` | `10` | Recorte de histórico enviado ao modelo |

```bash
export APPS_RHOAI_ENABLED=true
export APPS_RHOAI_MAAS_API_KEY='sk-...'
ansible-playbook playbooks/apps-install.yml
```

Ver também [`apps/rhoai-assistant/README.md`](../apps/rhoai-assistant/README.md).

### 10) Apps — backend TLS interno

| Variável | Default | Função |
|---|---|---|
| `APPS_BACKEND_TLS_ENABLED` | `true` | Habilita TLS no Pod (cert via Service serving) |
| `APPS_BACKEND_HTTPS_PORT` | `8443` | Porta HTTPS do pod |
| `APPS_BACKEND_PRIMARY_TLS_SECRET_NAME` | `<primary>-tls` | Secret do v1 |
| `APPS_BACKEND_SECONDARY_TLS_SECRET_NAME` | `<secondary>-tls` | Secret do v2 |
| `APPS_BACKEND_TLS_MOUNT_PATH` | `/etc/banking-tls` | Mount path no container |
| `APPS_BACKEND_TLS_CLIENT_AUTH` | `none` | mTLS client auth mode |
| `APPS_BACKEND_MCP_HTTPS_SERVICE_PORT` | `9443` | Service port pra MCP-tagged traffic |
| `APPS_BACKEND_CORS_ENABLED` | `false` | Liga CORS no Quarkus (default off — Gateway injeta) |

### 10b) Apps — backend TLS demo route (req 47)

| Variável | Default | Função |
|---|---|---|
| `APPS_BACKEND_TLS_ROUTE_ENABLED` | `true` | HTTPRoute `backend-tls` → `banking-api-v1:8443` + `BackendTLSPolicy` |
| `APPS_BACKEND_TLS_ROUTE_NAME` | `backend-tls` | Nome do HTTPRoute |
| `APPS_BACKEND_TLS_ROUTE_HOSTNAME` | (derivado) | Override — default `tls.<zone>` |
| `APPS_BACKEND_TLS_ROUTE_POLICY_NAME` | `backend-tls-backend-tls` | Nome do `BackendTLSPolicy` |
| `APPS_BACKEND_TLS_ROUTE_BACKEND_HOSTNAME` | `banking-api-v1.<ns>.svc` | SNI/hostname upstream |
| `APPS_BACKEND_TLS_ENABLED` | `true` | **Obrigatório** — HTTPS :8443 no banking-api (`QUARKUS_PROFILE=tls`) |

Ver [`tests/req047`](../tests/req047). O endpoint `/api/tls/info` já existe no banking-api.

### 11) Apps — Gateway + listener

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_LINK_ENABLED` | `true` | Cria Gateway + HTTPRoutes |
| `APPS_CONNECTIVITY_GATEWAY_NAME` | `rhcl-apps-gateway` | Nome do Gateway |
| `APPS_CONNECTIVITY_GATEWAY_NAMESPACE` | `openshift-ingress` | NS do Gateway |
| `APPS_CONNECTIVITY_GATEWAY_SERVICE_TYPE` | (vazio = LoadBalancer) | Forçar `ClusterIP`/`NodePort` via annotation Istio |
| `APPS_CONNECTIVITY_LISTENER_WILDCARD_ENABLED` | `false` | Listener wildcard (`*.<zone>`) — requer DNS automation |
| `APPS_CONNECTIVITY_MCP_LISTENER_ENABLED` | `true` | Cria listener MCP no Gateway |
| `APPS_CONNECTIVITY_GATEWAY_ELB_ANNOTATIONS_ENABLED` | `false` | Anotações AWS ELB (TCP passthrough) |
| `APPS_CONNECTIVITY_GATEWAY_DENY_ALL_ENABLED` | `true` | AuthPolicy deny-all no Gateway |
| `APPS_CONNECTIVITY_GATEWAY_DENY_ALL_POLICY_NAME` | `<gw>-deny-all` | Nome do CR |

### 12) Apps — HTTPRoute backend

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_ROUTE_NAME` | `banking-api-connectivity` | Nome do HTTPRoute |
| `APPS_CONNECTIVITY_ROUTE_HOSTNAME` | (derivado) | Hostname explícito (override) |
| `APPS_CONNECTIVITY_ROUTE_CORS_ENABLED` | `true` | Injeta headers `Access-Control-*` |
| `APPS_CONNECTIVITY_ROUTE_CORS_ALLOW_ORIGIN` | `*` | Origin permitida |
| `APPS_CONNECTIVITY_ROUTE_CORS_ALLOW_METHODS` | `GET,POST,PUT,PATCH,DELETE,OPTIONS` | Métodos |
| `APPS_CONNECTIVITY_ROUTE_CORS_ALLOW_HEADERS` | `...,api-key` | Lista de headers |
| `APPS_CONNECTIVITY_ROUTE_CORS_ALLOW_CREDENTIALS` | `true` | Permite cookies |
| `APPS_CONNECTIVITY_ROUTE_CORS_MAX_AGE` | `86400` | TTL do preflight |
| `APPS_CONNECTIVITY_ROUTE_ALT_SVC_ENABLED` | `true` | Injeta header `alt-svc` (HTTP/3) |
| `APPS_CONNECTIVITY_ROUTE_ALT_SVC_VALUE` | `h3=":443"; ma=86400` | Valor do header |

### 13) Apps — HTTPRoute frontend (`mobile-bank`)

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_FRONTEND_ROUTE_ENABLED` | `false` | Cria HTTPRoute + listener frontend |
| `APPS_CONNECTIVITY_FRONTEND_ROUTE_NAME` | `mobile-bank-connectivity` | Nome do CR |
| `APPS_CONNECTIVITY_FRONTEND_ROUTE_HOSTNAME` | (derivado) | Hostname explícito |
| `APPS_CONNECTIVITY_FRONTEND_LISTENER_NAME` | `frontend` | Nome do listener |
| `APPS_CONNECTIVITY_FRONTEND_HTTPS_ENABLED` | `false` | Listener HTTPS dedicado pro frontend |
| `APPS_CONNECTIVITY_FRONTEND_HTTPS_LISTENER_NAME` | `frontend-https` | Nome do listener HTTPS |
| `APPS_CONNECTIVITY_FRONTEND_TLS_SECRET_NAME` | `<tls_secret_name>` | Secret do cert |
| `APPS_CONNECTIVITY_FRONTEND_AUTH_POLICY_ENABLED` | `true` | AuthPolicy `allow-public` no frontend |
| `APPS_CONNECTIVITY_FRONTEND_AUTH_POLICY_NAME` | `<route>-allow-public` | Nome do CR |
| `APPS_FRONTEND_MCP_GATEWAY_URL` | (vazio) | URL do MCP gateway pro build do frontend |
| `APPS_FRONTEND_RHCL_GATEWAY_URL` | (derivado) | URL do backend baked no build do frontend |

### 14) Apps — Load Balancing por peso (req005)

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_LB_TEST_ENABLED` | `true` | Habilita path `/api/lb-test` |
| `APPS_CONNECTIVITY_LB_TEST_PATH` | `/api/lb-test` | Path do teste |
| `APPS_CONNECTIVITY_LB_V1_WEIGHT` | `50` | Peso do v1 |
| `APPS_CONNECTIVITY_LB_V2_WEIGHT` | `50` | Peso do v2 |

### 15) Apps — TLSPolicy

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_TLS_ENABLED` | `true` | Cria TLSPolicy |
| `APPS_CONNECTIVITY_TLS_POLICY_NAME` | `<gw>-tls` | Nome do CR |
| `APPS_CONNECTIVITY_TLS_SECRET_NAME` | `<gw>-tls` | Secret do cert |
| `APPS_CONNECTIVITY_TLS_ISSUER_NAME` | `letsencrypt-prod` | Nome do ClusterIssuer |
| `APPS_CONNECTIVITY_TLS_ISSUER_KIND` | `ClusterIssuer` | Tipo do issuer |
| `APPS_CONNECTIVITY_TLS_ISSUER_GROUP` | `cert-manager.io` | Group do issuer |

### 16) Apps — APIKeys + AuthPolicy

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_APIKEY_ENABLED` | `true` | Cria Secrets APIKey + AuthPolicy |
| `APPS_CONNECTIVITY_APIKEY_SECRET_NAME` | `banking-api-apikey` | Label app= dos Secrets |
| `APPS_CONNECTIVITY_APIKEY_SECRET_NAMESPACE` | `<apps_namespace>` | NS dos Secrets |
| `APPS_CONNECTIVITY_APIKEY_ALL_NAMESPACES` | `true` | AuthPolicy procura em qualquer NS |
| `APPS_CONNECTIVITY_APIKEY_GOLD` | `alice-gold-secret` | Valor da chave gold |
| `APPS_CONNECTIVITY_APIKEY_SILVER` | `bob-silver-secret` | Valor silver |
| `APPS_CONNECTIVITY_APIKEY_BRONZE` | `carol-bronze-secret` | Valor bronze |
| `APPS_CONNECTIVITY_APIKEY_VALUE` | `<APIKEY_GOLD>` | Chave única (baked no frontend) |

### 17) Apps — APIProduct + PlanPolicy + RateLimitPolicy

| Variável | Default | Função |
|---|---|---|
| `APPS_CONNECTIVITY_APIPRODUCT_ENABLED` | `true` | Cria APIProduct |
| `APPS_CONNECTIVITY_APIPRODUCT_NAME` | `banking-api` | Nome |
| `APPS_CONNECTIVITY_APIPRODUCT_DISPLAY_NAME` | `Banking API` | Display |
| `APPS_CONNECTIVITY_APIPRODUCT_DESCRIPTION` | (texto) | Descrição |
| `APPS_CONNECTIVITY_APIPRODUCT_VERSION` | `v1` | Versão |
| `APPS_CONNECTIVITY_APIPRODUCT_APPROVAL_MODE` | `manual` | `manual` / `auto` |
| `APPS_CONNECTIVITY_APIPRODUCT_PUBLISH_STATUS` | `Published` | Status |
| `APPS_CONNECTIVITY_APIPRODUCT_CONTACT_TEAM` | `RHCL PoC Team` | Contato |
| `APPS_CONNECTIVITY_APIPRODUCT_CONTACT_EMAIL` | (texto) | Email |
| `APPS_CONNECTIVITY_PLANPOLICY_ENABLED` | `true` | Cria PlanPolicy (gold/silver/bronze) |
| `APPS_CONNECTIVITY_PLANPOLICY_NAME` | `banking-api-plans` | Nome |
| `APPS_CONNECTIVITY_RATELIMIT_ENABLED` | `false` | RateLimitPolicy global anti-burst |
| `APPS_CONNECTIVITY_RATELIMIT_POLICY_NAME` | `banking-api-10rps` | Nome |
| `APPS_CONNECTIVITY_RATELIMIT_LIMIT` | `10` | Reqs |
| `APPS_CONNECTIVITY_RATELIMIT_WINDOW` | `1s` | Janela |

### 19) Apps — OpenShift Route fronting Gateway

| Variável | Default | Função |
|---|---|---|
| `APPS_OPENSHIFT_ROUTE_ENABLED` | `false` | Cria Route apontando pro Service do Gateway |
| `APPS_OPENSHIFT_ROUTE_NAMESPACE` | `<gw_namespace>` | NS da Route |
| `APPS_OPENSHIFT_ROUTE_TARGET_SERVICE` | (derivado `<gw>-<gwclass>`) | Service target |
| `APPS_OPENSHIFT_ROUTE_TARGET_PORT` | `http` | Named port do Service |
| `APPS_OPENSHIFT_ROUTE_INGRESS_CLASS_LABEL_KEY` | `kubernetes.io/ingress.class` | Key do label |
| `APPS_OPENSHIFT_ROUTE_INGRESS_CLASS_LABEL_VALUE` | `nginx` | Value |
| `APPS_OPENSHIFT_ROUTE_TLS_TERMINATION` | `edge` | `edge`/`reencrypt`/`passthrough` |

### 20) MCP Gateway (`mcp_gateway-install.yml`) — opcional, item 59

| Variável | Default | Função |
|---|---|---|
| `MCP_GATEWAY_NAMESPACE` | `mcp-gateway` | NS do operator, Gateway e CRs MCP |
| `MCP_GATEWAY_OPERATOR_CHANNEL` | `preview` | Canal |
| `MCP_GATEWAY_MANAGE_GATEWAY` | `false` | Reusa o Gateway dos apps quando false |
| `MCP_GATEWAY_GATEWAY_NAME` | `<apps_connectivity_gateway_name>` | Gateway target |
| `MCP_GATEWAY_GATEWAY_NAMESPACE` | `<apps_connectivity_gateway_namespace>` | NS do Gateway target |
| `MCP_GATEWAY_LISTENER_NAME` | `mcp` | Nome do listener no Gateway |
| `MCP_GATEWAY_PORT` | `8080` | Porta do listener |
| `MCP_GATEWAY_PROTOCOL` | `HTTP` | HTTP ou HTTPS |
| `MCP_GATEWAY_PATH` | `/mcp` | Path base |
| `MCP_GATEWAY_HOSTNAME` | (vazio) | Hostname público |
| `MCP_GATEWAY_EXTENSION_NAME` | `mcp-gateway` | Nome do CR MCPGatewayExtension |
| `MCP_GATEWAY_HTTP_ROUTE_MANAGEMENT` | `Enabled` | Gerencia HTTPRoute auto |
| `MCP_GATEWAY_CUSTOM_ROUTE_ENABLED` | `true` | Cria HTTPRoute custom com CORS |
| `MCP_GATEWAY_BROWSER_ROUTE_ENABLED` | `true` | Route pra acesso browser |
| `MCP_GATEWAY_SERVER_REGISTRATION_NAME` | `banking-api` | Nome do MCPServerRegistration |

---

## Override seguro via env-var (creds)

```bash
# Em vez de commitar no inventário, use env (ou Vault)
export RHCL_DNS_PROVIDER=aws
export RHCL_DNS_AWS_ACCESS_KEY_ID=AKIA...
export RHCL_DNS_AWS_SECRET_ACCESS_KEY=...
ansible-playbook playbooks/dns-install.yml
```

Pra creds permanentes: `ansible-vault encrypt_string` ou load de external var file via `-e @secrets.yml`.

---

## Rebuild só de imagens (`apps-build.yml`)

Quando muda só código no `apps/backend/banking-api` ou `apps/frontend/mobile-bank`, **não** precisa rodar `apps-install.yml` completo:

```bash
cd automation

# Rebuild dos 2 em paralelo via async
ansible-playbook playbooks/apps-build.yml

# Só backend
APPS_BUILD_TARGET=backend ansible-playbook playbooks/apps-build.yml

# Só frontend
APPS_BUILD_TARGET=frontend ansible-playbook playbooks/apps-build.yml
```

Tunables:

| Variável | Default | Função |
|---|---|---|
| `APPS_BUILD_TARGET` | `all` | `all` / `backend` / `frontend` |
| `APPS_BUILD_ASYNC_SECONDS` | `1800` | Timeout async |
| `APPS_BUILD_POLL_SECONDS` | `5` | Poll interval |

`BuildConfig`s já têm que existir (rode `apps-install.yml` uma vez antes). ImageStream triggers cuidam do rollout depois do build.

---

## Quando o `apps-build.yml` não serve

- **Cluster sem source-tree local** → use `APPS_IMAGE_SOURCE=quay`, sem build
- **Re-aplicação de manifests** (mudou env var sem mudar imagem) → use `apps-install.yml` normal; image change trigger não é exercido

---

## Execução isolada (test + remove por componente)

```bash
cd automation
ansible-playbook playbooks/gateway_api-test.yml
ansible-playbook playbooks/cert_manager-test.yml
ansible-playbook playbooks/rhcl-test.yml
ansible-playbook playbooks/coredns-test.yml
ansible-playbook playbooks/monitoring-test.yml
ansible-playbook playbooks/apps-test.yml
ansible-playbook playbooks/mcp_gateway-test.yml

# Remove em ordem reversa
ansible-playbook playbooks/mcp_gateway-remove.yml
ansible-playbook playbooks/apps-remove.yml
ansible-playbook playbooks/monitoring-remove.yml
ansible-playbook playbooks/coredns-remove.yml
ansible-playbook playbooks/rhcl-remove.yml
ansible-playbook playbooks/cert_manager-remove.yml
ansible-playbook playbooks/gateway_api-remove.yml
```

---

## Guias de teste por componente

- [README_TEST_INSTALLATION_GATEWAY_API.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_GATEWAY_API.md)
- [README_TEST_INSTALLATION_CERT_MANAGER.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_CERT_MANAGER.md)
- [README_TEST_INSTALLATION_RHCL.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_RHCL.md)
- [README_TEST_INSTALLATION_COREDNS.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_COREDNS.md)
- [README_TEST_INSTALLATION_DNS.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_DNS.md)
- [README_TEST_INSTALLATION_LETSENCRYPT.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_LETSENCRYPT.md)
- [README_TEST_INSTALLATION_APPS.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_APPS.md)
- [README_TEST_INSTALLATION_MCP_GATEWAY.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_MCP_GATEWAY.md)

## Notes

- `install-all.yml` applies components in this order: Gateway API, cert-manager, RHCL, CoreDNS, user-workload monitoring, sample applications. It does not run `dns-install.yml` or `letsencrypt-install.yml` — run those manually beforehand if you need them.
- `remove-all.yml` removes components in reverse dependency order.
- `test-all.yml` validates components in dependency order and stops at the first failure.
- This v1 does not implement the OpenShift `4.18-` Service Mesh path.
- `coredns-*.yml` is the DNS prerequisite in the main workflow.
- `dns-*.yml` remains available only for provider secret management. It does not create `DNSPolicy` resources.
- `letsencrypt-*.yml` is an optional helper that creates Let's Encrypt staging (and optionally production) `ClusterIssuer` resources backed by a DNS-01 solver. It reuses the same DNS credentials as `dns-*.yml`.
- `apps-*.yml` creates OpenShift `BuildConfig` and `ImageStream` objects plus standard `Deployment`, `Service`, and `Route` objects for the sample backend and frontend applications. Deployments use the `image.openshift.io/triggers` annotation so a successful build automatically rolls them out.
- `apps-*.yml` also creates a Gateway API connectivity link with `Gateway`, `HTTPRoute`, and a Kuadrant `RateLimitPolicy` for backend v1, backend v2, echo, and MCP server traffic.
- `mcp_gateway-*.yml` installs the MCP gateway Operator on the `preview` channel, reuses the existing app connectivity `Gateway` unless `MCP_GATEWAY_MANAGE_GATEWAY=true`, and registers the banking MCP server through a single-backend `HTTPRoute`.
