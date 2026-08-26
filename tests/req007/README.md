# Item 7 — Sticky session (banking-api via Gateway API)

Pacote interativo do Item 7 do PoC do RHCL. Veja
[`../req007.md`](../req007.md) para a documentação completa (setup,
troubleshooting, rollback).

## Arquivos

| Arquivo | O que é |
|---|---|
| [`index.html`](index.html) | Console standalone com baseline (round-robin), Set-Cookie do Envoy, e teste de 5 cookies × N reqs com a distribuição por pod. Pré-preenche o host via `apiHost` em `/env.json`. |
| [`destination-rule-mobile-bank-sticky-session.yaml`](destination-rule-mobile-bank-sticky-session.yaml) | Manifest legado, ainda incluído por compatibilidade. **Não use** — aponta pro `mobile-bank.Service` que está exposto via Route OCP e bypassa o Istio. |
| [`../req007.md`](../req007.md) | Documentação consultiva (lida pelo viewer da app de tests) |

## Como rodar a demo

1. Setup uma vez (veja [`../req007.md`](../req007.md) "Setup"):
   - `oc scale deploy/banking-api-v1 -n rhcl-apps --replicas=2`
   - Patch do env `APP_INSTANCE_NAME` pra `fieldRef metadata.name`
   - Patch da `DestinationRule banking-api-v1-http1` adicionando o
     `consistentHash.httpCookie`
2. Abre a página no catálogo.
3. Confere que **Hostname do gateway** está com a URL da banking-api
   (vem pré-preenchido via `apiHost`).
4. **Probar baseline (sem cookie)** — deve mostrar 2 pods distintos.
5. **Ver Set-Cookie do Envoy** — deve aparecer `CUSTOM_COOKIE_SESSION`
   (NÃO o cookie hash do HAProxy).
6. **Probar sticky (5 cookies × N reqs)** — cada cookie aderido a 1 pod.
