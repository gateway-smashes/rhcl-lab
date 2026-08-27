#!/usr/bin/env bash
# =============================================================================
# test-mtls.sh — Interactive mTLS validation script
#
# Usage:
#   ./test-mtls.sh             # interactive menu
#   ./test-mtls.sh <N>         # runs test N (1-8) and exits
#   ./test-mtls.sh A           # runs all tests
#
# Requires:
#   - RHCL_ZONE_ROOT_DOMAIN set
#   - certs/ folder with the generated certificates (via generate-certs.sh)
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

# --- Directories ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"
DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-}"

# --- Validation ---
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
HOST056="req056-mtls${APPS_PREFIX}${DOMAIN}"
HOST051="req051-mtls${APPS_PREFIX}${DOMAIN}"
HOSTUNTRUSTED="req051-untrusted${APPS_PREFIX}${DOMAIN}"
LAST_TEST_RESULT=""

# =============================================================================
# Test definitions
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
TEST_TITLE[1]="PASS: cert signed by the Intermediate CA"
TEST_DESC[1]="Presents to the gateway a client certificate signed directly by the
Intermediate. Since the https-single-ca listener trusts only that CA,
the mTLS handshake succeeds and the backend returns HTTP 200."
TEST_EXPECTED[1]="PASS"
TEST_HOST[1]="$HOST056"
TEST_CERT[1]="$CERTS_DIR/client-chain.crt"
TEST_KEY[1]="$CERTS_DIR/client-chain.key"

TEST_GROUP[2]="REQ 056"
TEST_TITLE[2]="FAIL: cert signed by the Root CA"
TEST_DESC[2]="Presents a certificate signed directly by the Root CA. Although the Root
is the 'parent' of the Intermediate in the PKI hierarchy, this listener trusts ONLY the
Intermediate — it does not walk up the chain. The handshake is rejected."
TEST_EXPECTED[2]="FAIL"
TEST_HOST[2]="$HOST056"
TEST_CERT[2]="$CERTS_DIR/client-direct.crt"
TEST_KEY[2]="$CERTS_DIR/client-direct.key"

TEST_GROUP[3]="REQ 056"
TEST_TITLE[3]="FAIL: cert from an unknown CA"
TEST_DESC[3]="Presents a certificate issued by a completely external CA with no
relation to the lab hierarchy. The gateway does not recognize this CA, so the
mTLS handshake fails immediately."
TEST_EXPECTED[3]="FAIL"
TEST_HOST[3]="$HOST056"
TEST_CERT[3]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[3]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[4]="REQ 056"
TEST_TITLE[4]="FAIL: no client certificate"
TEST_DESC[4]="Sends no client certificate. Since require_client_certificate=true,
the gateway requires identification. Without a certificate the connection is rejected,
proving anonymous access is blocked."
TEST_EXPECTED[4]="FAIL"
TEST_HOST[4]="$HOST056"
TEST_CERT[4]=""
TEST_KEY[4]=""

# --- REQ 051 ---
TEST_GROUP[5]="REQ 051"
TEST_TITLE[5]="PASS: cert with full chain (bundle)"
TEST_DESC[5]="Presents the client certificate (signed by the Intermediate) together with the
Intermediate cert in the bundle, forming the leaf→intermediate→root chain.
The listener trusts the Root, walks the chain, and accepts the handshake."
TEST_EXPECTED[5]="PASS"
TEST_HOST[5]="$HOST051"
TEST_CERT[5]="$CERTS_DIR/client-chain-bundle.crt"
TEST_KEY[5]="$CERTS_DIR/client-chain.key"

TEST_GROUP[6]="REQ 051"
TEST_TITLE[6]="PASS: cert signed directly by the Root"
TEST_DESC[6]="Presents a certificate signed directly by the Root CA. Since the listener
trusts the Root and the cert was issued by it, validation is direct — it does not
need to walk the chain. The handshake is accepted."
TEST_EXPECTED[6]="PASS"
TEST_HOST[6]="$HOST051"
TEST_CERT[6]="$CERTS_DIR/client-direct.crt"
TEST_KEY[6]="$CERTS_DIR/client-direct.key"

TEST_GROUP[7]="REQ 051"
TEST_TITLE[7]="FAIL: cert from an unknown CA"
TEST_DESC[7]="Same scenario as test 3 (external CA), now against the Root CA listener.
The trust chain cannot be built up to the configured Root, so
o Envoy rejeita o handshake."
TEST_EXPECTED[7]="FAIL"
TEST_HOST[7]="$HOST051"
TEST_CERT[7]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[7]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[8]="REQ 051"
TEST_TITLE[8]="FAIL: no client certificate"
TEST_DESC[8]="With no certificate presented, the client is rejected by both listeners.
Proves require_client_certificate=true is active, requiring mutual
authentication regardless of the trust model."
TEST_EXPECTED[8]="FAIL"
TEST_HOST[8]="$HOST051"
TEST_CERT[8]=""
TEST_KEY[8]=""

# --- REQ 056 (extra) — full chain including the Root against the Single-CA listener ---
TEST_GROUP[9]="REQ 056"
TEST_TITLE[9]="PASS: full chain (leaf+intermediate+ROOT) on the Intermediate CA"
TEST_DESC[9]="Against the https-single-ca listener (which trusts ONLY the Intermediate), the client
presents the whole chain: leaf + Intermediate + Root. Envoy builds the path
up to the trusted anchor (the Intermediate) and ignores the extra/untrusted Root, so
the handshake is accepted — proving that sending the full chain does not break validation."
TEST_EXPECTED[9]="PASS"
TEST_HOST[9]="$HOST056"
TEST_CERT[9]="$CERTS_DIR/client-chain-fullchain.crt"
TEST_KEY[9]="$CERTS_DIR/client-chain.key"

# --- ACCEPT_UNTRUSTED — the chain is NOT enforced; it only requires presenting a cert ---
TEST_GROUP[10]="ACCEPT_UNTRUSTED"
TEST_TITLE[10]="PASS: cert from an UNtrusted CA is accepted"
TEST_DESC[10]="Listener https-accept-untrusted uses trust_chain_verification=ACCEPT_UNTRUSTED:
chain verification becomes NON-fatal. The SAME client-untrusted rejected on the
req056 listener (test 3) is ACCEPTED here, proving the ACCEPT_UNTRUSTED effect — the
CA trust is no longer enforced."
TEST_EXPECTED[10]="PASS"
TEST_HOST[10]="$HOSTUNTRUSTED"
TEST_CERT[10]="$CERTS_DIR/client-untrusted.crt"
TEST_KEY[10]="$CERTS_DIR/client-untrusted.key"

TEST_GROUP[11]="ACCEPT_UNTRUSTED"
TEST_TITLE[11]="PASS: any valid cert is accepted (trust not enforced)"
TEST_DESC[11]="Same listener, with the client-chain (signed by the Intermediate). Also accepted.
Under ACCEPT_UNTRUSTED, any presented cert passes — including the SAN match
(match_typed_subject_alt_names) is NOT enforced. To gate by SAN use VERIFY_TRUST_CHAIN."
TEST_EXPECTED[11]="PASS"
TEST_HOST[11]="$HOSTUNTRUSTED"
TEST_CERT[11]="$CERTS_DIR/client-chain.crt"
TEST_KEY[11]="$CERTS_DIR/client-chain.key"

TEST_GROUP[12]="ACCEPT_UNTRUSTED"
TEST_TITLE[12]="FAIL: no client certificate"
TEST_DESC[12]="Without presenting a certificate. require_client_certificate=true is still active on this
listener, so anonymous access is blocked even with ACCEPT_UNTRUSTED — the only
guarantee left is 'a cert must be presented'."
TEST_EXPECTED[12]="FAIL"
TEST_HOST[12]="$HOSTUNTRUSTED"
TEST_CERT[12]=""
TEST_KEY[12]=""

# --- XFCC — forward the client cert to the backend via header ---
TEST_GROUP[13]="XFCC"
TEST_TITLE[13]="PASS: client cert forwarded to the backend (x-forwarded-client-cert)"
TEST_DESC[13]="With the EnvoyFilter req051-xfcc (forward_client_cert_details=SANITIZE_SET +
set_current_client_cert_details cert/chain/subject), the gateway injects the header
x-forwarded-client-cert with the PEM of the client cert. Calls /api/echo (backend echo-server) with a valid cert
and confirms the backend received the XFCC containing Cert=."
TEST_EXPECTED[13]="PASS"
TEST_HOST[13]="$HOST056"
TEST_CERT[13]="$CERTS_DIR/client-chain.crt"
TEST_KEY[13]="$CERTS_DIR/client-chain.key"
TEST_KIND[13]="xfcc"

# =============================================================================
# Functions
# =============================================================================

# Special test kind: verify the client cert reaches the backend via XFCC.
run_xfcc_test() {
  local idx=$1
  local interactive="${2:-true}"
  local host="${TEST_HOST[$idx]}" cert="${TEST_CERT[$idx]}" key="${TEST_KEY[$idx]}"

  echo -e "${CYAN}Comando:${RESET}"
  echo -e "${DIM}curl -kv --cert $cert --key $key https://$host/api/echo${RESET}"
  echo ""
  echo -e "${YELLOW}Expected result:${RESET} ${GREEN}HTTP 200 + x-forwarded-client-cert header with Cert= (PEM)${RESET}"
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

  # Full JSON response from the echo backend (contains the XFCC header with the cert)
  echo -e "${CYAN}Full JSON response from the backend (echo):${RESET}"
  echo -e "${DIM}"
  python3 -m json.tool "$tmpout" 2>/dev/null || cat "$tmpout"
  echo -e "${RESET}"

  # Client certificate, decoded (URL-decode) from the XFCC Cert= field
  if [[ -n "$xfcc" ]]; then
    echo -e "${CYAN}Client certificate (PEM decoded from XFCC):${RESET}"
    echo -e "${DIM}"
    python3 -c "
import json, re, urllib.parse
d = json.load(open('$tmpout'))
h = (d.get('request') or {}).get('headers') or {}
x = h.get('x-forwarded-client-cert') or (d.get('forwarded') or {}).get('x-forwarded-client-cert', '')
m = re.search(r'Cert=\"([^\"]*)\"', x)
print(urllib.parse.unquote(m.group(1)) if m else '(no Cert= field)')
" 2>/dev/null
    echo -e "${RESET}"
  fi
  echo -e "${DIM}────────────────────────────────────────────────────────${RESET}"
  echo ""

  local actual detail
  if [[ "$http_code" == "200" ]] && echo "$xfcc" | grep -q "Cert="; then
    actual="PASS"; detail="XFCC received at the backend (with Cert PEM)"
  else
    actual="FAIL"; detail="HTTP $http_code — XFCC missing or no Cert"
  fi
  rm -f "$tmpout"
  LAST_TEST_RESULT="$actual"

  echo -e "  Resultado: ${BOLD}${detail}${RESET}"
  echo ""
  if [[ "$actual" == "${TEST_EXPECTED[$idx]}" ]]; then
    echo -e "  ${GREEN}✓ SUCESSO${RESET} — ${detail}"
  else
    echo -e "  ${RED}✗ UNEXPECTED${RESET} — Expected ${TEST_EXPECTED[$idx]}, got $actual"
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
  echo "║       Interactive mTLS validation                        ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  echo -e "  ${DIM}Domain: ${DOMAIN}${RESET}${BOLD}"
  echo ""
  echo "  Single-CA (trusts only the Intermediate)"
  echo -e "  ${GREEN}[1]${RESET}${BOLD} PASS: cert signed by the Intermediate CA"
  echo -e "  ${RED}[2]${RESET}${BOLD} FAIL: cert signed by the Root CA"
  echo -e "  ${RED}[3]${RESET}${BOLD} FAIL: cert from an unknown CA"
  echo -e "  ${RED}[4]${RESET}${BOLD} FAIL: no client certificate"
  echo -e "  ${GREEN}[9]${RESET}${BOLD} PASS: full chain (leaf+intermediate+ROOT)"
  echo ""
  echo "  REQ 051 — Chain-CA (trusts the Root, accepts the chain)"
  echo -e "  ${GREEN}[5]${RESET}${BOLD} PASS: cert with full chain (bundle)"
  echo -e "  ${GREEN}[6]${RESET}${BOLD} PASS: cert signed directly by the Root"
  echo -e "  ${RED}[7]${RESET}${BOLD} FAIL: cert from an unknown CA"
  echo -e "  ${RED}[8]${RESET}${BOLD} FAIL: no client certificate"
  echo ""
  echo "  ACCEPT_UNTRUSTED — chain not enforced; only requires a cert"
  echo -e "  ${GREEN}[10]${RESET}${BOLD} PASS: cert from an untrusted CA is accepted"
  echo -e "  ${GREEN}[11]${RESET}${BOLD} PASS: any valid cert is accepted"
  echo -e "  ${RED}[12]${RESET}${BOLD} FAIL: no client certificate"
  echo ""
  echo "  XFCC — forward the client cert to the backend"
  echo -e "  ${GREEN}[13]${RESET}${BOLD} PASS: cert in the x-forwarded-client-cert header"
  echo ""
  echo -e "  ${YELLOW}[A]${RESET}${BOLD} Run ALL tests"
  echo -e "  ${DIM}[Q]${RESET}${BOLD} Quit"
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
  echo -e "${BOLD}  TEST $idx — ${TEST_GROUP[$idx]} — ${TEST_TITLE[$idx]}${RESET}"
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
    echo -e "${YELLOW}Expected result:${RESET} ${GREEN}HTTP 200 (connection accepted)${RESET}"
  else
    echo -e "${YELLOW}Expected result:${RESET} ${RED}Connection rejected (TLS handshake failure)${RESET}"
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
      28) status_detail="HTTP $http_code — Timeout (host unreachable?)" ;;
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
      echo -e "  ${GREEN}✓ SUCCESS${RESET} — Connection rejected (expected)"
    fi
  else
    echo -e "  ${RED}✗ UNEXPECTED${RESET} — Expected $expected, got $actual_result"
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
  echo -e "${BOLD}       RUNNING ALL 13 TESTS                         ${RESET}"
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
    echo -e "  ${GREEN}✓ ALL TESTS PASSED AS EXPECTED${RESET}"
  else
    echo -e "  ${RED}✗ WARNING: $fail TEST(S) WITH UNEXPECTED RESULT${RESET}"
  fi
  echo ""
}

# =============================================================================
# Pre-flight check
# =============================================================================

preflight() {
  echo -e "${CYAN}Checking connectivity to ${HOST056} ...${RESET}"
  if curl -sk --connect-timeout 5 -o /dev/null "https://$HOST056/api/tls/info" 2>/dev/null; then
    echo -e "${GREEN}  ✓ TCP connection OK${RESET}"
  else
    local rc=$?
    if [[ $rc -eq 7 ]]; then
      echo -e "${RED}  ✗ Connection refused — porta 443 fechada em ${HOST056}${RESET}"
    elif [[ $rc -eq 28 ]]; then
      echo -e "${RED}  ✗ Timeout — ${HOST056} unreachable${RESET}"
    elif [[ $rc -eq 6 ]]; then
      echo -e "${RED}  ✗ DNS failed — could not resolve ${HOST056}${RESET}"
    else
      echo -e "${YELLOW}  ? curl exit $rc — may be normal (mTLS requires a cert).${RESET}"
    fi
  fi
  echo ""
}

# =============================================================================
# Execution
# =============================================================================

# Direct mode (no menu)
if [[ -n "$TEST_NUM" ]]; then
  preflight
  if [[ "$TEST_NUM" == "A" || "$TEST_NUM" == "a" ]]; then
    run_all
  elif [[ "$TEST_NUM" =~ ^([1-9]|1[0-3])$ ]]; then
    run_test "$TEST_NUM" "false"
  else
    echo -e "${RED}Error: invalid test '$TEST_NUM'. Use 1-13 or A.${RESET}"
    exit 1
  fi
  exit 0
fi

# Interactive mode (menu)
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
      echo -e "${RED}Invalid option. Use 1-13, A or Q.${RESET}"
      sleep 1
      ;;
  esac
done
