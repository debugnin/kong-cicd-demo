#!/usr/bin/env bash
#
# deploy-kong-operator.sh
# Install the Kong Operator + Gateway API CRDs into the current cluster.
#
# Follows https://developer.konghq.com/operator/get-started/gateway-api/install/
# (chart kong/kong-operator, formerly kong/gateway-operator). The "Konnect mode"
# default sets ENABLE_CONTROLLER_KONNECT=true so the operator reconciles
# KonnectGatewayControlPlane / KonnectExtension / KonnectAPIAuthConfiguration
# CRs — required by the kong-cicd-demo manifests in this workspace.
#
# Usage:
#   deploy-kong-operator.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS         Kubernetes namespace (default: kong-system)
#   -r, --release NAME         Helm release name (default: kong-operator)
#   -v, --version VER          kong-operator chart version (default: 1.2.4)
#   -i, --image-tag TAG        kong-operator image tag (default: 2.1.5)
#   -g, --gateway-api VER      Gateway API CRD version (default: v1.4.1)
#   --no-konnect               Disable ENABLE_CONTROLLER_KONNECT (on-prem mode)
#   --cert-manager             Enable webhook cert management via cert-manager
#                              (cert-manager must already be installed)
#   --skip-gateway-api         Skip installing Gateway API CRDs
#   --no-wait                  Skip the rollout-status check at the end
#   --konnect-token TOKEN      Create konnect-token secret in kong namespace
#   --konnect-ns NS            Namespace for konnect-token secret (default: kong)
#   -h, --help                 Show this help
#

set -euo pipefail

NAMESPACE="kong-system"
RELEASE="kong-operator"
CHART_VERSION="1.2.4"
IMAGE_TAG="2.1.5"
GATEWAY_API_VERSION="v1.4.1"
KONNECT="true"
CERT_MANAGER="false"
SKIP_GATEWAY_API="false"
WAIT_FLAG="--wait"
KONNECT_TOKEN="${KONNECT_TOKEN:-}"
KONNECT_NS="kong"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)        NAMESPACE="$2"; shift 2 ;;
    -r|--release)          RELEASE="$2"; shift 2 ;;
    -v|--version)          CHART_VERSION="$2"; shift 2 ;;
    -i|--image-tag)        IMAGE_TAG="$2"; shift 2 ;;
    -g|--gateway-api)      GATEWAY_API_VERSION="$2"; shift 2 ;;
    --no-konnect)          KONNECT="false"; shift ;;
    --cert-manager)        CERT_MANAGER="true"; shift ;;
    --konnect-token)       KONNECT_TOKEN="$2"; shift 2 ;;
    --konnect-ns)          KONNECT_NS="$2"; shift 2 ;;
    --skip-gateway-api)    SKIP_GATEWAY_API="true"; shift ;;
    --no-wait)             WAIT_FLAG=""; shift ;;
    -h|--help)             sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH."
done

info "Cluster context     : $(kubectl config current-context)"
info "Namespace           : $NAMESPACE"
info "Release             : $RELEASE"
info "Chart version       : $CHART_VERSION"
info "Image tag           : $IMAGE_TAG"
info "Gateway API version : $GATEWAY_API_VERSION"
info "Konnect mode        : $KONNECT"
info "cert-manager hook   : $CERT_MANAGER"
info "Skip Gateway API    : $SKIP_GATEWAY_API"

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

if [[ "$SKIP_GATEWAY_API" != "true" ]]; then
  info "Installing Gateway API CRDs ($GATEWAY_API_VERSION, server-side apply)..."
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
fi

info "Adding kong Helm repo..."
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update kong >/dev/null

info "Installing Kong Operator..."
HELM_SET_FLAGS=(--set "image.tag=${IMAGE_TAG}")
if [[ "$KONNECT" == "true" ]]; then
  HELM_SET_FLAGS+=(--set "env.ENABLE_CONTROLLER_KONNECT=true")
fi
if [[ "$CERT_MANAGER" == "true" ]]; then
  HELM_SET_FLAGS+=(--set "global.webhooks.options.certManager.enabled=true")
fi

helm upgrade --install "$RELEASE" kong/kong-operator \
  -n "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  "${HELM_SET_FLAGS[@]}"

if [[ -n "$WAIT_FLAG" ]]; then
  info "Waiting for operator controller-manager to become Available..."
  kubectl -n "$NAMESPACE" wait --for=condition=Available=true --timeout=120s \
    deployment/"${RELEASE}-kong-operator-controller-manager"
fi

echo
ok "Kong Operator deployed."
kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE"

echo
info "Operator-managed CRDs now present in the cluster:"
if [[ -n "$KONNECT_TOKEN" ]]; then
  echo
  info "Creating Konnect token Secret in namespace $KONNECT_NS..."
  kubectl create namespace "$KONNECT_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$KONNECT_NS" create secret generic konnect-token \
    --from-literal=token="$KONNECT_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - \
      "konghq.com/credential=konnect" \
      "konghq.com/secret=true" \
      --dry-run=client -o yaml \
    | kubectl apply -f -
  ok "Secret konnect-token created in namespace $KONNECT_NS"
fi

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
  Next steps
──────────────────────────────────────────────────────────────────────────────
EOF

if [[ -z "$KONNECT_TOKEN" ]]; then
  cat <<EOF

  1. Create the Konnect token Secret (referenced by KonnectAPIAuthConfiguration):

       kubectl create namespace kong
       kubectl -n kong create secret generic konnect-token \\
         --from-literal=token="kpat_..." \\
         && kubectl -n kong label secret konnect-token \\
              "konghq.com/credential=konnect" \\
              "konghq.com/secret=true"

     Or re-run this script with:
       ./deploy-kong-operator.sh --konnect-token "kpat_..."

  2. Install Argo CD:
EOF
else
  cat <<EOF

  1. Install Argo CD:
EOF
fi

cat <<EOF

       ./deploy-argocd.sh

  ${KONNECT_TOKEN:+2}${KONNECT_TOKEN:-3}    ./deploy-argocd.sh

  3. Apply the kong-cicd-demo Argo CD configs:

       cd ../kong-cicd-demo
       kubectl apply -f argocd/projects/
       kubectl apply -f argocd/app-platform.yaml -f argocd/app-httpbin.yaml

EOF
