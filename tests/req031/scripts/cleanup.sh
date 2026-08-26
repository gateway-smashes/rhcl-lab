#!/usr/bin/env bash
# Item 31 — remove TUDO que foi criado (manifests + RBAC). Idempotente.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-rhcl-apps}"

echo "==> Removendo o produto pix-api do ns $NS..."
oc -n "$NS" delete -f "$ROOT/manifests/05-apikey-cr.yaml" --ignore-not-found
oc -n "$NS" delete -f "$ROOT/manifests/04-apikey-secret.yaml" --ignore-not-found
oc -n "$NS" delete -f "$ROOT/manifests/03-authpolicy.yaml" --ignore-not-found
oc -n "$NS" delete -f "$ROOT/manifests/02-planpolicy.yaml" --ignore-not-found
oc -n "$NS" delete -f "$ROOT/manifests/01-apiproduct.yaml" --ignore-not-found
oc -n "$NS" delete httproute pix-api-connectivity --ignore-not-found
oc -n "$NS" delete -f "$ROOT/manifests/06-rbac.yaml" --ignore-not-found
echo "==> OK — limpo."
