# REQ 23 / 46 — WebSockets para APIs em tempo real (PoC)

Página HTML interativa que demonstra a conectividade WebSocket entre o browser
e o backend da banking-api, tanto por acesso direto quanto passando pelo
RHCL / Gateway API.

Consulte [`../req023.md`](../req023.md) para a documentação completa do teste,
incluindo cenário, HTTPRoute necessário, comandos de terminal e validação pelo
frontend Red Bank.

## Arquivos

- [index.html](index.html) — página PoC single-file (sem build step).

## Como executar

```bash
# A partir da raiz do repositório
python3 -m http.server 9090 --directory tests/req023
# Abrir http://localhost:9090
```

Qualquer porta funciona. A página se conecta via WebSocket ao backend, então
o backend precisa estar rodando e acessível pela URL configurada.

## Como usar a página

1. **Definir a URL do WebSocket** — use um dos presets (localhost ou RHCL
   Gateway) ou digite manualmente.

2. **Clicar Connect** — a página abre uma conexão WebSocket ao endpoint
   `/ws/live` do backend. O badge no topo muda para `connected` (verde).

3. **Disparar uma transferência** — clique *Send transfer* para enviar um
   POST ao endpoint REST `/api/v1/transfers`. O backend processará a
   transferência e emitirá eventos pelo WebSocket.

4. **Observar os eventos em tempo real** — o log exibe cada mensagem JSON
   recebida, e os indicadores de estágio mostram a progressão:
   `PENDING → PROCESSING → COMPLETED → BALANCE UPDATED`.

5. **Comandos de terminal** — a seção inferior da página mostra comandos
   `websocat`, `wscat` e `curl` prontos para copiar e executar no terminal.

## Presets

| Preset | WebSocket URL | Uso |
| --- | --- | --- |
| Direct → localhost:8080 | `ws://localhost:8080/ws/live` | Teste local sem gateway |
| Via RHCL Gateway | `wss://<gateway-host>/ws/live` | Teste com o RHCL (configurar a URL do gateway e clicar Save) |

A URL do gateway é persistida em `localStorage` para sobreviver a reloads.

## O que "sucesso" significa

- Badge mostra **connected** (verde).
- Heartbeats (`backend.health`) aparecem no log a cada ~1 segundo.
- Após clicar *Send transfer*, 4 eventos aparecem em sequência:
  `transfer.pending` → `transfer.processing` → `transfer.completed` →
  `balance.updated`.
- Os indicadores de estágio avançam visualmente de cinza → amarelo → verde.

## O que indica falha

- Badge mostra **error** (vermelho) + mensagem `WebSocket ERROR` no log →
  o path `/ws` não está mapeado no HTTPRoute do gateway, ou o backend não
  está acessível.
- Nenhum heartbeat aparece → conexão não foi estabelecida.
- Transfer enviada mas nenhum evento WebSocket aparece → WebSocket desconectado
  ou apontando para backend diferente do que recebeu a transferência.
