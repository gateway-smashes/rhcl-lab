#!/usr/bin/env bash
# cluster-env.sh — Discovery de variáveis do cluster para os playbooks RHCL.
#
# Auto-detecta o perfil do cluster e exporta os defaults certos
# para cada cenário. Em seguida carrega segredos do ~/cluster-secrets.sh
# (preferido) ou automation/cluster-secrets.sh (project-local fallback).
#
# Uso:
#   source automation/scripts/cluster-env.sh                    # auto-detect
#   source automation/scripts/cluster-env.sh --profile=aws      # força AWS lab
#   source automation/scripts/cluster-env.sh --dry-run          # só imprime
#   source automation/scripts/cluster-env.sh --quiet            # sem print
#
# Perfis:
#   aws-lab    — sandbox/lab Red Hat. AWS LoadBalancer. Let's Encrypt.
#                Build local de imagens.
#   other      — fallback. Discovery aplicado, sem ajustes de perfil.
#
# Sinais de detecção (em ordem de prioridade):
#   1. --profile=X explicito vence tudo
#   2. Infrastructure.status.platform == AWS       → aws-lab
#   3. cluster domain contém '.opentlc.com'        → aws-lab
#   4. (nada acima)                                 → other

# IMPORTANTE: este script é feito para ser executado com `source` (ele exporta
# variáveis no shell atual). Por isso NÃO use `set -e`: com errexit ativo, um
# único comando que retorne ≠ 0 durante o source derruba o shell interativo do
# usuário (em bash e, de forma ainda mais agressiva, em zsh) — e o errexit ainda
# "vaza" para o shell depois. Os pontos fatais usam `return N 2>/dev/null ||
# exit N`; o restante degrada com `_warn` / `|| true`.

# Caminho deste próprio script — resolve corretamente com `source` tanto em bash
# (BASH_SOURCE) quanto em zsh (BASH_SOURCE não existe → cai em $0, que o zsh
# define para o arquivo sourceado). Sem isso, BASH_SOURCE vazio em zsh quebra o
# caminho do cluster-secrets.sh e do --help.
_SELF_PATH="${BASH_SOURCE[0]:-$0}"

PROFILE_OVERRIDE=""
QUIET=false
DRYRUN=false
for arg in "$@"; do
  case "$arg" in
    --profile=*) PROFILE_OVERRIDE="${arg#*=}" ;;
    --quiet)     QUIET=true ;;
    --dry-run)   DRYRUN=true ;;
    --help|-h)
      sed -n '2,30p' "$_SELF_PATH" | sed 's/^# \{0,1\}//'
      return 0 2>/dev/null || exit 0
      ;;
  esac
done

_log() { ${QUIET} || echo "[cluster-env] $*" >&2; }
_warn() { ${QUIET} || echo "[cluster-env] ⚠ $*" >&2; }
_export() {
  ${DRYRUN} && { echo "export $1=\"$2\""; return; }
  export "$1=$2"
}

# ============================================================
# Sanity check — oc logado
# ============================================================
if ! oc whoami >/dev/null 2>&1; then
  echo "[cluster-env] ERRO: 'oc' não está conectado a nenhum cluster." >&2
  echo "[cluster-env]        Execute 'oc login <api-server>' antes de chamar este script." >&2
  return 1 2>/dev/null || exit 1
fi

CLUSTER=$(oc whoami --show-server 2>/dev/null | sed -E 's|https?://api\.||;s|:6443$||')
USER=$(oc whoami)
_log "Cluster: $CLUSTER (user: $USER)"

# ============================================================
# Detecção de perfil
# ============================================================
PROFILE=""
if [[ -n "$PROFILE_OVERRIDE" ]]; then
  PROFILE="$PROFILE_OVERRIDE"
  # Aceita a forma curta documentada no header (--profile=aws).
  [[ "$PROFILE" == "aws" ]] && PROFILE="aws-lab"
  _log "Perfil: $PROFILE (override via --profile)"
else
  PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$PLATFORM" == "aws" ]] || [[ "$CLUSTER" == *.opentlc.com ]]; then
    PROFILE="aws-lab"
    _log "Perfil: aws-lab (platform=AWS ou cluster .opentlc.com)"
  else
    PROFILE="other"
    _log "Perfil: other (platform=$PLATFORM)"
  fi
fi

# ============================================================
# Discovery comum a todos os perfis
# ============================================================

# Zone domain — sempre vem do Infrastructure
ZONE_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
[[ -n "$ZONE_DOMAIN" ]] && _export RHCL_ZONE_ROOT_DOMAIN "$ZONE_DOMAIN"
_log "  RHCL_ZONE_ROOT_DOMAIN=$ZONE_DOMAIN"

# ClusterIssuer — escolha por prioridade
ISSUER=""
for candidate in letsencrypt-prod letsencrypt-production-ec2 letsencrypt-production letsencrypt-staging self-signed; do
  if oc get clusterissuer "$candidate" >/dev/null 2>&1 \
     && [[ "$(oc get clusterissuer "$candidate" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; then
    ISSUER="$candidate"; break
  fi
done
if [[ -z "$ISSUER" ]]; then
  ISSUER=$(oc get clusterissuer -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
fi
if [[ -n "$ISSUER" ]]; then
  _export APPS_CONNECTIVITY_TLS_ISSUER_NAME "$ISSUER"
  _export APPS_CONNECTIVITY_TLS_ISSUER_KIND "ClusterIssuer"
  _log "  APPS_CONNECTIVITY_TLS_ISSUER_NAME=$ISSUER"
else
  _warn "Nenhum ClusterIssuer Ready — rode letsencrypt-install.yml antes de apps-install."
fi

# GatewayClass — escolha por prioridade
GWCLASS=""
for candidate in openshift-default istio; do
  if oc get gatewayclass "$candidate" >/dev/null 2>&1 \
     && [[ "$(oc get gatewayclass "$candidate" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == "True" ]]; then
    GWCLASS="$candidate"; break
  fi
done
[[ -z "$GWCLASS" ]] && GWCLASS=$(oc get gatewayclass -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Accepted")].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
if [[ -n "$GWCLASS" ]]; then
  _export GATEWAY_API_GATEWAYCLASS_NAME "$GWCLASS"
  _log "  GATEWAY_API_GATEWAYCLASS_NAME=$GWCLASS"
else
  _warn "Nenhuma GatewayClass Accepted — rode gateway_api-install.yml antes."
fi

# DNS provider — só pra AWS conseguimos detectar tudo
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "$PLATFORM" in
  aws)
    _export RHCL_DNS_PROVIDER "aws"
    AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null)
    [[ -n "$AWS_REGION" ]] && _export RHCL_DNS_AWS_REGION "$AWS_REGION"
    _log "  RHCL_DNS_PROVIDER=aws (region=$AWS_REGION)"
    ;;
  azure) _export RHCL_DNS_PROVIDER "azure"; _log "  RHCL_DNS_PROVIDER=azure" ;;
  gcp)   _export RHCL_DNS_PROVIDER "gcp";   _log "  RHCL_DNS_PROVIDER=gcp" ;;
  *)     _log "  RHCL_DNS_PROVIDER: platform '$PLATFORM' não casa AWS/Azure/GCP — setar manual no cluster-secrets" ;;
esac

# Defaults convencionais (todos os perfis)
_export APPS_NAMESPACE "${APPS_NAMESPACE:-rhcl-apps}"
_export APPS_CONNECTIVITY_GATEWAY_NAME "${APPS_CONNECTIVITY_GATEWAY_NAME:-rhcl-apps-gateway}"
_export APPS_CONNECTIVITY_GATEWAY_NAMESPACE "${APPS_CONNECTIVITY_GATEWAY_NAMESPACE:-openshift-ingress}"
# Frontend (mobile-bank, SPA estático) é servido pela OpenShift Route que
# o apps role cria por padrão — não consome policies do Kuadrant
# (sem APIKey/Auth/RateLimit). HTTPRoute + listener no Gateway eram
# redundantes em ambos os perfis (AWS lab e other).
_export APPS_CONNECTIVITY_FRONTEND_ROUTE_ENABLED "${APPS_CONNECTIVITY_FRONTEND_ROUTE_ENABLED:-false}"

# DNS namespace tem que casar com o Gateway namespace (Kuadrant DNSPolicy
# exige Secret e Gateway no mesmo ns). Default do all.yml é 'api-gateway',
# que não bate com 'openshift-ingress'.
_export RHCL_DNS_NAMESPACE "${RHCL_DNS_NAMESPACE:-$APPS_CONNECTIVITY_GATEWAY_NAMESPACE}"
_log "  RHCL_DNS_NAMESPACE=$RHCL_DNS_NAMESPACE (alinhado com gateway namespace)"

# ============================================================
# Defaults por perfil
# ============================================================
case "$PROFILE" in
  aws-lab)
    _log ""
    _log "=== Aplicando defaults do perfil AWS LAB ==="
    _export APPS_IMAGE_SOURCE "${APPS_IMAGE_SOURCE:-build}"
    _export APPS_CONNECTIVITY_GATEWAY_SERVICE_TYPE ""    # = LoadBalancer (cloud LB controller)
    _export APPS_CONNECTIVITY_GATEWAY_ELB_ANNOTATIONS_ENABLED "${APPS_CONNECTIVITY_GATEWAY_ELB_ANNOTATIONS_ENABLED:-true}"
    _export APPS_OPENSHIFT_ROUTE_ENABLED "false"
    _export APPS_BACKEND_CORS_ENABLED "${APPS_BACKEND_CORS_ENABLED:-false}"
    _log "  APPS_IMAGE_SOURCE=build (BuildConfig + oc start-build a partir do source)"
    _log "  APPS_CONNECTIVITY_GATEWAY_SERVICE_TYPE='' (LoadBalancer auto-provisionado)"
    _log "  APPS_CONNECTIVITY_GATEWAY_ELB_ANNOTATIONS_ENABLED=true (anotações TCP passthrough AWS ELB)"
    _log "  APPS_OPENSHIFT_ROUTE_ENABLED=false"
    ;;
  other)
    _log ""
    _log "=== Perfil 'other' — sem defaults específicos aplicados ==="
    _log "    Set manualmente as flags do seu ambiente:"
    _log "      APPS_IMAGE_SOURCE, APPS_CONNECTIVITY_GATEWAY_SERVICE_TYPE,"
    _log "      APPS_OPENSHIFT_ROUTE_ENABLED, etc."
    ;;
  *)
    _warn "Perfil '$PROFILE' desconhecido — esperado: aws-lab | other"
    ;;
esac

# ============================================================
# Carrega secrets (ordem: ~/ primeiro, depois project-local)
# ============================================================
SECRETS_LOADED=false
for secrets_file in "$HOME/cluster-secrets.sh" "$(dirname "$_SELF_PATH")/../cluster-secrets.sh"; do
  if [[ -f "$secrets_file" ]]; then
    _log ""
    _log "Carregando $secrets_file"
    # shellcheck source=/dev/null
    source "$secrets_file"
    SECRETS_LOADED=true
    break
  fi
done
if ! ${SECRETS_LOADED}; then
  _log ""
  _warn "Nenhum cluster-secrets.sh encontrado."
  _log "    Copie automation/scripts/cluster-secrets.sh.example pra ~/cluster-secrets.sh"
  _log "    ou pra automation/cluster-secrets.sh (project-local — já está no .gitignore)."
fi

# ============================================================
# Detecção de troca de sandbox — vars per-cluster que ficaram stale
# ============================================================
# Quando o usuário troca de sandbox AWS sem limpar ~/cluster-secrets.sh, o
# install-all completa silenciosamente e o ACME challenge fica pending pra
# sempre (InvalidClientTokenId → SignatureDoesNotMatch → NoSuchHostedZone).
# Avisamos aqui pra dar chance de corrigir antes do playbook rodar.
# Cache do último cluster em ~/.cache/rhcl-lab/last-cluster.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhcl-lab"
LAST_CLUSTER_FILE="$CACHE_DIR/last-cluster"
LAST_CLUSTER=""
[[ -f "$LAST_CLUSTER_FILE" ]] && LAST_CLUSTER=$(cat "$LAST_CLUSTER_FILE" 2>/dev/null || true)

if [[ -n "$LAST_CLUSTER" && "$LAST_CLUSTER" != "$CLUSTER" ]]; then
  _log ""
  _warn "Cluster mudou desde a última execução:"
  _warn "  anterior: $LAST_CLUSTER"
  _warn "  atual:    $CLUSTER"
  STALE_VARS=()
  [[ -n "${LETSENCRYPT_AWS_HOSTED_ZONE_ID:-}" ]] && STALE_VARS+=("LETSENCRYPT_AWS_HOSTED_ZONE_ID")
  [[ -n "${RHCL_DNS_AWS_ACCESS_KEY_ID:-}"   ]] && STALE_VARS+=("RHCL_DNS_AWS_ACCESS_KEY_ID")
  [[ -n "${RHCL_DNS_AWS_SECRET_ACCESS_KEY:-}" ]] && STALE_VARS+=("RHCL_DNS_AWS_SECRET_ACCESS_KEY")
  if (( ${#STALE_VARS[@]} > 0 )); then
    _warn "  As seguintes vars estão setadas e PODEM ser do cluster anterior:"
    for v in "${STALE_VARS[@]}"; do _warn "    - $v"; done
    _warn "  Se vieram de ~/cluster-secrets.sh hardcoded, remova-as de lá —"
    _warn "  o role letsencrypt auto-descobre via kube-system/aws-creds + Route53."
    _warn "  (Veja docs/cluster-secrets.md.)"
  fi
fi

# Persiste o cluster atual pra próxima invocação. Só em modo real, não --dry-run.
if ! ${DRYRUN}; then
  mkdir -p "$CACHE_DIR" 2>/dev/null && echo "$CLUSTER" > "$LAST_CLUSTER_FILE"
fi

_log ""
_log "Pronto. Veja todas as vars setadas:"
_log "  env | grep -E '^(RHCL_|APPS_|GATEWAY_API_|LETSENCRYPT_)' | sort"
