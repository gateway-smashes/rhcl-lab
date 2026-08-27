#!/usr/bin/env bash
# Generate a full PKI for REQ 050 — OCSP stapling + CRL revocation testing.
#
# Builds on the REQ 051 hierarchy, but the server and client certs are issued
# through `openssl ca` (tracked in index.txt) so we can revoke certs, publish a
# CRL, and produce OCSP responses.
#
# Hierarchy:
#   Root CA (self-signed)
#    └── Intermediate CA (signed by Root; also the CRL issuer / OCSP responder)
#         ├── Server cert   (SAN=req050-crl/req050-ocsp/*.$DOMAIN)
#         ├── Client "valid"   (CN=banking-client-valid)      — NOT revoked
#         └── Client "revoked" (CN=banking-client-revoked)    — revoked below
#
#   Untrusted CA (self-signed, unrelated)
#    └── Client "untrusted" (CN=untrusted-client)
#
# Outputs (./certs/, git-ignored):
#   crl.pem          — CRL signed by the Intermediate CA (lists the revoked client)
#   server-ocsp.der  — OCSP response for the server cert (staple), status "good"
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=example.com
#   ./generate-certs.sh

set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-example.com}"
OUTDIR="./certs"
DAYS="${DAYS:-825}"
OCSP_DAYS="${OCSP_DAYS:-7}"
SUBJECT_BASE="/C=BR/ST=DF/L=Brasilia/O=RHCL-PoC"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/newcerts"
: > "$OUTDIR/index.txt"
echo "1000" > "$OUTDIR/serial"
echo "1000" > "$OUTDIR/crlnumber"

# ===========================================================================
# 0. openssl CA config (used by `openssl ca` for issuing / revoking / CRL)
# ===========================================================================
cat > "$OUTDIR/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_intermediate

[ CA_intermediate ]
dir               = ${OUTDIR}
database          = \$dir/index.txt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
new_certs_dir     = \$dir/newcerts
certificate       = \$dir/intermediate-ca.crt
private_key       = \$dir/intermediate-ca.key
default_md        = sha256
default_days      = ${DAYS}
default_crl_days  = 30
policy            = policy_any
email_in_dn       = no
unique_subject    = no
rand_serial       = no

[ policy_any ]
commonName             = supplied
organizationName       = optional
organizationalUnitName = optional
stateOrProvinceName    = optional
countryName            = optional

[ server_ext ]
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[ client_ext ]
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature
extendedKeyUsage       = clientAuth

[ alt_names ]
DNS.1 = req050-crl.${DOMAIN}
DNS.2 = req050-ocsp.${DOMAIN}
DNS.3 = *.${DOMAIN}
EOF

# ===========================================================================
# 1. Root CA
# ===========================================================================
echo "==> [1/7] Generating Root CA"
openssl genrsa -out "$OUTDIR/root-ca.key" 4096
openssl req -x509 -new -nodes -key "$OUTDIR/root-ca.key" -sha256 -days "$DAYS" \
  -subj "${SUBJECT_BASE}/CN=RHCL PoC Root CA" \
  -out "$OUTDIR/root-ca.crt"

# ===========================================================================
# 2. Intermediate CA (signed by Root) — issuer, CRL signer, OCSP responder
# ===========================================================================
echo "==> [2/7] Generating Intermediate CA"
openssl genrsa -out "$OUTDIR/intermediate-ca.key" 4096
openssl req -new -key "$OUTDIR/intermediate-ca.key" \
  -subj "${SUBJECT_BASE}/CN=RHCL PoC Intermediate CA" \
  -out "$OUTDIR/intermediate-ca.csr"

cat > "$OUTDIR/intermediate-ca.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
EOF

openssl x509 -req -in "$OUTDIR/intermediate-ca.csr" \
  -CA "$OUTDIR/root-ca.crt" -CAkey "$OUTDIR/root-ca.key" -CAcreateserial \
  -out "$OUTDIR/intermediate-ca.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/intermediate-ca.ext"

# ===========================================================================
# 3. Server certificate (issued via `openssl ca` so OCSP can look it up)
# ===========================================================================
echo "==> [3/7] Generating server certificate"
openssl genrsa -out "$OUTDIR/server.key" 2048
openssl req -new -key "$OUTDIR/server.key" \
  -subj "${SUBJECT_BASE}/CN=req050-crl.${DOMAIN}" \
  -out "$OUTDIR/server.csr"

openssl ca -batch -config "$OUTDIR/openssl.cnf" -extensions server_ext \
  -in "$OUTDIR/server.csr" -out "$OUTDIR/server.crt"

# Full chain for the TLS secret (server + intermediate + root)
cat "$OUTDIR/server.crt" "$OUTDIR/intermediate-ca.crt" "$OUTDIR/root-ca.crt" \
  > "$OUTDIR/server-fullchain.crt"

# ===========================================================================
# 4. Client "valid" (issued via `openssl ca`, NOT revoked)
# ===========================================================================
echo "==> [4/7] Generating client cert 'valid'"
openssl genrsa -out "$OUTDIR/client-valid.key" 2048
openssl req -new -key "$OUTDIR/client-valid.key" \
  -subj "${SUBJECT_BASE}/CN=banking-client-valid" \
  -out "$OUTDIR/client-valid.csr"
openssl ca -batch -config "$OUTDIR/openssl.cnf" -extensions client_ext \
  -in "$OUTDIR/client-valid.csr" -out "$OUTDIR/client-valid.crt"

# ===========================================================================
# 5. Client "revoked" (issued, then revoked → appears in the CRL)
# ===========================================================================
echo "==> [5/7] Generating client cert 'revoked' and revoking it"
openssl genrsa -out "$OUTDIR/client-revoked.key" 2048
openssl req -new -key "$OUTDIR/client-revoked.key" \
  -subj "${SUBJECT_BASE}/CN=banking-client-revoked" \
  -out "$OUTDIR/client-revoked.csr"
openssl ca -batch -config "$OUTDIR/openssl.cnf" -extensions client_ext \
  -in "$OUTDIR/client-revoked.csr" -out "$OUTDIR/client-revoked.crt"

openssl ca -batch -config "$OUTDIR/openssl.cnf" \
  -revoke "$OUTDIR/client-revoked.crt" -crl_reason keyCompromise

# CRL signed by the Intermediate CA (lists client-revoked)
openssl ca -batch -config "$OUTDIR/openssl.cnf" -gencrl -out "$OUTDIR/crl.pem"

# ===========================================================================
# 6. OCSP response for the SERVER cert (the staple) — status "good"
#    Signed by the Intermediate CA acting as its own OCSP responder.
# ===========================================================================
echo "==> [6/7] Generating OCSP staple for the server cert"
openssl ocsp \
  -index "$OUTDIR/index.txt" \
  -CA "$OUTDIR/intermediate-ca.crt" \
  -rsigner "$OUTDIR/intermediate-ca.crt" \
  -rkey "$OUTDIR/intermediate-ca.key" \
  -issuer "$OUTDIR/intermediate-ca.crt" \
  -cert "$OUTDIR/server.crt" \
  -ndays "$OCSP_DAYS" \
  -respout "$OUTDIR/server-ocsp.der"

# ===========================================================================
# 7. Untrusted CA + client cert (proves unknown-CA rejection)
# ===========================================================================
echo "==> [7/7] Generating untrusted CA + client cert"
openssl genrsa -out "$OUTDIR/untrusted-ca.key" 4096
openssl req -x509 -new -nodes -key "$OUTDIR/untrusted-ca.key" -sha256 -days "$DAYS" \
  -subj "${SUBJECT_BASE}/CN=Untrusted External CA" \
  -out "$OUTDIR/untrusted-ca.crt"

openssl genrsa -out "$OUTDIR/client-untrusted.key" 2048
openssl req -new -key "$OUTDIR/client-untrusted.key" \
  -subj "${SUBJECT_BASE}/CN=untrusted-client" \
  -out "$OUTDIR/client-untrusted.csr"

cat > "$OUTDIR/client-untrusted.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EOF

openssl x509 -req -in "$OUTDIR/client-untrusted.csr" \
  -CA "$OUTDIR/untrusted-ca.crt" -CAkey "$OUTDIR/untrusted-ca.key" -CAcreateserial \
  -out "$OUTDIR/client-untrusted.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/client-untrusted.ext"

# ===========================================================================
# Cleanup temp files (keep index.txt/crl/ocsp artifacts)
# ===========================================================================
rm -f "$OUTDIR"/*.csr "$OUTDIR"/*.ext "$OUTDIR"/*.old "$OUTDIR"/*.attr

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "============================================================"
echo "  PKI generated in: $OUTDIR/"
echo "  Domain:           $DOMAIN"
echo "  CRL:              $OUTDIR/crl.pem (revoked: banking-client-revoked)"
echo "  OCSP staple:      $OUTDIR/server-ocsp.der (valid ${OCSP_DAYS} days)"
echo "============================================================"
echo ""
echo "CRL contents:"
openssl crl -in "$OUTDIR/crl.pem" -noout -text | sed -n '1,20p'
echo ""

NS="req050-gateway"
cat <<EOF
------------------------------------------------------------
  Kubernetes commands to create Secrets
------------------------------------------------------------

# -- Server TLS Secret (used by both listeners; mounted for OCSP staple) --
oc -n $NS create secret tls req050-server-tls \\
  --cert=$OUTDIR/server-fullchain.crt \\
  --key=$OUTDIR/server.key

# -- Intermediate CA (mTLS trust anchor for both listeners) --
oc -n $NS create secret generic req050-intermediate-ca \\
  --from-file=ca.crt=$OUTDIR/intermediate-ca.crt

# -- CRL (mounted for the CRL listener) --
oc -n $NS create secret generic req050-crl \\
  --from-file=crl.pem=$OUTDIR/crl.pem

# -- OCSP staple (mounted for the OCSP listener) --
oc -n $NS create secret generic req050-ocsp-staple \\
  --from-file=server-ocsp.der=$OUTDIR/server-ocsp.der

------------------------------------------------------------
  Test commands (after the Gateway is running)
------------------------------------------------------------

# === CRL listener (trusts Intermediate; rejects revoked clients) ===

# PASS — valid client
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-valid.crt --key $OUTDIR/client-valid.key \\
  https://req050-crl.${DOMAIN}/api/tls/info

# FAIL — revoked client (rejected by CRL check)
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-revoked.crt --key $OUTDIR/client-revoked.key \\
  https://req050-crl.${DOMAIN}/api/tls/info

# === OCSP listener (server staples its OCSP response) ===

# Inspect the stapled OCSP response (look for "OCSP Response Status: successful"
# and "Cert Status: good")
openssl s_client -connect req050-ocsp.${DOMAIN}:443 \\
  -servername req050-ocsp.${DOMAIN} -status \\
  -cert $OUTDIR/client-valid.crt -key $OUTDIR/client-valid.key </dev/null
EOF
