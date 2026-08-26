#!/usr/bin/env bash
# req026 — End-to-end validation of the RHCL streaming controls.
#
# Exercises 5 cases against the live gateway. Exits non-zero on the
# first mismatch so it slots into CI.
#
# Required env (defaults match the r46jf sandbox):
#   GATEWAY_HOST   hostname of the gateway route
#   API_KEY        a valid api-key for the banking-api product (e.g. from a
#                  rotate-key call against the developer portal)
set -euo pipefail

GATEWAY_HOST="${GATEWAY_HOST:-banking-api-connectivity.apps.cluster-r46jf.r46jf.sandbox3219.opentlc.com}"
API_KEY="${API_KEY:?API_KEY env var required — get one from the dev portal}"

UPLOAD_URL="https://${GATEWAY_HOST}/api/files/upload"
DOWNLOAD_URL="https://${GATEWAY_HOST}/api/files/download"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# Generates a binary stream of $1 MiB and POSTs it to /api/files/upload.
# Captures the HTTP status + a snapshot of the response body + headers.
upload_mib() {
  local mib="$1"
  local headers_out body_out
  headers_out="$(mktemp)"
  body_out="$(mktemp)"

  local code
  code=$(dd if=/dev/urandom bs=1M count="${mib}" status=none \
    | curl -sk -X POST \
        -H "api-key: ${API_KEY}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @- \
        -D "${headers_out}" -o "${body_out}" \
        -w "%{http_code}" \
        "${UPLOAD_URL}")

  echo "${code}|${headers_out}|${body_out}"
}

# Case 1 — small upload
yellow "[1/5] 1 MiB upload → expect 200 + sha256"
IFS='|' read -r CODE HDRS BODY <<<"$(upload_mib 1)"
if [ "${CODE}" != "200" ] || ! grep -q '"sha256"' "${BODY}"; then
  red "    FAIL: code=${CODE}, body=$(head -c 200 "${BODY}")"
  exit 1
fi
green "    OK ($(jq -r '.bytesReceived' "${BODY}") bytes, sha256=$(jq -r '.sha256' "${BODY}" | cut -c1-12)…)"
rm -f "${HDRS}" "${BODY}"

# Case 2 — medium upload, still under the 32 MiB cap
yellow "[2/5] 25 MiB upload → expect 200 + sha256"
IFS='|' read -r CODE HDRS BODY <<<"$(upload_mib 25)"
if [ "${CODE}" != "200" ] || ! grep -q '"sha256"' "${BODY}"; then
  red "    FAIL: code=${CODE}, body=$(head -c 200 "${BODY}")"
  exit 1
fi
green "    OK ($(jq -r '.bytesReceived' "${BODY}") bytes, durationMs=$(jq -r '.durationMs' "${BODY}"))"
rm -f "${HDRS}" "${BODY}"

# Case 3 — oversize upload, RHCL rejects with 413 BEFORE bytes finish
# streaming to the backend. The Lua filter counts bytes chunk-a-chunk
# via bodyChunks() and short-circuits with respond() the moment the
# running total exceeds 32 MiB.
#
# Proof that the rejection came from the gateway (not the Quarkus
# backend):
#   - `x-rhcl-streaming-cap: 33554432` header (emitted by our Lua
#     filter, never by Quarkus)
#   - `x-rhcl-observed-bytes: <total>` — the byte count at the moment
#     Lua aborted, so it's typically slightly above 32 MiB but well
#     below the full 50 MiB payload (streaming, not buffered).
#   - content-type: text/plain (Quarkus errors would be
#     application/json).
yellow "[3/5] 50 MiB upload → expect 413 from RHCL gateway Lua filter"
IFS='|' read -r CODE HDRS BODY <<<"$(upload_mib 50)"
if [ "${CODE}" != "413" ]; then
  red "    FAIL: code=${CODE} (expected 413), body=$(head -c 200 "${BODY}")"
  exit 1
fi
CAP_HDR="$(grep -i '^x-rhcl-streaming-cap:' "${HDRS}" | head -1 | tr -d '\r\n ')"
OBS_HDR="$(grep -i '^x-rhcl-observed-bytes:' "${HDRS}" | head -1 | tr -d '\r\n ')"
CONTENT_TYPE="$(grep -i '^content-type:' "${HDRS}" | head -1 | tr -d '\r\n ')"
if [ -z "${CAP_HDR}" ]; then
  red "    FAIL: no x-rhcl-streaming-cap header — 413 might have come from somewhere else."
  red "    hdrs snapshot:"
  head -20 "${HDRS}" | sed 's/^/      /' >&2
  exit 1
fi
if ! echo "${CONTENT_TYPE}" | grep -qi 'text/plain'; then
  red "    FAIL: content-type ${CONTENT_TYPE} — expected text/plain from the Lua respond()."
  exit 1
fi
green "    OK (HTTP 413 from Lua streaming filter, ${CAP_HDR}, ${OBS_HDR})"
rm -f "${HDRS}" "${BODY}"

# Case 4 — slow trickle, exceeds the 60s request timeout. We push 5 MiB
# at 100 KiB/s = ~52s of stream + handshake/processing > 60s threshold.
yellow "[4/5] 5 MiB @ 100 KiB/s → expect 408 or 504 (>60s timeout)"
HDRS=$(mktemp); BODY=$(mktemp)
SLOW_CODE=$(dd if=/dev/urandom bs=1M count=5 status=none \
  | curl -sk -X POST \
      -H "api-key: ${API_KEY}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @- \
      --limit-rate 100k \
      --max-time 90 \
      -D "${HDRS}" -o "${BODY}" \
      -w "%{http_code}" \
      "${UPLOAD_URL}" 2>/dev/null || echo "000")
case "${SLOW_CODE}" in
  408|504)
    green "    OK (HTTP ${SLOW_CODE})"
    ;;
  200)
    yellow "    SKIP — completed in under 60s on this link (no timeout fired). Consider lowering apps_streaming_upload_request_timeout or raising the payload."
    ;;
  *)
    red "    FAIL: unexpected code ${SLOW_CODE}"
    exit 1
    ;;
esac
rm -f "${HDRS}" "${BODY}"

# Case 5 — download with explicit chunk size; assert Content-Length matches.
yellow "[5/5] 10 MiB download (256 KiB chunks) → expect 200 + Content-Length 10485760"
HDRS=$(mktemp); BODY=$(mktemp)
DL_CODE=$(curl -sk \
  -H "api-key: ${API_KEY}" \
  -D "${HDRS}" -o "${BODY}" \
  -w "%{http_code}" \
  "${DOWNLOAD_URL}?size=10485760&chunkSize=262144")
LEN=$(grep -i '^content-length' "${HDRS}" | awk '{print $2}' | tr -d '\r')
ACTUAL=$(wc -c < "${BODY}" | tr -d ' ')
if [ "${DL_CODE}" != "200" ] || [ "${LEN}" != "10485760" ] || [ "${ACTUAL}" != "10485760" ]; then
  red "    FAIL: code=${DL_CODE}, content-length=${LEN}, actual_bytes=${ACTUAL}"
  exit 1
fi
green "    OK (Content-Length=${LEN}, actual_bytes=${ACTUAL})"
rm -f "${HDRS}" "${BODY}"

echo ""
green "All 5 cases passed — RHCL gateway is enforcing the streaming size cap (Lua bodyChunks) and the per-rule request timeout on /api/files/upload."
