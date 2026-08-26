# Item 4 — Resiliência do gateway à indisponibilidade do control plane

Pacote interativo do Item 4 do PoC do RHCL. Veja
[`../req004.md`](../req004.md) para a documentação completa (definição
arquitetural, what-works-what-degrades, recomendações de produção).

## Arquivos

| Arquivo | O que é |
|---|---|
| [`index.html`](index.html) | Console standalone com o roteiro de demo: scale-down dos operadores, probe de tráfego, restore. Pré-preenche o host via `apiHost` em `/env.json`. |
| [`../req004.md`](../req004.md) | Documentação consultiva (lida pelo viewer da app de tests) |

## Como rodar a demo

1. Abra a página no catálogo de tests da PoC.
2. Confira que **Hostname do gateway** está com a URL da banking-api do
   cluster onde você está (deve vir pré-preenchido).
3. Aperte **Verificar estado inicial** — confirma que o tráfego está OK
   antes do teste e lista os pods do `kuadrant-system`.
4. Aperte **Derrubar control plane** — escala os 4 operadores para 0.
5. Aperte **Probar tráfego** — dispara N requests; deve dar `200` em
   todas (o data plane segue servindo).
6. Aperte **Restaurar control plane** — escala os 4 operadores de volta.

Todos os passos podem ser feitos via CLI também — os comandos exatos
estão na página, copy-paste-friendly, espelhando o que o
[`req004.md`](../req004.md) descreve.

## Pré-requisitos

- Cluster com RHCL instalado e a banking-api respondendo (igual req061-65).
- Usuário com privilégio para `oc scale deploy/... -n kuadrant-system`.
- A página usa CORS contra o gateway — o `HTTPRoute` da banking-api já tem
  os headers configurados pela role `apps` (req014).
