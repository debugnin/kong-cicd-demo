#!/usr/bin/env bash
#
# deploy-vault.sh
# Install HashiCorp Vault in the local kind cluster, in dev mode.
#
# What dev mode gives you:
#   - Single in-memory instance, auto-unsealed
#   - KV v2 enabled at secret/
#   - Root token known up-front (default: "root")
#   - No persistence — restarting wipes everything
#
# Usage:
#   deploy-vault.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Kubernetes namespace (default: vault)
#   -r, --release NAME     Helm release name (default: vault)
#   -t, --token TOKEN      Root token to seed (default: root)
#   --no-wait              Do not pass --wait to helm
#   -h, --help             Show this help
#

set -euo pipefail

NAMESPACE="vault"
RELEASE="vault"
ROOT_TOKEN="root"
WAIT_FLAG="--wait"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -t|--token)     ROOT_TOKEN="$2"; shift 2 ;;
    --no-wait)      WAIT_FLAG=""; shift ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH."
done

info "Cluster context : $(kubectl config current-context)"
info "Namespace       : $NAMESPACE"
info "Release         : $RELEASE"
info "Root token      : $ROOT_TOKEN"

info "Adding HashiCorp Helm repo..."
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

info "Installing Vault (dev mode)..."
helm upgrade --install "$RELEASE" hashicorp/vault \
  -n "$NAMESPACE" --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=$ROOT_TOKEN" \
  --set "ui.enabled=true" \
  $WAIT_FLAG

echo
ok "Vault deployed."
kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
  Next steps
──────────────────────────────────────────────────────────────────────────────

  Port-forward the API/UI:
    kubectl -n $NAMESPACE port-forward svc/$RELEASE 8200:8200 &

  Point the Vault Terraform provider at it:
    export VAULT_ADDR=http://localhost:8200
    export VAULT_TOKEN=$ROOT_TOKEN

  Verify the KV v2 mount exists at secret/:
    vault secrets list | grep '^secret/'

  Then in terraform-platform-cp/:
    terraform plan
    terraform apply

  Vault UI: http://localhost:8200/ui  (token: $ROOT_TOKEN)

EOF
