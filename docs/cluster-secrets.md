# `~/cluster-secrets.sh` entre sandboxes

## TL;DR

No perfil `aws-lab` **não hardcode** estas vars em `~/cluster-secrets.sh`:

- `LETSENCRYPT_AWS_HOSTED_ZONE_ID`
- `RHCL_DNS_AWS_ACCESS_KEY_ID`
- `RHCL_DNS_AWS_SECRET_ACCESS_KEY`

O role `letsencrypt` resolve tudo automaticamente em cada sandbox.

## O bug

Sintoma: você troca de sandbox AWS, roda `install-all.yml`, ele completa OK,
mas o `rhcl-0` (Keycloak) fica `ContainerCreating` pra sempre. Investigando:

```
oc get certificate -A
# ... apps-tls False (not ready)

oc describe order -n openshift-ingress <name>
# ... InvalidClientTokenId
# ... SignatureDoesNotMatch
# ... NoSuchHostedZone
```

Causa: `~/cluster-secrets.sh` (fora do repo) tinha valores hardcoded do
cluster anterior. O `cluster-env.sh` carrega o arquivo no fim, então os
valores stale sobrescrevem o discovery do cluster atual. O role
`letsencrypt` só auto-descobre quando a var está vazia — se você passou um
valor (mesmo errado), ele confia e gera um ClusterIssuer apontando pra zona
errada, na conta AWS errada. O cert-manager tenta o DNS-01 challenge e
fica preso.

## A correção (já no código)

1. **`automation/roles/letsencrypt/tasks/validate_aws_zone.yml`** — quando
   o user passa `LETSENCRYPT_AWS_HOSTED_ZONE_ID` explícito, validamos antes
   de gerar o ClusterIssuer:
   - As creds AWS funcionam (`get_hosted_zone`)
   - A zone existe nesta conta
   - O `Name` da zone cobre o domínio do cluster
   - Os NS da zone batem com NS público
   
   Falha qualquer check → `ansible.builtin.fail` com mensagem indicando
   exatamente o que limpar em `~/cluster-secrets.sh`.

2. **`automation/scripts/cluster-env.sh`** — cacheamos o hostname do último
   cluster em `~/.cache/rhcl-lab/last-cluster`. Quando o cluster muda E
   alguma das vars suspeitas está setada, imprimimos um warning loud
   listando quais vars conferir.

3. **`automation/scripts/cluster-secrets.sh.example`** — agora desencoraja
   hardcoding dessas vars e aponta pra este doc.

## Fluxo recomendado em sandbox AWS

```bash
# 1) Login no sandbox novo
oc login <api-server>

# 2) Carrega env (vai avisar se detectar cluster trocado com vars stale)
source automation/scripts/cluster-env.sh

# 3) Install
ansible-playbook automation/install-all.yml
```

`~/cluster-secrets.sh` deve conter só vars **não-por-cluster** (e-mail do
Let's Encrypt, imagens Quay, API keys de teste, etc.).

## Se você PRECISA hardcodear (cluster não-IPI, creds dedicadas)

Atualize as 3 vars sempre que trocar de cluster. A validação em
`validate_aws_zone.yml` agora aborta cedo com mensagem clara se o conjunto
ficar incoerente — não tem mais hang silencioso.

## Como reproduzir o bug original

```bash
# Provisiona sandbox A, popula ~/cluster-secrets.sh com os IDs dele
source automation/scripts/cluster-env.sh && ansible-playbook automation/install-all.yml

# Provisiona sandbox B, NÃO limpa ~/cluster-secrets.sh
oc login <novo-api>
source automation/scripts/cluster-env.sh && ansible-playbook automation/install-all.yml

# Antes do fix: install completa, ACME fica pending pra sempre.
# Depois do fix: cluster-env.sh avisa que o cluster mudou + letsencrypt
# role aborta com mensagem indicando o que limpar.
```
