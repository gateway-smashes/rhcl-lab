#!/usr/bin/env bash
# =============================================================================
# test-req050.sh — Validação interativa de OCSP/CRL (REQ 050)
#
# Uso:
#   ./test-req050.sh             # menu interativo
#   ./test-req050.sh <N>         # executa cenário N (1-5) e sai
#   ./test-req050.sh A           # executa todos os cenários
#
# Requer:
#   - RHCL_ZONE_ROOT_DOMAIN definido
#   - Pasta certs/ com os certificados gerados (via generate-certs.sh)
# =============================================================================
set -uo pipefail

BOLD='\033[1m'; RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; DIM='\033[2m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-}"
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
HOST_CRL="req050-crl${APPS_PREFIX}${DOMAIN}"
HOST_OCSP="req050-ocsp${APPS_PREFIX}${DOMAIN}"
LAST_TEST_RESULT=""

# --- Definição dos cenários ---
declare -a T_GROUP T_TITLE T_DESC T_EXPECTED T_HOST T_CERT T_KEY T_KIND

T_GROUP[1]="CRL"; T_KIND[1]="curl"
T_TITLE[1]="PASS: cliente válido (não revogado)"
T_DESC[1]="Cliente com certificado assinado pela CA Intermediária e ausente da CRL.
O gateway valida a cadeia mTLS e confirma na CRL que o serial não está revogado.
Handshake aceito, backend responde HTTP 200."
T_EXPECTED[1]="PASS"; T_HOST[1]="$HOST_CRL"
T_CERT[1]="$CERTS_DIR/client-valid.crt"; T_KEY[1]="$CERTS_DIR/client-valid.key"

T_GROUP[2]="CRL"; T_KIND[2]="curl"
T_TITLE[2]="FAIL: cliente revogado"
T_DESC[2]="Mesma CA Intermediária, mas o serial deste certificado consta na CRL montada
no gateway. O Envoy checa a CRL (only_verify_leaf_cert_crl) e rejeita o
handshake, provando que revogação por CRL é aplicada."
T_EXPECTED[2]="FAIL"; T_HOST[2]="$HOST_CRL"
T_CERT[2]="$CERTS_DIR/client-revoked.crt"; T_KEY[2]="$CERTS_DIR/client-revoked.key"

T_GROUP[3]="CRL"; T_KIND[3]="curl"
T_TITLE[3]="FAIL: cert de CA desconhecida"
T_DESC[3]="Certificado emitido por uma CA externa, sem relação com a hierarquia do PoC.
A cadeia de confiança não é construída — rejeitado antes mesmo da checagem de CRL."
T_EXPECTED[3]="FAIL"; T_HOST[3]="$HOST_CRL"
T_CERT[3]="$CERTS_DIR/client-untrusted.crt"; T_KEY[3]="$CERTS_DIR/client-untrusted.key"

T_GROUP[4]="CRL"; T_KIND[4]="curl"
T_TITLE[4]="FAIL: sem certificado de cliente"
T_DESC[4]="Nenhum certificado apresentado. Como require_client_certificate=true, o acesso
anônimo é bloqueado no handshake."
T_EXPECTED[4]="FAIL"; T_HOST[4]="$HOST_CRL"
T_CERT[4]=""; T_KEY[4]=""

T_GROUP[5]="OCSP"; T_KIND[5]="ocsp"
T_TITLE[5]="PASS: servidor grampeia resposta OCSP (staple)"
T_DESC[5]="O cliente pede o status OCSP no handshake (status_request). O gateway responde
com o certificado de servidor + a resposta OCSP grampeada. Espera-se
'OCSP Response Status: successful' e 'Cert Status: good'."
T_EXPECTED[5]="PASS"; T_HOST[5]="$HOST_OCSP"
T_CERT[5]="$CERTS_DIR/client-valid.crt"; T_KEY[5]="$CERTS_DIR/client-valid.key"

print_header() {
  clear
  echo -e "${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║        REQ 050 — Validação OCSP / CRL (mTLS)              ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  echo -e "  ${DIM}Domínio: ${DOMAIN}${RESET}${BOLD}"
  echo ""
  echo "  CRL — revogação de certificado de cliente"
  echo -e "  ${GREEN}[1]${RESET}${BOLD} PASS: cliente válido (não revogado)"
  echo -e "  ${RED}[2]${RESET}${BOLD} FAIL: cliente revogado (na CRL)"
  echo -e "  ${RED}[3]${RESET}${BOLD} FAIL: cert de CA desconhecida"
  echo -e "  ${RED}[4]${RESET}${BOLD} FAIL: sem certificado de cliente"
  echo ""
  echo "  OCSP stapling — status do certificado de servidor"
  echo -e "  ${GREEN}[5]${RESET}${BOLD} PASS: resposta OCSP grampeada (good)"
  echo ""
  echo -e "  ${YELLOW}[A]${RESET}${BOLD} Executar TODOS os cenários"
  echo -e "  ${DIM}[Q]${RESET}${BOLD} Sair"
  echo -e "${RESET}"
}

run_curl_test() {
  local idx=$1 interactive="${2:-true}"
  local host="${T_HOST[$idx]}" cert="${T_CERT[$idx]}" key="${T_KEY[$idx]}" expected="${T_EXPECTED[$idx]}"

  local cmd="curl -kv"
  [[ -n "$cert" ]] && cmd+=" --cert $cert --key $key"
  cmd+=" https://$host/api/tls/info"
  echo -e "${CYAN}Comando:${RESET} ${DIM}$cmd${RESET}"
  echo ""
  if [[ "$expected" == "PASS" ]]; then
    echo -e "${YELLOW}Esperado:${RESET} ${GREEN}HTTP 200${RESET}"
  else
    echo -e "${YELLOW}Esperado:${RESET} ${RED}Conexão rejeitada (TLS handshake failure)${RESET}"
  fi
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local curl_args=(-k --connect-timeout 10)
  [[ -n "$cert" ]] && curl_args+=(--cert "$cert" --key "$key")
  local tmpout; tmpout=$(mktemp); local tmperr="$tmpout.err"
  local curl_exit=0 http_code
  http_code=$(curl -sS -w '\n%{http_code}' "${curl_args[@]}" "https://$host/api/tls/info" -o "$tmpout" 2>"$tmperr") || curl_exit=$?
  http_code=$(echo "$http_code" | tr -d '[:space:]')
  [[ -z "$http_code" || ! "$http_code" =~ ^[0-9]+$ ]] && http_code="000"

  if [[ "$http_code" == "200" ]]; then
    echo -e "${DIM}"; python3 -m json.tool "$tmpout" 2>/dev/null || cat "$tmpout"; echo -e "${RESET}"
  elif [[ -s "$tmperr" ]]; then
    echo -e "${RED}  $(cat "$tmperr")${RESET}"
  fi
  rm -f "$tmpout" "$tmperr"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local actual detail
  if [[ "$http_code" == "200" ]]; then
    actual="PASS"; detail="HTTP 200"
  else
    actual="FAIL"
    case "$curl_exit" in
      7)  detail="Connection refused (porta 443 fechada?)" ;;
      28) detail="Timeout (host inacessível?)" ;;
      35) detail="TLS handshake rejected (revogado/mTLS)" ;;
      56) detail="Connection reset (revogado/mTLS)" ;;
      58|60) detail="Cert verification failed" ;;
      *)  detail="HTTP $http_code — curl exit $curl_exit" ;;
    esac
  fi
  LAST_TEST_RESULT="$actual"
  print_verdict "$idx" "$actual" "$expected" "$detail"
  [[ "$interactive" == "true" ]] && { echo -e "${DIM}ENTER para continuar...${RESET}"; read -r; }
}

run_ocsp_test() {
  local idx=$1 interactive="${2:-true}"
  local host="${T_HOST[$idx]}" cert="${T_CERT[$idx]}" key="${T_KEY[$idx]}" expected="${T_EXPECTED[$idx]}"

  local cmd="openssl s_client -connect ${host}:443 -servername ${host} -status --cert ${cert} --key ${key}"
  echo -e "${CYAN}Comando:${RESET} ${DIM}${cmd} </dev/null${RESET}"
  echo ""
  echo -e "${YELLOW}Esperado:${RESET} ${GREEN}OCSP Response Status: successful + Cert Status: good${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local out
  out=$(openssl s_client -connect "${host}:443" -servername "${host}" -status \
        -cert "$cert" -key "$key" </dev/null 2>/dev/null)

  # Extract the OCSP section for display
  echo -e "${DIM}"
  echo "$out" | grep -E "OCSP Response Status|Cert Status|This Update|Next Update" | sed 's/^/  /' || true
  echo -e "${RESET}"
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"

  local actual detail
  if echo "$out" | grep -q "OCSP Response Status: successful" && echo "$out" | grep -q "Cert Status: good"; then
    actual="PASS"; detail="Staple presente — Cert Status: good"
  elif echo "$out" | grep -q "OCSP response: no response sent"; then
    actual="FAIL"; detail="Sem staple (OCSP não grampeado)"
  else
    actual="FAIL"; detail="Staple ausente ou conexão falhou"
  fi
  LAST_TEST_RESULT="$actual"
  print_verdict "$idx" "$actual" "$expected" "$detail"
  [[ "$interactive" == "true" ]] && { echo -e "${DIM}ENTER para continuar...${RESET}"; read -r; }
}

print_verdict() {
  local idx=$1 actual=$2 expected=$3 detail=$4
  echo ""
  echo -e "  Resultado: ${BOLD}${detail}${RESET}"
  echo ""
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓ SUCESSO — resultado conforme esperado ($expected)${RESET}"
  else
    echo -e "  ${RED}✗ INESPERADO — esperava $expected, obteve $actual${RESET}"
  fi
  echo ""
}

run_test() {
  local idx=$1 interactive="${2:-true}"
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  CENÁRIO $idx — ${T_GROUP[$idx]} — ${T_TITLE[$idx]}${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "${DIM}${T_DESC[$idx]}${RESET}"
  echo ""
  if [[ "${T_KIND[$idx]}" == "ocsp" ]]; then
    run_ocsp_test "$idx" "$interactive"
  else
    run_curl_test "$idx" "$interactive"
  fi
}

run_all() {
  echo ""
  echo -e "${BOLD}══════════ EXECUTANDO TODOS OS CENÁRIOS ══════════${RESET}"
  local pass=0 fail=0
  for i in 1 2 3 4 5; do
    run_test "$i" "false"
    if [[ "$LAST_TEST_RESULT" == "${T_EXPECTED[$i]}" ]]; then ((pass++)); else ((fail++)); fi
  done
  echo ""
  echo -e "${BOLD}RESUMO: ${GREEN}$pass OK${RESET}${BOLD}, ${RED}$fail inesperado(s)${RESET}"
  echo ""
  if [[ "$fail" -eq 0 ]]; then
    echo -e "  ${GREEN}✓ TODOS OS CENÁRIOS CONFORME ESPERADO${RESET}"
  else
    echo -e "  ${RED}✗ ATENÇÃO: $fail cenário(s) com resultado inesperado${RESET}"
  fi
  echo ""
}

# --- Execução ---
if [[ -n "$TEST_NUM" ]]; then
  if [[ "$TEST_NUM" == "A" || "$TEST_NUM" == "a" ]]; then
    run_all
  elif [[ "$TEST_NUM" =~ ^[1-5]$ ]]; then
    run_test "$TEST_NUM" "false"
  else
    echo -e "${RED}Erro: cenário inválido '$TEST_NUM'. Use 1-5 ou A.${RESET}"; exit 1
  fi
  exit 0
fi

while true; do
  print_header
  echo -ne "  ${BOLD}Escolha [1-5, A, Q]: ${RESET}"
  read -r choice
  case "$choice" in
    [1-5]) run_test "$choice" "true" ;;
    [Aa])  run_all; echo -e "${DIM}ENTER para voltar ao menu...${RESET}"; read -r ;;
    [Qq])  echo -e "\n${DIM}Saindo...${RESET}"; exit 0 ;;
    *)     echo -e "${RED}Opção inválida. Use 1-5, A ou Q.${RESET}"; sleep 1 ;;
  esac
done
