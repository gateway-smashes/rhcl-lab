#!/usr/bin/env bash
# =============================================================================
# test-mtls.sh — Script interativo de validação mTLS (REQ 051 + 056)
#
# Uso:
#   ./test-mtls.sh             # menu interativo
#   ./test-mtls.sh <N>         # executa teste N (1-8) e sai
#   ./test-mtls.sh A           # executa todos os testes
#
# Requer:
#   - RHCL_ZONE_ROOT_DOMAIN definido
#   - Pasta certs/ com os certificados gerados (via generate-certs.sh)
# =============================================================================
set -uo pipefail

# --- Cores ANSI ---
BOLD='\033[1m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
DIM='\033[2m'
RESET='\033[0m'

# --- Diretórios ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-}"

# --- Validação ---
TEST_NUM="${1:-}"

if [[ ! -d "$CERTS_DIR" ]]; then
  echo -e "${RED}Erro: pasta certs/ não encontrada em $CERTS_DIR${RESET}"
  echo "Execute ./generate-certs.sh primeiro."
  exit 1
fi

if [[ -z "$DOMAIN" ]]; then
  echo -e "${RED}Erro: RHCL_ZONE_ROOT_DOMAIN não definido.${RESET}"
  echo "Execute: export RHCL_ZONE_ROOT_DOMAIN=seu.dominio.com"
  exit 1
fi


APPS_PREFIX="${RHCL_APPS_PREFIX:-.}"
HOST056="req056-mtls${APPS_PREFIX}${DOMAIN}"
HOST051="req051-mtls${APPS_PREFIX}${DOMAIN}"
HOSTUNTRUSTED="req051-untrusted${APPS_PREFIX}${DOMAIN}"
LAST_TEST_RESULT=""

# =============================================================================
# Definição dos testes
# =============================================================================

declare -a TEST_TITLE
declare -a TEST_DESC
declare -a TEST_EXPECTED
declare -a TEST_HOST
declare -a TEST_CERT
declare -a TEST_KEY
declare -a TEST_GROUP

# --- REQ 056 ---
TEST_GROUP[1]="REQ 056"
TEST_TITLE[1]="PASS: cert assinado pela CA Intermediária"
TEST_DESC[1]="Apresenta ao gateway um certificado de cliente assinado diretamente pela CA
Intermediária. Como o listener https-single-ca confia exclusivamente nessa CA,
o handshake mTLS é bem-sucedido e o backend retorna HTTP 200."
TEST_EXPECTED[1]="PASS"
TEST_HOST[1]="$HOST056"
TEST_CERT[1]="$CERTS_DIR/client-chain.crt"
TEST_KEY[1]="$CERTS_DIR/client-chain.key"

TEST_GROUP[2]="REQ 056"
TEST_TITLE[2]="FAIL: cert assinado pela Root CA"
TEST_DESC[2]="Apresenta um certificado assinado diretamente pela Root CA. Apesar de a Root
ser 'mãe' da Intermediária na hierarquia PKI, este listener confia APENAS na
Intermediária — não sobe a cadeia. O handshake é rejeitado."
TEST_EXPECTED[2]="FAIL"
TEST_HOST[2]="$HOST056"
TEST_CERT[2]="$CERTS_DIR/client-direct.crt"
TEST_KEY[2]="$CERTS_DIR/client-direct.key"

TEST_GROUP[3]="REQ 056"
TEST_TITLE[3]="FAIL: cert de CA desconhecida"
TEST_DESC[3]="Apresenta um certificado emitido por uma CA completamente externa e sem
relação com a hierarquia do PoC. O gateway não reconhece essa CA, então o
handshake mTLS falha imediatamente."
TEST_EXPECTED[3]="FAIL"
TEST_HOST[3]="$HOST056"
TEST_CERT[3]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[3]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[4]="REQ 056"
TEST_TITLE[4]="FAIL: sem certificado de cliente"
TEST_DESC[4]="Não envia nenhum certificado de cliente. Como require_client_certificate=true,
o gateway exige identificação. Sem certificado, a conexão é rejeitada,
provando que acesso anônimo é bloqueado."
TEST_EXPECTED[4]="FAIL"
TEST_HOST[4]="$HOST056"
TEST_CERT[4]=""
TEST_KEY[4]=""

# --- REQ 051 ---
TEST_GROUP[5]="REQ 051"
TEST_TITLE[5]="PASS: cert com cadeia completa (bundle)"
TEST_DESC[5]="Apresenta o certificado de cliente (assinado pela Intermediária) junto com o
cert da Intermediária no bundle, formando a cadeia leaf→intermediate→root.
O listener confia na Root, percorre a cadeia e aceita o handshake."
TEST_EXPECTED[5]="PASS"
TEST_HOST[5]="$HOST051"
TEST_CERT[5]="$CERTS_DIR/client-chain-bundle.crt"
TEST_KEY[5]="$CERTS_DIR/client-chain.key"

TEST_GROUP[6]="REQ 051"
TEST_TITLE[6]="PASS: cert assinado diretamente pela Root"
TEST_DESC[6]="Apresenta um certificado assinado diretamente pela Root CA. Como o listener
confia na Root e o cert foi emitido por ela, a validação é direta — não
precisa percorrer cadeia. O handshake é aceito."
TEST_EXPECTED[6]="PASS"
TEST_HOST[6]="$HOST051"
TEST_CERT[6]="$CERTS_DIR/client-direct.crt"
TEST_KEY[6]="$CERTS_DIR/client-direct.key"

TEST_GROUP[7]="REQ 051"
TEST_TITLE[7]="FAIL: cert de CA desconhecida"
TEST_DESC[7]="Mesmo cenário do teste 3 (CA externa), agora contra o listener da Root CA.
A cadeia de confiança não pode ser construída até a Root configurada, então
o Envoy rejeita o handshake."
TEST_EXPECTED[7]="FAIL"
TEST_HOST[7]="$HOST051"
TEST_CERT[7]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[7]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[8]="REQ 051"
TEST_TITLE[8]="FAIL: sem certificado de cliente"
TEST_DESC[8]="Sem apresentar certificado, o cliente é rejeitado por ambos os listeners.
Comprova que require_client_certificate=true está ativo, exigindo autenticação
mútua independentemente do modelo de trust."
TEST_EXPECTED[8]="FAIL"
TEST_HOST[8]="$HOST051"
TEST_CERT[8]=""
TEST_KEY[8]=""

# --- REQ 056 (extra) — full chain incluindo a Root contra o listener Single-CA ---
TEST_GROUP[9]="REQ 056"
TEST_TITLE[9]="PASS: cadeia completa (leaf+intermediate+ROOT) na CA Intermediária"
TEST_DESC[9]="Contra o listener https-single-ca (que confia APENAS na Intermediária), o cliente
apresenta a cadeia inteira: leaf + Intermediária + Root. O Envoy constrói o caminho
até a âncora confiável (a Intermediária) e ignora a Root extra/não confiável, então
o handshake é aceito — provar que enviar a cadeia completa não quebra a validação."
TEST_EXPECTED[9]="PASS"
TEST_HOST[9]="$HOST056"
TEST_CERT[9]="$CERTS_DIR/client-chain-fullchain.crt"
TEST_KEY[9]="$CERTS_DIR/client-chain.key"

# --- ACCEPT_UNTRUSTED — cadeia NÃO é enforçada; só exige apresentar um cert ---
TEST_GROUP[10]="ACCEPT_UNTRUSTED"
TEST_TITLE[10]="PASS: cert de CA NÃO confiável é aceito"
TEST_DESC[10]="Listener https-accept-untrusted usa trust_chain_verification=ACCEPT_UNTRUSTED:
a verificação da cadeia vira NÃO-fatal. O MESMO client-untrusted que é rejeitado no
listener req056 (teste 3) é ACEITO aqui, provando o efeito do ACCEPT_UNTRUSTED — a
confiança na CA deixa de ser enforçada."
TEST_EXPECTED[10]="PASS"
TEST_HOST[10]="$HOSTUNTRUSTED"
TEST_CERT[10]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[10]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[11]="ACCEPT_UNTRUSTED"
TEST_TITLE[11]="PASS: qualquer cert válido é aceito (trust não enforçado)"
TEST_DESC[11]="Mesmo listener, com o client-chain (assinado pela Intermediária). Também é aceito.
Sob ACCEPT_UNTRUSTED, qualquer cert apresentado passa — inclusive o casamento por SAN
(match_typed_subject_alt_names) NÃO é enforçado. Para gate por SAN use VERIFY_TRUST_CHAIN."
TEST_EXPECTED[11]="PASS"
TEST_HOST[11]="$HOSTUNTRUSTED"
TEST_CERT[11]="$CERTS_DIR/client-chain.crt"
TEST_KEY[11]="$CERTS_DIR/client-chain.key"

TEST_GROUP[12]="ACCEPT_UNTRUSTED"
TEST_TITLE[12]="FAIL: sem certificado de cliente"
TEST_DESC[12]="Sem apresentar certificado. require_client_certificate=true continua ativo neste
listener, então o acesso anônimo é bloqueado mesmo com ACCEPT_UNTRUSTED — a única
garantia que resta é 'um cert precisa ser apresentado'."
TEST_EXPECTED[12]="FAIL"
TEST_HOST[12]="$HOSTUNTRUSTED"
TEST_CERT[12]=""
TEST_KEY[12]=""

# --- XFCC — encaminhar o cert do cliente ao backend via header ---
TEST_GROUP[13]="XFCC"
TEST_TITLE[13]="PASS: cert do cliente encaminhado ao backend (x-forwarded-client-cert)"
TEST_DESC[13]="Com o EnvoyFilter req051-xfcc (forward_client_cert_details=SANITIZE_SET +
set_current_client_cert_details cert/chain/subject), o gateway injeta o header
x-forwarded-client-cert com o PEM do cert do cliente. Chama /api/echo (backend echo-server) com um cert
válido e confirma que o backend recebeu o XFCC contendo Cert=."
TEST_EXPECTED[13]="PASS"
TEST_HOST[13]="$HOST056"
TEST_CERT[13]="$CERTS_DIR/client-chain.crt"
TEST_KEY[13]="$CERTS_DIR/client-chain.key"
TEST_KIND[13]="xfcc"

# =============================================================================
# Funções
# =============================================================================

# Special test kind: verify the client cert reaches the backend via XFCC.
run_xfcc_test() {
  local idx=$1
  local interactive="${2:-true}"
  local host="${TEST_HOST[$idx]}" cert="${TEST_CERT[$idx]}" key="${TEST_KEY[$idx]}"

  echo -e "${CYAN}Comando:${RESET}"
  echo -e "${DIM}curl -kv --cert $cert --key $key https://$host/api/echo${RESET}"
  echo ""
  echo -e "${YELLOW}Resultado esperado:${RESET} ${GREEN}HTTP 200 + header x-forwarded-client-cert com Cert= (PEM)${RESET}"
  echo ""
  echo -e "${CYAN}Executando...${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local tmpout; tmpout=$(mktemp)
  local http_code
  http_code=$(curl -sS -k -w '\n%{http_code}' --cert "$cert" --key "$key" --connect-timeout 10 \
    "https://$host/api/echo" -o "$tmpout" 2>/dev/null) || true
  http_code=$(echo "$http_code" | tr -d '[:space:]')
  [[ "$http_code" =~ ^[0-9]+$ ]] || http_code="000"

  # Echo backend puts headers under request.headers; banking-api used forwarded.*
  local xfcc
  xfcc=$(python3 -c "
import json
d=json.load(open('$tmpout'))
h=(d.get('request') or {}).get('headers') or {}
print(h.get('x-forwarded-client-cert') or (d.get('forwarded') or {}).get('x-forwarded-client-cert',''))
" 2>/dev/null)

  # Resposta JSON completa do backend echo (contém o header XFCC com o cert)
  echo -e "${CYAN}Resposta JSON completa do backend (echo):${RESET}"
  echo -e "${DIM}"
  python3 -m json.tool "$tmpout" 2>/dev/null || cat "$tmpout"
  echo -e "${RESET}"

  # Certificado do cliente, decodificado (URL-decode) do campo Cert= do XFCC
  if [[ -n "$xfcc" ]]; then
    echo -e "${CYAN}Certificado do cliente (PEM decodificado do XFCC):${RESET}"
    echo -e "${DIM}"
    python3 -c "
import json, re, urllib.parse
d = json.load(open('$tmpout'))
h = (d.get('request') or {}).get('headers') or {}
x = h.get('x-forwarded-client-cert') or (d.get('forwarded') or {}).get('x-forwarded-client-cert', '')
m = re.search(r'Cert=\"([^\"]*)\"', x)
print(urllib.parse.unquote(m.group(1)) if m else '(sem campo Cert=)')
" 2>/dev/null
    echo -e "${RESET}"
  fi
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"
  echo ""

  local actual detail
  if [[ "$http_code" == "200" ]] && echo "$xfcc" | grep -q "Cert="; then
    actual="PASS"; detail="XFCC recebido no backend (com Cert PEM)"
  else
    actual="FAIL"; detail="HTTP $http_code — XFCC ausente ou sem Cert"
  fi
  rm -f "$tmpout"
  LAST_TEST_RESULT="$actual"

  echo -e "  Resultado: ${BOLD}${detail}${RESET}"
  echo ""
  if [[ "$actual" == "${TEST_EXPECTED[$idx]}" ]]; then
    echo -e "  ${GREEN}✓ SUCESSO${RESET} — ${detail}"
  else
    echo -e "  ${RED}✗ INESPERADO${RESET} — Esperava ${TEST_EXPECTED[$idx]}, obteve $actual"
  fi
  echo ""
  if [[ "$interactive" == "true" ]]; then
    echo -e "${DIM}Pressione ENTER para continuar...${RESET}"
    read -r
  fi
}

print_header() {
  clear
  echo -e "${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║       REQ 051 + 056 — Validação Interativa mTLS          ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  echo -e "  ${DIM}Domínio: ${DOMAIN}${RESET}${BOLD}"
  echo ""
  echo "  REQ 056 — Single-CA (confia apenas na Intermediária)"
  echo -e "  ${GREEN}[1]${RESET}${BOLD} PASS: cert assinado pela CA Intermediária"
  echo -e "  ${RED}[2]${RESET}${BOLD} FAIL: cert assinado pela Root CA"
  echo -e "  ${RED}[3]${RESET}${BOLD} FAIL: cert de CA desconhecida"
  echo -e "  ${RED}[4]${RESET}${BOLD} FAIL: sem certificado de cliente"
  echo -e "  ${GREEN}[9]${RESET}${BOLD} PASS: cadeia completa (leaf+intermediate+ROOT)"
  echo ""
  echo "  REQ 051 — Chain-CA (confia na Root, aceita cadeia)"
  echo -e "  ${GREEN}[5]${RESET}${BOLD} PASS: cert com cadeia completa (bundle)"
  echo -e "  ${GREEN}[6]${RESET}${BOLD} PASS: cert assinado diretamente pela Root"
  echo -e "  ${RED}[7]${RESET}${BOLD} FAIL: cert de CA desconhecida"
  echo -e "  ${RED}[8]${RESET}${BOLD} FAIL: sem certificado de cliente"
  echo ""
  echo "  ACCEPT_UNTRUSTED — cadeia não é enforçada; só exige um cert"
  echo -e "  ${GREEN}[10]${RESET}${BOLD} PASS: cert de CA não confiável é aceito"
  echo -e "  ${GREEN}[11]${RESET}${BOLD} PASS: qualquer cert válido é aceito"
  echo -e "  ${RED}[12]${RESET}${BOLD} FAIL: sem certificado de cliente"
  echo ""
  echo "  XFCC — encaminhar cert do cliente ao backend"
  echo -e "  ${GREEN}[13]${RESET}${BOLD} PASS: cert no header x-forwarded-client-cert"
  echo ""
  echo -e "  ${YELLOW}[A]${RESET}${BOLD} Executar TODOS os testes"
  echo -e "  ${DIM}[Q]${RESET}${BOLD} Sair"
  echo -e "${RESET}"
}

build_curl_verbose() {
  local idx=$1
  local host="${TEST_HOST[$idx]}"
  local cert="${TEST_CERT[$idx]}"
  local key="${TEST_KEY[$idx]}"

  local cmd="curl -kv"
  if [[ -n "$cert" ]]; then
    cmd+=" --cert $cert --key $key"
  fi
  cmd+=" https://$host/api/tls/info"
  echo "$cmd"
}

run_test() {
  local idx=$1
  local interactive="${2:-true}"
  local host="${TEST_HOST[$idx]}"
  local cert="${TEST_CERT[$idx]}"
  local key="${TEST_KEY[$idx]}"
  local expected="${TEST_EXPECTED[$idx]}"

  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  TESTE $idx — ${TEST_GROUP[$idx]} — ${TEST_TITLE[$idx]}${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "${DIM}${TEST_DESC[$idx]}${RESET}"
  echo ""

  if [[ "${TEST_KIND[$idx]:-curl}" == "xfcc" ]]; then
    run_xfcc_test "$idx" "$interactive"
    return
  fi

  echo -e "${CYAN}Comando:${RESET}"
  echo -e "${DIM}$(build_curl_verbose "$idx")${RESET}"
  echo ""

  if [[ "$expected" == "PASS" ]]; then
    echo -e "${YELLOW}Resultado esperado:${RESET} ${GREEN}HTTP 200 (conexão aceita)${RESET}"
  else
    echo -e "${YELLOW}Resultado esperado:${RESET} ${RED}Conexão rejeitada (TLS handshake failure)${RESET}"
  fi
  echo ""
  echo -e "${CYAN}Executando...${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local curl_args=(-k --connect-timeout 10)
  if [[ -n "$cert" ]]; then
    curl_args+=(--cert "$cert" --key "$key")
  fi

  local tmpout
  tmpout=$(mktemp)
  local tmperr="$tmpout.err"

  local curl_exit=0
  local http_code
  http_code=$(curl -sS -w '\n%{http_code}' "${curl_args[@]}" "https://$host/api/tls/info" -o "$tmpout" 2>"$tmperr") || curl_exit=$?

  # http_code is the last line of -w output
  http_code=$(echo "$http_code" | tr -d '[:space:]')
  if [[ -z "$http_code" || ! "$http_code" =~ ^[0-9]+$ ]]; then
    http_code="000"
  fi

  # Show relevant output
  if [[ "$http_code" == "200" ]]; then
    echo -e "${DIM}"
    python3 -m json.tool "$tmpout" 2>/dev/null || cat "$tmpout"
    echo -e "${RESET}"
  elif [[ -s "$tmperr" ]]; then
    echo -e "${RED}  $(cat "$tmperr")${RESET}"
  fi
  rm -f "$tmpout" "$tmperr"

  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"
  echo ""

  local actual_result
  local status_detail
  if [[ "$http_code" == "200" ]]; then
    actual_result="PASS"
    status_detail="HTTP 200"
  else
    actual_result="FAIL"
    case "$curl_exit" in
      7)  status_detail="HTTP $http_code — Connection refused (porta 443 fechada?)" ;;
      28) status_detail="HTTP $http_code — Timeout (host inacessível?)" ;;
      35) status_detail="HTTP $http_code — TLS handshake rejected (mTLS rejeitado)" ;;
      56) status_detail="HTTP $http_code — Connection reset (mTLS rejeitado)" ;;
      60) status_detail="HTTP $http_code — Server cert verification failed" ;;
      *)  status_detail="HTTP $http_code — curl exit code $curl_exit" ;;
    esac
  fi

  LAST_TEST_RESULT="$actual_result"

  echo -e "  Resultado: ${BOLD}${status_detail}${RESET}"
  echo ""

  if [[ "$actual_result" == "$expected" ]]; then
    if [[ "$expected" == "PASS" ]]; then
      echo -e "  ${GREEN}✓ SUCESSO${RESET} — HTTP 200 (conforme esperado)"
    else
      echo -e "  ${GREEN}✓ SUCESSO${RESET} — Conexão rejeitada (esperado)"
    fi
  else
    echo -e "  ${RED}✗ INESPERADO${RESET} — Esperava $expected, obteve $actual_result"
  fi

  echo ""

  if [[ "$interactive" == "true" ]]; then
    echo -e "${DIM}Pressione ENTER para continuar...${RESET}"
    read -r
  fi
}

run_all() {
  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}       EXECUTANDO TODOS OS 13 TESTES                         ${RESET}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════════${RESET}"

  local pass=0
  local fail=0

  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    run_test "$i" "false"

    if [[ "$LAST_TEST_RESULT" == "${TEST_EXPECTED[$i]}" ]]; then
      ((pass++))
    else
      ((fail++))
    fi
  done

  echo ""
  echo -e "${BOLD}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  RESUMO: ${GREEN}$pass testes OK${RESET}${BOLD}, ${RED}$fail testes inesperados${RESET}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════════${RESET}"
  echo ""

  if [[ "$fail" -eq 0 ]]; then
    echo -e "  ${GREEN}✓ TODOS OS TESTES PASSARAM CONFORME ESPERADO${RESET}"
  else
    echo -e "  ${RED}✗ ATENÇÃO: $fail TESTE(S) COM RESULTADO INESPERADO${RESET}"
  fi
  echo ""
}

# =============================================================================
# Pre-flight check
# =============================================================================

preflight() {
  echo -e "${CYAN}Verificando conectividade com ${HOST056} ...${RESET}"
  if curl -sk --connect-timeout 5 -o /dev/null "https://$HOST056/api/tls/info" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Conexão TCP OK${RESET}"
  else
    local rc=$?
    if [[ $rc -eq 7 ]]; then
      echo -e "${RED}  ✗ Connection refused — porta 443 fechada em ${HOST056}${RESET}"
    elif [[ $rc -eq 28 ]]; then
      echo -e "${RED}  ✗ Timeout — ${HOST056} inacessível${RESET}"
    elif [[ $rc -eq 6 ]]; then
      echo -e "${RED}  ✗ DNS falhou — não conseguiu resolver ${HOST056}${RESET}"
    else
      echo -e "${YELLOW}  ? curl exit $rc — pode ser normal (mTLS exige cert).${RESET}"
    fi
  fi
  echo ""
}

# =============================================================================
# Execução
# =============================================================================

# Modo direto (sem menu)
if [[ -n "$TEST_NUM" ]]; then
  preflight
  if [[ "$TEST_NUM" == "A" || "$TEST_NUM" == "a" ]]; then
    run_all
  elif [[ "$TEST_NUM" =~ ^([1-9]|1[0-3])$ ]]; then
    run_test "$TEST_NUM" "false"
  else
    echo -e "${RED}Erro: teste inválido '$TEST_NUM'. Use 1-13 ou A.${RESET}"
    exit 1
  fi
  exit 0
fi

# Modo interativo (menu)
while true; do
  print_header
  echo -ne "  ${BOLD}Escolha [1-13, A, Q]: ${RESET}"
  read -r choice

  case "$choice" in
    [1-9]|1[0-3])
      run_test "$choice" "true"
      ;;
    [Aa])
      run_all
      echo -e "${DIM}Pressione ENTER para voltar ao menu...${RESET}"
      read -r
      ;;
    [Qq])
      echo ""
      echo -e "${DIM}Saindo...${RESET}"
      exit 0
      ;;
    *)
      echo -e "${RED}Opção inválida. Use 1-13, A ou Q.${RESET}"
      sleep 1
      ;;
  esac
done
