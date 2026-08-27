#!/usr/bin/env bash
# =============================================================================
# test-req050.sh — Interactive OCSP/CRL validation
#
# Uso:
#   ./test-req050.sh             # menu interativo
#   ./test-req050.sh <N>         # run scenario N (1-5) and exit
#   ./test-req050.sh A           # run all scenarios
#
# Requer:
#   - RHCL_ZONE_ROOT_DOMAIN definido
#   - certs/ folder with the generated certificates (via generate-certs.sh)
# =============================================================================
set -uo pipefail

BOLD='\033[1m'; RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; DIM='\033[2m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-}"
TEST_NUM="${1:-}"

if [[ ! -d "$CERTS_DIR" ]]; then
  echo -e "${RED}Error: certs/ folder not found in $CERTS_DIR${RESET}"
  echo "Execute ./generate-certs.sh primeiro."
  exit 1
fi
if [[ -z "$DOMAIN" ]]; then
  echo -e "${RED}Error: RHCL_ZONE_ROOT_DOMAIN not set.${RESET}"
  echo "Execute: export RHCL_ZONE_ROOT_DOMAIN=seu.dominio.com"
  exit 1
fi

APPS_PREFIX="${RHCL_APPS_PREFIX:-.}"
HOST_CRL="req050-crl${APPS_PREFIX}${DOMAIN}"
HOST_OCSP="req050-ocsp${APPS_PREFIX}${DOMAIN}"
LAST_TEST_RESULT=""

# --- Scenario definitions ---
declare -a T_GROUP T_TITLE T_DESC T_EXPECTED T_HOST T_CERT T_KEY T_KIND

T_GROUP[1]="CRL"; T_KIND[1]="curl"
T_TITLE[1]="PASS: valid client (not revoked)"
T_DESC[1]="Client with a certificate signed by the Intermediate CA and absent from the CRL.
The gateway validates the mTLS chain and confirms in the CRL that the serial is not revoked.
Handshake accepted, backend returns HTTP 200."
T_EXPECTED[1]="PASS"; T_HOST[1]="$HOST_CRL"
T_CERT[1]="$CERTS_DIR/client-valid.crt"; T_KEY[1]="$CERTS_DIR/client-valid.key"

T_GROUP[2]="CRL"; T_KIND[2]="curl"
T_TITLE[2]="FAIL: revoked client"
T_DESC[2]="Same Intermediate CA, but this certificate's serial is in the assembled CRL
at the gateway. Envoy checks the CRL (only_verify_leaf_cert_crl) and rejects the
handshake, proving CRL revocation is applied."
T_EXPECTED[2]="FAIL"; T_HOST[2]="$HOST_CRL"
T_CERT[2]="$CERTS_DIR/client-revoked.crt"; T_KEY[2]="$CERTS_DIR/client-revoked.key"

T_GROUP[3]="CRL"; T_KIND[3]="curl"
T_TITLE[3]="FAIL: cert from an unknown CA"
T_DESC[3]="Certificate issued by an external CA, unrelated to the lab hierarchy.
The trust chain is not built — rejected before the CRL check even happens."
T_EXPECTED[3]="FAIL"; T_HOST[3]="$HOST_CRL"
T_CERT[3]="$CERTS_DIR/client-untrusted.crt"; T_KEY[3]="$CERTS_DIR/client-untrusted.key"

T_GROUP[4]="CRL"; T_KIND[4]="curl"
T_TITLE[4]="FAIL: no client certificate"
T_DESC[4]="No certificate presented. Since require_client_certificate=true,
anonymous access is blocked at the handshake."
T_EXPECTED[4]="FAIL"; T_HOST[4]="$HOST_CRL"
T_CERT[4]=""; T_KEY[4]=""

T_GROUP[5]="OCSP"; T_KIND[5]="ocsp"
T_TITLE[5]="PASS: server staples OCSP response (staple)"
T_DESC[5]="The client requests OCSP status in the handshake (status_request). The gateway
responds with the server certificate + the stapled OCSP response. Expect
'OCSP Response Status: successful' and 'Cert Status: good'."
T_EXPECTED[5]="PASS"; T_HOST[5]="$HOST_OCSP"
T_CERT[5]="$CERTS_DIR/client-valid.crt"; T_KEY[5]="$CERTS_DIR/client-valid.key"

print_header() {
  clear
  echo -e "${BOLD}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║        OCSP / CRL validation (mTLS)                       ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  echo -e "  ${DIM}Domain: ${DOMAIN}${RESET}${BOLD}"
  echo ""
  echo "  CRL — client certificate revocation"
  echo -e "  ${GREEN}[1]${RESET}${BOLD} PASS: valid client (not revoked)"
  echo -e "  ${RED}[2]${RESET}${BOLD} FAIL: revoked client (in the CRL)"
  echo -e "  ${RED}[3]${RESET}${BOLD} FAIL: cert from an unknown CA"
  echo -e "  ${RED}[4]${RESET}${BOLD} FAIL: no client certificate"
  echo ""
  echo "  OCSP stapling — server certificate status"
  echo -e "  ${GREEN}[5]${RESET}${BOLD} PASS: stapled OCSP response (good)"
  echo ""
  echo -e "  ${YELLOW}[A]${RESET}${BOLD} Run ALL scenarios"
  echo -e "  ${DIM}[Q]${RESET}${BOLD} Quit"
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
    echo -e "${YELLOW}Expected:${RESET} ${RED}Connection rejected (TLS handshake failure)${RESET}"
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
      28) detail="Timeout (host unreachable?)" ;;
      35) detail="TLS handshake rejected (revoked/mTLS)" ;;
      56) detail="Connection reset (revoked/mTLS)" ;;
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
    actual="FAIL"; detail="No staple (OCSP not stapled)"
  else
    actual="FAIL"; detail="Staple missing or connection failed"
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
    echo -e "  ${RED}✗ UNEXPECTED — expected $expected, got $actual${RESET}"
  fi
  echo ""
}

run_test() {
  local idx=$1 interactive="${2:-true}"
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  SCENARIO $idx — ${T_GROUP[$idx]} — ${T_TITLE[$idx]}${RESET}"
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
  echo -e "${BOLD}══════════ RUNNING ALL SCENARIOS ══════════${RESET}"
  local pass=0 fail=0
  for i in 1 2 3 4 5; do
    run_test "$i" "false"
    if [[ "$LAST_TEST_RESULT" == "${T_EXPECTED[$i]}" ]]; then ((pass++)); else ((fail++)); fi
  done
  echo ""
  echo -e "${BOLD}RESUMO: ${GREEN}$pass OK${RESET}${BOLD}, ${RED}$fail inesperado(s)${RESET}"
  echo ""
  if [[ "$fail" -eq 0 ]]; then
    echo -e "  ${GREEN}✓ ALL SCENARIOS AS EXPECTED${RESET}"
  else
    echo -e "  ${RED}✗ WARNING: $fail scenario(s) with an unexpected result${RESET}"
  fi
  echo ""
}

# --- Execution ---
if [[ -n "$TEST_NUM" ]]; then
  if [[ "$TEST_NUM" == "A" || "$TEST_NUM" == "a" ]]; then
    run_all
  elif [[ "$TEST_NUM" =~ ^[1-5]$ ]]; then
    run_test "$TEST_NUM" "false"
  else
    echo -e "${RED}Error: invalid scenario '$TEST_NUM'. Use 1-5 or A.${RESET}"; exit 1
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
    *)     echo -e "${RED}Invalid option. Use 1-5, A or Q.${RESET}"; sleep 1 ;;
  esac
done
