# REQ 71 — OIDC / JWT Auth no Gateway (RHBK + Kuadrant)

Validação operacional do item 71: **Keycloak (RHBK) real** emitindo JWT e o
**Gateway (Authorino/AuthPolicy)** validando e autorizando — a app não valida nada.

Resumo conceitual + arquitetura: [`../req071.md`](../req071.md).

---

## Pré-requisitos

```bash
# Cluster com RHCL/Kuadrant + banking-api já instalados (apps-install).
oc whoami
# RHBK instalado via automação:
cd automation
export RHCL_ZONE_ROOT_DOMAIN=poc.rhcl.com.br      # ajuste p/ o seu zone
ansible-playbook playbooks/rhbk-install.yml
ansible-playbook playbooks/rhbk-test.yml          # confirma issuer + token

# Variáveis usadas nos exemplos
export HOST=$(oc get httproute banking-api-connectivity -n rhcl-apps -o jsonpath='{.spec.hostnames[0]}')
export KC=https://keycloak.poc.rhcl.com.br        # = issuer base
export REALM=rhcl
export CID=banking-api
export CSECRET=banking-api-secret
```

Helper pra pegar token (password grant):

```bash
tok() { curl -s "$KC/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=$CID -d client_secret=$CSECRET \
  -d username="$1" -d password="$2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'; }
ALICE=$(tok alice alice123)
BOB=$(tok bob bob123)
```

> O token é um JWT RS256 com `iss=$KC/realms/rhcl`, `aud=banking-api`,
> `realm_access.roles`, `preferred_username`, `email`, `scope`. Decode com
> `echo $ALICE | cut -d. -f2 | base64 -d | jq` (ajuste padding se preciso).

---

## Cenário A — authN (validação do token no gateway)

A policy instalada protege `/api/whoami` com `jwt.issuerUrl`. O Authorino baixa o
JWKS do realm e valida **assinatura + iss + aud + exp** a cada request.

```bash
# Sem token → 401
curl -sk -o /dev/null -w "no token:   %{http_code}\n" "https://$HOST/api/whoami"
# Token forjado → 401 (assinatura inválida)
curl -sk -o /dev/null -w "lixo:       %{http_code}\n" -H "Authorization: Bearer not.a.jwt" "https://$HOST/api/whoami"
# Token válido → 200 + claims VERIFICADAS encaminhadas pelo gateway
curl -sk -H "Authorization: Bearer $ALICE" "https://$HOST/api/whoami" | jq '.jwt'
```

**Esperado**: `401`, `401`, depois `200` com um objeto `jwt` assim:

```json
{
  "x-jwt-aud": "banking-api",
  "x-jwt-email": "alice@example.com",
  "x-jwt-iss": "https://keycloak.poc.rhcl.com.br/realms/rhcl",
  "x-jwt-preferred-username": "alice",
  "x-jwt-roles": "[banking-customer]",
  "x-jwt-scope": "profile email",
  "x-jwt-sub": "…"
}
```

> Esses `x-jwt-*` são **injetados pelo gateway** (Authorino `response.success.headers`)
> a partir das claims já validadas. O backend não decodifica o token — só ecoa.

Prova de expiração: o `accessTokenLifespan` do realm é 300s. Espere o token expirar
e repita — vira `401` (claim `exp`), sem nenhum código na app.

---

## Cenário B — authZ por realm role (403 vs 200)

Default instalado exige `banking-customer` (alice e bob passam). Para ver o `403`,
troque a exigência pra `banking-admin`:

```bash
# alice NÃO tem banking-admin → 403 ; bob tem → 200
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"replace","path":"/spec/rules/authorization/jwt-require-role/patternMatching/patterns/0/value","value":"banking-admin"}]'
sleep 6
curl -sk -o /dev/null -w "alice: %{http_code}\n" -H "Authorization: Bearer $ALICE" "https://$HOST/api/whoami"   # 403
curl -sk -o /dev/null -w "bob:   %{http_code}\n" -H "Authorization: Bearer $BOB"   "https://$HOST/api/whoami"   # 200

# Voltar ao default (banking-customer)
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"replace","path":"/spec/rules/authorization/jwt-require-role/patternMatching/patterns/0/value","value":"banking-customer"}]'
```

---

## Cenário C — authZ por audience

Exigir `aud == banking-api` (qualquer token sem esse audience é negado):

```bash
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"add","path":"/spec/rules/authorization/jwt-require-aud","value":{
        "when":[{"predicate":"request.path.startsWith(\"/api/whoami\")"}],
        "patternMatching":{"patterns":[{"selector":"auth.identity.aud","operator":"eq","value":"banking-api"}]}}}]'
sleep 6
curl -sk -o /dev/null -w "alice (aud ok): %{http_code}\n" -H "Authorization: Bearer $ALICE" "https://$HOST/api/whoami"  # 200
# limpar
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"remove","path":"/spec/rules/authorization/jwt-require-aud"}]'
```

---

## Cenário D — authZ por scope (opcional)

Requer um optional client scope `accounts` no realm. Crie via admin API:

```bash
# admin definitivo do realm master (criado via spec.bootstrapAdmin): admin/redhat
AT=$(curl -s "$KC/realms/master/protocol/openid-connect/token" -d grant_type=password \
      -d client_id=admin-cli -d username=admin -d password=redhat | jq -r .access_token)
# cria o client scope 'accounts' e associa como optional ao client banking-api (ver Keycloak admin REST).
```

Depois, peça o token com `-d scope=accounts` e exija na AuthPolicy:
`selector: auth.identity.scope, operator: incl, value: accounts`. Sem o scope → `403`.

---

## Regressão (nada quebrou)

```bash
curl -sk -o /dev/null -w "echo anon:  %{http_code}\n" "https://$HOST/api/echo"                 # 200
KEY=$(oc -n rhcl-apps get secret banking-api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)
curl -sk -o /dev/null -w "apikey v1:  %{http_code}\n" -H "api-key: $KEY" "https://$HOST/api/v1/accounts"   # roteia (não 401)
```

---

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---------|----------------|-----|
| `/api/whoami` → `404` | HTTPRoute sem a rule `/api/whoami` | `APPS_CONNECTIVITY_JWT_ENABLED=true` (a rule é adicionada pela role apps) ou patch manual |
| Token válido → `401` | `iss` ≠ `issuerUrl`, ou Authorino não confia no TLS do issuer | hostname do Keycloak == issuerUrl da AuthPolicy; cert Let's Encrypt (não self-signed) |
| AuthPolicy não fica `Enforced` | Authorino falhou ao buscar o JWKS | `oc -n kuadrant-system logs deploy/authorino`; testar `curl $KC/realms/rhcl/.well-known/openid-configuration` |
| Token sem `realm_access.roles`/`scope` | realm import com `clientScopes` no nível do realm (suprime built-ins) | **não** declarar `clientScopes` no realm; deixar os built-ins (roles/profile/email) |
| `keycloak.<zone>` resolve no gateway, não no router | `*.<zone>` é wildcard → gateway | DNSRecord específico (03-…dnsrecord) apontando no router LB |

---

## Limpeza

```bash
cd automation && ansible-playbook playbooks/rhbk-remove.yml
oc -n openshift-ingress delete dnsrecord.kuadrant.io keycloak-rhcl --ignore-not-found
# desligar o JWT no gateway:
oc -n rhcl-apps patch authpolicy banking-api-connectivity-apikey --type=json \
  -p '[{"op":"remove","path":"/spec/rules/authentication/jwt-keycloak"},{"op":"remove","path":"/spec/rules/authorization/jwt-require-role"}]'
```
