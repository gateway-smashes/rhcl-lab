#!/usr/bin/env bash
# Generate a self-signed CA + server certificate + (optional) client certificate
# for the Quarkus `tls` profile. Files land in this directory and are git-ignored.
#
# Usage:
#   ./generate-certs.sh
#
# Outputs:
#   ca.crt / ca.key       - self-signed CA used to sign the server cert and to
#                           validate client certificates when client-auth=request.
#   server.crt / server.key - server cert for `localhost`
#   client.crt / client.key - sample client cert for mTLS tests
#
# After running, start the backend with:
#   mvn quarkus:dev -Dquarkus.profile=tls
# And test with:
#   curl -v --cacert ca.crt https://localhost:8443/api/v1/accounts/summary
#   curl -v --cacert ca.crt --cert client.crt --key client.key \
#        https://localhost:8443/api/v1/accounts/summary

set -euo pipefail

cd "$(dirname "$0")"

DAYS=${DAYS:-825}
SUBJECT_BASE="/C=BR/ST=DF/L=Brasilia/O=RHCL-PoC"

echo "==> Generating CA"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" \
  -subj "${SUBJECT_BASE}/CN=RHCL PoC CA" \
  -out ca.crt

echo "==> Generating server cert (CN=localhost)"
openssl genrsa -out server.key 2048
openssl req -new -key server.key \
  -subj "${SUBJECT_BASE}/CN=localhost" \
  -out server.csr
cat > server.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = banking-api
IP.1  = 127.0.0.1
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" -sha256 -extfile server.ext

echo "==> Generating client cert (CN=banking-client)"
openssl genrsa -out client.key 2048
openssl req -new -key client.key \
  -subj "${SUBJECT_BASE}/CN=banking-client" \
  -out client.csr
cat > client.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days "$DAYS" -sha256 -extfile client.ext

rm -f server.csr server.ext client.csr client.ext ca.srl
echo "==> Done. Files:"
ls -1 ca.crt ca.key server.crt server.key client.crt client.key
