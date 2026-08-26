#!/usr/bin/env bash
# Force POSIX numeric locale so awk always uses "." as the decimal
# separator. Without this, on a pt-BR / pt-PT macOS shell every printf
# "%.2f" comes out as "0,00", and any later math on those strings breaks.
export LC_NUMERIC=C
# simulate-api-traffic.sh — generate weighted API-key traffic against the
# banking-api or pix-api HTTPRoute to populate the "Top consumers" ranking
# (and Traffic / Latency / Request rate charts) on the API Product detail
# page of the custom-rhcl-console plugin.
#
# What this script does
#   1. Auto-discovers the gateway hostname from the HTTPRoute.
#   2. Reads the API-key Secrets in `rhcl-apps` (auth.identity.metadata.name
#      is what shows up in the ranking — that's the Secret name).
#   3. Fires requests with a weighted distribution per consumer so the
#      ranking shows a clear ordering instead of a flat tie.
#   4. Sprinkles a few requests with a bogus key so a 401 bucket shows
#      up too — useful to demo success rate / response code charts.
#
# Why these particular weights
#   We want a visually unambiguous top-3 with a long tail. Alice (gold)
#   gets the lion's share, Bob (silver) about a third of that, Carol
#   (bronze) about a sixth. The extra "alice-apikey-secret" key (another
#   Secret bound to Alice) gets a sprinkle so the ranking shows
#   non-trivial entries that aren't the obvious user-id mapping.
#
# Usage
#   ./tests/simulate-api-traffic.sh                      # banking, 60s, ~5 rps
#   ./tests/simulate-api-traffic.sh --target=pix         # pix API (only 1 key — useful for sparkline / latency)
#   ./tests/simulate-api-traffic.sh --target=ai          # AI Gateway lens — chat completions, token budget + 429s
#   ./tests/simulate-api-traffic.sh --target=ai --rpm=30 # AI, gentle — a mix of ✓ and ⚠429 instead of near-all-429
#   ./tests/simulate-api-traffic.sh --duration=180       # 3 minutes
#   ./tests/simulate-api-traffic.sh --forever            # run until Ctrl-C (ignores --duration)
#   ./tests/simulate-api-traffic.sh --rps=15             # punchier — 15 req/s
#   ./tests/simulate-api-traffic.sh --rps=0.2            # gentle — 1 req every 5s (12 rpm)
#   ./tests/simulate-api-traffic.sh --rpm=30             # per-minute alias — same as --rps=0.5
#   ./tests/simulate-api-traffic.sh --bad-keys           # sprinkle invalid keys (every 20th)
#
# Quiet demo mode (background traffic that won't wake ops up):
#   ./tests/simulate-api-traffic.sh --forever --rpm=20 --bad-keys
#
# Single-key mode (use a key you generated in the Developer Portal):
#   ./tests/simulate-api-traffic.sh --key=bk_live_xxxxx
#   ./tests/simulate-api-traffic.sh --key=bk_live_xxx --rps=10 --duration=120
#   ./tests/simulate-api-traffic.sh --key=bk_live_xxx \
#       --host=banking-api-connectivity.apps.example.com \
#       --paths=/api/v1/accounts/summary,/api/whoami
#   # --host overrides HTTPRoute discovery; --paths is a comma-separated list;
#   # --header changes the credential header (default: api-key).
#
# Stop with Ctrl-C — the script reports totals on exit.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults / CLI
# ----------------------------------------------------------------------------
TARGET="banking"          # banking | pix
DURATION_S=60
FOREVER=false             # --forever: ignore --duration, run until Ctrl-C
RPS=5
BAD_KEYS=false
NS=rhcl-apps
KEY=""                    # single-key mode: a portal-generated API key
HOST_OVERRIDE=""          # override the gateway hostname (skip HTTPRoute discovery)
PATHS_CSV=""              # comma-separated list of paths to hit
HEADER="api-key"          # credential header name

for arg in "$@"; do
  case "$arg" in
    --target=*)   TARGET="${arg#*=}" ;;
    --duration=*) DURATION_S="${arg#*=}" ;;
    --forever)    FOREVER=true ;;
    --rps=*)      RPS="${arg#*=}" ;;
    # --rpm is a convenience alias — customer/demo mode usually thinks in
    # "requests per minute" ("30 rpm please, don't wake anyone up"),
    # while the engine sleeps between requests in fractional seconds. We
    # convert once here so the rest of the script only speaks --rps.
    # `awk` because bash arithmetic is integer-only — RPM=30 → RPS=0.5
    # would truncate to 0 with $((30/60)) and lock the loop into a
    # tight busy-spin.
    --rpm=*)      RPS=$(awk -v m="${arg#*=}" 'BEGIN { printf "%.6f", m/60 }') ;;
    --bad-keys)   BAD_KEYS=true ;;
    --key=*)      KEY="${arg#*=}" ;;
    --host=*)     HOST_OVERRIDE="${arg#*=}" ;;
    --paths=*)    PATHS_CSV="${arg#*=}" ;;
    --header=*)   HEADER="${arg#*=}" ;;
    --help|-h)
      sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done

case "$TARGET" in
  banking)
    ROUTE_NAME=banking-api-connectivity
    APP_LABEL=banking-api-apikey
    # Weighted consumer pool — Secret name : relative weight
    # (Secret name is what the ranking shows; we put the secret name first
    #  so the awk picker below can split easily.)
    CONSUMERS=(
      "banking-api-key-alice|alice-gold-secret|18"
      "banking-api-key-bob|bob-silver-secret|6"
      "banking-api-key-carol|carol-bronze-secret|3"
      "banking-api-alice-apikey-secret|a7_Jnxl7tPJBRhR2tEpGuXSdrDoeltVN5fgpEGqw1-k=|1"
    )
    # Path pool as "METHOD PATH" pairs. Method drives whether the
    # entry needs a JSON body (see maybe_body()); paths without an
    # explicit method default to GET at hit time. The mix covers
    # every /api/{v1,v2}/… surface Prometheus label
    # (`route_name`, `request_headers_x_consumer_id`) so the customer's
    # dashboards populate cells for both backends, both major methods,
    # AI inference, TLS metadata, and the public /echo heartbeat.
    #
    # `/api/whoami` is intentionally in the pool even though it may
    # 403 on clusters where the JWT rule is on — the failure surface
    # is itself useful (populates the "Auth denied" cells), and on
    # clusters WITHOUT JWT the endpoint answers 200 with api-key auth,
    # so it's a valid target either way.
    PATHS=(
      "GET  /api/v1/accounts/summary"
      "GET  /api/v2/accounts/summary"
      "GET  /api/echo"
      "GET  /api/whoami"
      "GET  /api/tls/info"
      "POST /api/v1/transfers"
      "POST /api/v2/transfers"
      "POST /api/v1/chat/completions"
    )
    ;;
  pix)
    ROUTE_NAME=pix-api-connectivity
    APP_LABEL=pix-api-keys
    CONSUMERS=(
      "pix-api-key-tester|pix-tester-secret|10"
    )
    PATHS=(
      "/pix/v1/balance"
      "/pix/v1/transfer"
      "/pix/v1/qrcode"
    )
    ;;
  ai)
    # AI Gateway lens — hammer the OpenAI-compatible chat route so the
    # TokenRateLimitPolicy (token budget) and the per-consumer token/cost
    # tables on the console's "AI Gateway" page light up. Same HTTPRoute and
    # API keys as `banking`; the only surface is /api/v1/chat/completions,
    # whose response `usage.total_tokens` is what the TokenRateLimitPolicy
    # meters — and 429s on once a site's per-minute token budget is spent.
    #
    # Budget is small (≈300 tokens/min) and each call is ≈40-50 tokens, so
    # only ~6 calls/min succeed. At the default 5 rps almost everything past
    # the first few seconds is a 429 — great for the Throttled KPI, punchy but
    # extreme. For a mix of ✓ and ⚠ that keeps the budget gauge near the cap,
    # run it gentle:  --target=ai --rpm=30
    ROUTE_NAME=banking-api-connectivity
    APP_LABEL=banking-api-apikey
    # alice=gold gets the lion's share, bob=silver a third, carol=bronze a sprinkle
    # (so the Consumers table shows a clear gold/silver/bronze ordering).
    CONSUMERS=(
      "banking-api-key-alice|alice-gold-secret|6"
      "banking-api-key-bob|bob-silver-secret|3"
      "banking-api-key-carol|carol-bronze-secret|1"
    )
    PATHS=(
      "POST /api/v1/chat/completions"
    )
    ;;
  *) echo "Unknown --target=$TARGET (use 'banking', 'pix' or 'ai')" >&2; exit 1 ;;
esac

# Single-key mode: a portal-generated key replaces the weighted consumer pool.
if [[ -n "$KEY" ]]; then
  CONSUMERS=( "portal-key|$KEY|1" )
fi

# Optional path override (comma-separated).
if [[ -n "$PATHS_CSV" ]]; then
  IFS=',' read -r -a PATHS <<<"$PATHS_CSV"
fi

# ----------------------------------------------------------------------------
# Discovery
# ----------------------------------------------------------------------------
if [[ -n "$HOST_OVERRIDE" ]]; then
  HOST="$HOST_OVERRIDE"
else
  if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: 'oc' not logged in (need it to discover the host — or pass --host=)." >&2
    exit 1
  fi
  # First hostname declared on the Gateway-API HTTPRoute. Uses the fully
  # qualified resource (`httproutes.gateway.networking.k8s.io`) so it
  # doesn't collide with other operators that also register an
  # `HTTPRoute` kind (e.g. Contour's `httproutes.projectcontour.io`,
  # OpenShift Serverless, etc.) on the same cluster — a bare
  # `oc get httproute` picks whichever match `oc` resolves first, which
  # on customer clusters is often the wrong one and returns no
  # hostname.
  HOST=$(oc get httproutes.gateway.networking.k8s.io "$ROUTE_NAME" -n "$NS" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)
  if [[ -z "$HOST" ]]; then
    echo "ERROR: could not find hostname on HTTPRoute (gateway.networking.k8s.io) $NS/$ROUTE_NAME (or pass --host=)." >&2
    exit 1
  fi
fi

BASE="https://$HOST"

# ----------------------------------------------------------------------------
# Build a tab-separated weighted pool that picker reads from.
# Each line: secret_name <TAB> raw_key <TAB> weight
# ----------------------------------------------------------------------------
POOL_FILE=$(mktemp)
trap 'rm -f "$POOL_FILE"' EXIT

for entry in "${CONSUMERS[@]}"; do
  IFS='|' read -r secret_name raw_key weight <<<"$entry"
  printf '%s\t%s\t%s\n' "$secret_name" "$raw_key" "$weight" >>"$POOL_FILE"
done

TOTAL_WEIGHT=$(awk -F'\t' '{s+=$3} END {print s}' "$POOL_FILE")

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
echo "================================================================"
echo "Target:    $TARGET  →  $BASE"
echo "Route:     $NS/$ROUTE_NAME (label app=$APP_LABEL)"
echo "Consumers: $(wc -l <"$POOL_FILE") secrets, total weight $TOTAL_WEIGHT"
if $FOREVER; then
  echo "Plan:      forever @ ~${RPS} rps  (bad-keys: $BAD_KEYS) — Ctrl-C to stop"
else
  echo "Plan:      ${DURATION_S}s @ ~${RPS} rps  (bad-keys: $BAD_KEYS)"
fi
echo "================================================================"

# Bash 3.2 (macOS default) has no associative arrays, so we accumulate
# into a temp log: one line per request as "<status>\t<secret_name>".
# `awk` does the grouping at the end. Slower than `declare -A` would be
# but trivial at the rates this script runs.
LOG=$(mktemp)
trap 'rm -f "$POOL_FILE" "$LOG"' EXIT

# Colors — only when stdout is a TTY and NO_COLOR is unset.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'; C_GREY=$'\033[90m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_GREEN=; C_YELLOW=; C_RED=; C_MAGENTA=; C_CYAN=; C_GREY=
fi

# Live tallies
N_2XX=0; N_3XX=0; N_429=0; N_4XX=0; N_5XX=0; N_000=0

# Classify a status code -> sets GLYPH and COLOR.
classify() {
  case "$1" in
    2*)   GLYPH="✓"; COLOR=$C_GREEN;   N_2XX=$((N_2XX+1)) ;;
    3*)   GLYPH="→"; COLOR=$C_CYAN;    N_3XX=$((N_3XX+1)) ;;
    429)  GLYPH="⚠"; COLOR=$C_YELLOW;  N_429=$((N_429+1)) ;;
    4*)   GLYPH="✗"; COLOR=$C_RED;     N_4XX=$((N_4XX+1)) ;;
    5*)   GLYPH="✗"; COLOR=$C_MAGENTA; N_5XX=$((N_5XX+1)) ;;
    *)    GLYPH="•"; COLOR=$C_GREY;    N_000=$((N_000+1)) ;;
  esac
}

tally_line() {
  local elapsed=$(( $(date +%s) - START ))
  local rate
  rate=$(awk -v r="$REQ_TOTAL" -v e="$elapsed" 'BEGIN { if (e > 0) printf "%.1f", r/e; else printf "0.0" }')
  printf '%s   ── %d reqs · %s%d ✓%s · %s%d ⚠429%s · %s%d ✗4xx%s · %s%d ✗5xx%s · %s%d •conn%s · %s rps ──%s\n' \
    "$C_BOLD" "$REQ_TOTAL" \
    "$C_GREEN" "$N_2XX" "$C_RESET$C_BOLD" \
    "$C_YELLOW" "$N_429" "$C_RESET$C_BOLD" \
    "$C_RED" "$N_4XX" "$C_RESET$C_BOLD" \
    "$C_MAGENTA" "$N_5XX" "$C_RESET$C_BOLD" \
    "$C_GREY" "$N_000" "$C_RESET$C_BOLD" \
    "$rate" "$C_RESET"
}

START=$(date +%s)
DEADLINE=$((START + DURATION_S))
# BSD awk (the macOS default) doesn't accept ternary `?:` in BEGIN — use
# straight `printf` here. Quoting is awkward because RPS is a shell var,
# so we substitute it directly into the awk program.
SLEEP_S=$(awk "BEGIN { printf \"%.3f\", 1 / $RPS }")
REQ_TOTAL=0
BAD_EVERY=20   # every 20th request goes with a bogus key when --bad-keys is set

# Ctrl-C in --forever mode should still print the tally + breakdown, not
# just kill the process silently. Flip the loop guard on SIGINT so the
# summary block below runs on the way out.
KEEP_RUNNING=true
trap 'KEEP_RUNNING=false; echo ""; echo "(Ctrl-C — finishing summary...)"' INT

while $KEEP_RUNNING && ( $FOREVER || [[ $(date +%s) -lt $DEADLINE ]] ); do
  # Decide: bogus key (every Nth) or weighted pick
  if $BAD_KEYS && (( REQ_TOTAL % BAD_EVERY == BAD_EVERY - 1 )); then
    secret_name="(bogus-key)"
    raw_key="this-is-not-a-real-key-$RANDOM"
  else
    # Weighted random pick: spin a [1..TOTAL_WEIGHT] number, walk cumulative.
    pick=$((RANDOM % TOTAL_WEIGHT + 1))
    selected=$(awk -F'\t' -v pick="$pick" '
      { cum += $3; if (cum >= pick) { print $1 "\t" $2; exit } }
    ' "$POOL_FILE")
    secret_name="${selected%%	*}"
    raw_key="${selected##*	}"
  fi

  # Pool entries are "METHOD PATH" — split at the first whitespace.
  # Bare paths (no method) default to GET so `--paths=...` overrides
  # from a customer keep working unchanged.
  entry=${PATHS[$((RANDOM % ${#PATHS[@]}))]}
  entry="${entry#"${entry%%[![:space:]]*}"}"   # ltrim
  if [[ "$entry" == *" "* ]]; then
    method=${entry%%[[:space:]]*}
    path=${entry#*[[:space:]]}
    path="${path#"${path%%[![:space:]]*}"}"    # ltrim path after method
  else
    method="GET"
    path="$entry"
  fi

  # Body pool per path — kept minimal (constant payload per endpoint).
  # The traffic simulator's job is to move labels through Prometheus,
  # not to fuzz the backend, so deterministic bodies keep replay
  # comparisons meaningful and don't spawn a real transfer flood.
  body=""
  case "$path" in
    /api/v1/transfers|/api/v2/transfers)
      body='{"fromBank":"Example Bank","toBank":"EXTERNAL","amount":1,"description":"simulate-api-traffic"}'
      ;;
    /api/v1/chat/completions)
      # model `banking-mock-gpt` is the one the mock inference backend answers
      # with a real `usage` block (prompt/completion/total_tokens) — that
      # total_tokens is what the TokenRateLimitPolicy meters. A "hi" prompt
      # bills ~1 token; this longer prompt bills ~40-50 so the token budget
      # actually fills (and 429s) at a demoable rate.
      body='{"model":"banking-mock-gpt","messages":[{"role":"user","content":"Explique em duas frases o que e rate limiting de tokens em um AI gateway e por que ele importa."}]}'
      ;;
  esac

  if [[ -n "$body" ]]; then
    out=$(curl -ks -o /dev/null -w '%{http_code} %{time_total}' \
      -X "$method" \
      -H "$HEADER: $raw_key" \
      -H "content-type: application/json" \
      -H "x-flow-trace-id: poc-$REQ_TOTAL-$RANDOM" \
      -d "$body" \
      "$BASE$path" 2>/dev/null || echo "000 0")
  else
    out=$(curl -ks -o /dev/null -w '%{http_code} %{time_total}' \
      -X "$method" \
      -H "$HEADER: $raw_key" \
      -H "x-flow-trace-id: poc-$REQ_TOTAL-$RANDOM" \
      "$BASE$path" 2>/dev/null || echo "000 0")
  fi
  status=${out%% *}
  ttime=${out##* }
  ms=$(awk -v t="$ttime" 'BEGIN { printf "%d", t*1000 }')

  printf '%s\t%s\n' "$status" "$secret_name" >>"$LOG"
  REQ_TOTAL=$((REQ_TOTAL + 1))

  # Live, color-coded line per request so success/failure is obvious at a glance.
  classify "$status"
  ts=$(date +%H:%M:%S)
  printf '%s  %s%s %-3s%s  %5sms  %-4s %-30s %s%s%s\n' \
    "$C_DIM$ts$C_RESET" \
    "$COLOR" "$GLYPH" "$status" "$C_RESET" \
    "$ms" \
    "$method" \
    "$path" \
    "$C_DIM" "$secret_name" "$C_RESET"

  # Compact running scoreboard every 20 requests.
  if (( REQ_TOTAL % 20 == 0 )); then tally_line; fi

  sleep "$SLEEP_S"
done

echo ""
tally_line
echo ""
echo "================================================================"
elapsed_total=$(( $(date +%s) - START ))
echo "Done: $REQ_TOTAL requests in ${elapsed_total}s"
echo ""
echo "By consumer (Secret name — shows up in Top consumers ranking):"
awk -F'\t' '{c[$2]++} END {for (k in c) printf "  %-45s %d\n", k, c[k]}' "$LOG" \
  | sort -k2 -nr
echo ""
echo "By HTTP status:"
awk -F'\t' '{c[$1]++} END {for (k in c) printf "  %-6s %d\n", k, c[k]}' "$LOG" \
  | sort
echo "================================================================"
echo ""
if [[ "$TARGET" == "ai" ]]; then
  echo "Next: open Connectivity Link → AI Gateway → wait ~60s"
  echo "      (token budget gauge, Throttled 429s and the Consumers table)"
else
  echo "Next: open Connectivity Link → API Products → $(echo "$TARGET" | tr '[:lower:]' '[:upper:]') → wait ~60s"
fi
echo "      (Prometheus scrape ~30s + plugin poll ~60s)"
