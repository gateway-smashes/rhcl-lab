#!/bin/sh
# Build env.json from a whitelist of environment variables so that the static
# test pages can read them at runtime (via fetch('/env.json')).
#
# Add new variables to ENV_VARS as needed — keep keys camelCased on the JSON
# side so they look natural in JS. Empty values are written as empty strings,
# which the pages treat as "not configured".
set -eu

OUT="${OUT:-/opt/app-root/src/env.json}"

# pairs: <env var name>=<json key>
#
# apiHost — hostname do gateway que expõe a banking-api/pix-api. As páginas
# interativas usam pra pré-preencher o campo "host" sem o operador precisar
# digitar. Vem da mesma env var que o Ansible (apps) usa
# (APPS_CONNECTIVITY_ROUTE_HOSTNAME). Quando ausente, as páginas caem no
# fallback window.location.host (= hostname do próprio catálogo).
ENV_VARS="
RHCL_ZONE_ROOT_DOMAIN=rhclZoneRootDomain
APPS_CONNECTIVITY_ROUTE_HOSTNAME=apiHost
THANOS_QUERIER_HOSTNAME=thanosQuerierHost
GRAFANA_ROUTE_HOSTNAME=grafanaHost
"

esc() { printf '%s' "$1" | sed 's|\\|\\\\|g; s|"|\\"|g'; }

body=$(echo "$ENV_VARS" | while IFS='=' read -r var key; do
  [ -z "$var" ] && continue
  [ -z "$key" ] && continue
  val=$(eval "printf '%s' \"\${$var:-}\"")
  printf ',"%s":"%s"' "$key" "$(esc "$val")"
done | sed 's/^,//')

printf '{%s}\n' "$body" > "$OUT"

echo "[env] wrote $OUT"
