#!/usr/bin/env bash
#
# deploy-dp.sh
# Deploy the Kong data plane onto the local kind cluster against a Konnect CP.
#
# What it does:
#   1. Verify kubectl and helm are available
#   2. Ensure the target namespace exists
#   3. Create/refresh the kong-vault-token Secret (Kong reads it via env at boot)
#   4. Add/update the Kong Helm repo
#   5. helm upgrade --install with values.yaml
#
# The cluster cert/key are sourced from in-cluster Vault at runtime via
# Kong's `{vault://hcv/...}` references in values.yaml — no on-disk cert
# material is needed by this script.
#
# Usage:
#   deploy-dp.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Kubernetes namespace (default: kong)
#   -r, --release NAME     Helm release name (default: kong-dp)
#   -t, --token TOKEN      Vault token to seed into the kong-vault-token
#                          Secret (default: root, matches deploy-vault.sh)
#   -f, --values FILE      Helm values file (default: <script-dir>/values.yaml)
#   --no-wait              Do not pass --wait to helm
#   -h, --help             Show this help
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="kong"
RELEASE="kong-dp"
VAULT_TOKEN="root"
VALUES="${SCRIPT_DIR}/values.yaml"
WAIT_FLAG="--wait"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -t|--token)     VAULT_TOKEN="$2"; shift 2 ;;
    -f|--values)    VALUES="$2"; shift 2 ;;
    --no-wait)      WAIT_FLAG=""; shift ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ── Prereqs ───────────────────────────────────────────────────────────────────
for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH."
done

[[ -r "$VALUES" ]] || die "Values file not readable: $VALUES"

info "Cluster context : $(kubectl config current-context)"
info "Namespace       : $NAMESPACE"
info "Release         : $RELEASE"
info "Values          : $VALUES"

# ── Namespace ─────────────────────────────────────────────────────────────────
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  info "Creating namespace '$NAMESPACE'..."
  kubectl create ns "$NAMESPACE"
fi

# ── Vault token Secret (idempotent) ───────────────────────────────────────────
info "Applying secret kong-vault-token..."
kubectl -n "$NAMESPACE" create secret generic kong-vault-token \
  --from-literal=token="$VAULT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Helm repo ─────────────────────────────────────────────────────────────────
info "Updating Kong Helm repo..."
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update kong >/dev/null

# ── Install / upgrade ─────────────────────────────────────────────────────────
info "Running helm upgrade --install..."
helm upgrade --install "$RELEASE" kong/kong \
  -n "$NAMESPACE" \
  -f "$VALUES" \
  $WAIT_FLAG

# ── Status ────────────────────────────────────────────────────────────────────
echo
ok "Deployed."
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$RELEASE"
echo
info "Tail DP logs:    kubectl -n $NAMESPACE logs -l app.kubernetes.io/instance=$RELEASE -f"
info "Proxy service:   kubectl -n $NAMESPACE get svc -l app.kubernetes.io/instance=$RELEASE"
