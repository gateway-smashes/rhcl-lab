#!/usr/bin/env bash
# Generate a full PKI for REQ 051 + 056 mTLS gateway testing.
#
# Hierarchy:
#   Root CA (self-signed)
#    └── Intermediate CA (signed by Root)
#         ├── Server cert (SAN=*.$DOMAIN, req051-mtls.$DOMAIN, req056-mtls.$DOMAIN)
#         ├── Client cert "chain" (CN=banking-client-chain, signed by Intermediate)
#         └── Client cert "direct" (CN=banking-client-direct, signed by Root)
#
#   Untrusted CA (self-signed, unrelated)
#    └── Client cert "untrusted" (CN=untrusted-client)
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=sandbox2314.opentlc.com
#   ./generate-certs.sh
#
# Outputs land in ./certs/ (git-ignored). At the end the script prints
# oc/kubectl commands to create the Secrets and ConfigMaps expected by the
# Gateway manifest.

set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="${RHCL_ZONE_ROOT_DOMAIN:-example.com}"
OUTDIR="./certs"
DAYS="${DAYS:-825}"
SUBJECT_BASE="/C=BR/ST=DF/L=Brasilia/O=RHCL-PoC"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# ===========================================================================
# 1. Root CA
# ===========================================================================
echo "==> [1/7] Generating Root CA"
openssl genrsa -out "$OUTDIR/root-ca.key" 4096
openssl req -x509 -new -nodes -key "$OUTDIR/root-ca.key" -sha256 -days "$DAYS" \
  -subj "${SUBJECT_BASE}/CN=RHCL PoC Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$OUTDIR/root-ca.crt"

# ===========================================================================
# 2. Intermediate CA (signed by Root)
# ===========================================================================
echo "==> [2/7] Generating Intermediate CA"
openssl genrsa -out "$OUTDIR/intermediate-ca.key" 4096
openssl req -new -key "$OUTDIR/intermediate-ca.key" \
  -subj "${SUBJECT_BASE}/CN=RHCL PoC Intermediate CA" \
  -out "$OUTDIR/intermediate-ca.csr"

cat > "$OUTDIR/v3_intermediate_ca.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=critical,CA:TRUE,pathlen:0
subjectKeyIdentifier=hash
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
EOF

openssl x509 -req -in "$OUTDIR/intermediate-ca.csr" \
  -CA "$OUTDIR/root-ca.crt" -CAkey "$OUTDIR/root-ca.key" -CAcreateserial \
  -out "$OUTDIR/intermediate-ca.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/v3_intermediate_ca.ext"

# ===========================================================================
# 3. Server certificate (signed by Intermediate, multi-SAN)
# ===========================================================================
echo "==> [3/7] Generating server certificate"
openssl genrsa -out "$OUTDIR/server.key" 2048
openssl req -new -key "$OUTDIR/server.key" \
  -subj "${SUBJECT_BASE}/CN=req051-mtls.${DOMAIN}" \
  -out "$OUTDIR/server.csr"

cat > "$OUTDIR/server.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1 = req051-mtls.${DOMAIN}
DNS.2 = req056-mtls.${DOMAIN}
DNS.3 = *.${DOMAIN}
EOF

openssl x509 -req -in "$OUTDIR/server.csr" \
  -CA "$OUTDIR/intermediate-ca.crt" -CAkey "$OUTDIR/intermediate-ca.key" -CAcreateserial \
  -out "$OUTDIR/server.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/server.ext"

# Build full chain for the TLS secret (server + intermediate + root)
cat "$OUTDIR/server.crt" "$OUTDIR/intermediate-ca.crt" "$OUTDIR/root-ca.crt" \
  > "$OUTDIR/server-fullchain.crt"

# ===========================================================================
# 4. Client cert "direct" (signed directly by Root CA)
# ===========================================================================
echo "==> [4/7] Generating client cert 'direct' (signed by Root CA)"
openssl genrsa -out "$OUTDIR/client-direct.key" 2048
openssl req -new -key "$OUTDIR/client-direct.key" \
  -subj "${SUBJECT_BASE}/CN=banking-client-direct" \
  -out "$OUTDIR/client-direct.csr"

cat > "$OUTDIR/client-direct.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EOF

openssl x509 -req -in "$OUTDIR/client-direct.csr" \
  -CA "$OUTDIR/root-ca.crt" -CAkey "$OUTDIR/root-ca.key" -CAcreateserial \
  -out "$OUTDIR/client-direct.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/client-direct.ext"

# ===========================================================================
# 5. Client cert "chain" (signed by Intermediate CA)
# ===========================================================================
echo "==> [5/7] Generating client cert 'chain' (signed by Intermediate CA)"
openssl genrsa -out "$OUTDIR/client-chain.key" 2048
openssl req -new -key "$OUTDIR/client-chain.key" \
  -subj "${SUBJECT_BASE}/CN=banking-client-chain" \
  -out "$OUTDIR/client-chain.csr"

cat > "$OUTDIR/client-chain.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EOF

openssl x509 -req -in "$OUTDIR/client-chain.csr" \
  -CA "$OUTDIR/intermediate-ca.crt" -CAkey "$OUTDIR/intermediate-ca.key" -CAcreateserial \
  -out "$OUTDIR/client-chain.crt" -days "$DAYS" -sha256 \
  -extfile "$OUTDIR/client-chain.ext"

# Bundle: client leaf + intermediate (client sends full chain in TLS handshake)
cat "$OUTDIR/client-chain.crt" "$OUTDIR/intermediate-ca.crt" \
  > "$OUTDIR/client-chain-bundle.crt"

# Full bundle: client leaf + intermediate + ROOT (client sends the whole chain
# up to the self-signed root). Used to test the single-CA listener (trusts only
# the Intermediate) when the client also presents the untrusted root.
cat "$OUTDIR/client-chain.crt" "$OUTDIR/intermediate-ca.crt" "$OUTDIR/root-ca.crt" \
  > "$OUTDIR/client-chain-fullchain.crt"

# ===========================================================================
# 6. Untrusted CA + client cert (proves chain closure)
# ===========================================================================
echo "==> [6/7] Generating untrusted CA + client cert"
openssl genrsa -out "$OUTDIR/untrusted-ca.key" 4096
openssl req -x509 -new -nodes -key "$OUTDIR/untrusted-ca.key" -sha256 -days "$DAYS" \
  -subj "${SUBJECT_BASE}/CN=Untrusted External CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
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
# 7. Cleanup temp files
# ===========================================================================
echo "==> [7/7] Cleaning up"
rm -f "$OUTDIR"/*.csr "$OUTDIR"/*.ext "$OUTDIR"/*.srl

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "============================================================"
echo "  PKI generated in: $OUTDIR/"
echo "  Domain:           $DOMAIN"
echo "============================================================"
echo ""
echo "Files:"
ls -1 "$OUTDIR/"
echo ""
echo "------------------------------------------------------------"
echo "  Kubernetes commands to create Secrets"
echo "------------------------------------------------------------"
echo ""

NS="req051-gateway"

cat <<EOF
# -- Server TLS Secret (used by both Gateway listeners) --
oc -n $NS create secret tls req051-server-tls \\
  --cert=$OUTDIR/server-fullchain.crt \\
  --key=$OUTDIR/server.key

# -- Secret: Intermediate CA (for single-CA EnvoyFilter / REQ 056) --
# Istio SDS mounts secrets under /etc/istio/<secret-name>/
oc -n $NS create secret generic req051-intermediate-ca-sdscert \\
  --from-file=ca.crt=$OUTDIR/intermediate-ca.crt

# -- Secret: Root CA (for chain-CA EnvoyFilter / REQ 051) --
oc -n $NS create secret generic req051-root-ca-sdscert \\
  --from-file=ca.crt=$OUTDIR/root-ca.crt

# -- Verify --
oc -n $NS get secret req051-server-tls req051-intermediate-ca-sdscert req051-root-ca-sdscert
EOF

echo ""
echo "------------------------------------------------------------"
echo "  Test commands (after Gateway is running)"
echo "------------------------------------------------------------"
echo ""

cat <<EOF
# === REQ 056: Single-CA validation (trusts Intermediate only) ===

# PASS — client cert signed by Intermediate
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-chain.crt --key $OUTDIR/client-chain.key \\
  https://req056-mtls.${DOMAIN}/api/tls/info

# FAIL — client cert signed by Root (not directly trusted by this listener)
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-direct.crt --key $OUTDIR/client-direct.key \\
  https://req056-mtls.${DOMAIN}/api/tls/info

# FAIL — untrusted CA
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-untrusted.crt --key $OUTDIR/client-untrusted.key \\
  https://req056-mtls.${DOMAIN}/api/tls/info

# === REQ 051: Chain-CA validation (trusts Root only) ===

# PASS — client cert signed by Intermediate, sends full chain bundle
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-chain-bundle.crt --key $OUTDIR/client-chain.key \\
  https://req051-mtls.${DOMAIN}/api/tls/info

# PASS — client cert signed directly by Root
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-direct.crt --key $OUTDIR/client-direct.key \\
  https://req051-mtls.${DOMAIN}/api/tls/info

# FAIL — untrusted CA
curl -v --cacert $OUTDIR/root-ca.crt \\
  --cert $OUTDIR/client-untrusted.crt --key $OUTDIR/client-untrusted.key \\
  https://req051-mtls.${DOMAIN}/api/tls/info

# === No client cert at all (must fail on both) ===
curl -v --cacert $OUTDIR/root-ca.crt \\
  https://req051-mtls.${DOMAIN}/api/tls/info

curl -v --cacert $OUTDIR/root-ca.crt \\
  https://req056-mtls.${DOMAIN}/api/tls/info
EOF
