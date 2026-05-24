#!/usr/bin/env bash
#
# deploy-argocd.sh
# Install Argo CD in the current kubectl cluster.
#
# What this gives you:
#   - argo-cd Helm release in namespace argocd
#   - argocd-server reachable via port-forward or NodePort
#   - Initial admin password printed at the end
#
# Usage:
#   deploy-argocd.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Kubernetes namespace (default: argocd)
#   -r, --release NAME     Helm release name (default: argocd)
#   -v, --version VER      argo-cd chart version (default: 9.5.14, appVersion v3.4.2)
#   --insecure             Set server.insecure=true (skips TLS, useful for kind)
#   --no-wait              Skip the rollout-status check at the end (fire-and-forget)
#   -h, --help             Show this help
#

set -euo pipefail

NAMESPACE="argocd"
RELEASE="argocd"
CHART_VERSION="9.5.14"
INSECURE="false"
WAIT_FLAG="--wait"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -v|--version)   CHART_VERSION="$2"; shift 2 ;;
    --insecure)     INSECURE="true"; shift ;;
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
info "Chart version   : $CHART_VERSION"
info "Insecure mode   : $INSECURE"

info "Checking cluster reachability..."
if ! kubectl get --raw /healthz --request-timeout=10s >/dev/null 2>&1; then
  die "Cannot reach Kubernetes API server in context '$(kubectl config current-context)'.
       Common causes:
         - Docker Desktop wedged          → restart Docker, then 'docker ps' should work
         - kind cluster stopped           → 'docker start <kind-control-plane-container>'
         - kubeconfig points elsewhere    → 'kubectl config current-context'
       Verify with:
         kubectl cluster-info"
fi

info "Adding argo Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

info "Installing Argo CD..."
HELM_SET_FLAGS=()
if [[ "$INSECURE" == "true" ]]; then
  HELM_SET_FLAGS+=(--set "configs.params.server\.insecure=true")
fi

helm upgrade --install "$RELEASE" argo/argo-cd \
  -n "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  "${HELM_SET_FLAGS[@]}"

if [[ -n "$WAIT_FLAG" ]]; then
  info "Waiting for argocd-server rollout..."
  kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=5m
fi

ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(secret not present — already rotated?)")

echo
ok "Argo CD deployed."
kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
  Next steps
──────────────────────────────────────────────────────────────────────────────

  Port-forward the UI:
    kubectl -n $NAMESPACE port-forward svc/$RELEASE-server 8080:443 &

  Open: https://localhost:8080
    username: admin
    password: $ADMIN_PASSWORD

  CLI login (with port-forward running):
    argocd login localhost:8080 --username admin --password '$ADMIN_PASSWORD' --insecure

  Apply the kong-cicd-demo Applications:
    cd ../kong-cicd-demo
    kubectl apply -f argocd/projects/
    kubectl apply -f argocd/app-platform.yaml -f argocd/app-httpbin.yaml

  Watch them sync:
    argocd app list
    argocd app wait platform httpbin --health --sync

EOF
