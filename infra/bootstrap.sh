#!/usr/bin/env bash
# Installs Kong Gateway Operator and Argo CD into the current kubectl context.
# Idempotent: safe to re-run.

set -euo pipefail

KONG_OPERATOR_VERSION="${KONG_OPERATOR_VERSION:-0.6.0}"
ARGOCD_VERSION="${ARGOCD_VERSION:-8.0.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"

echo "==> Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Adding helm repos"
helm repo add kong https://charts.konghq.com
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Installing Kong Gateway Operator (${KONG_OPERATOR_VERSION})"
kubectl create namespace kong-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kong-gateway-operator kong/gateway-operator \
  --namespace kong-system \
  --version "${KONG_OPERATOR_VERSION}" \
  --set image.tag="${KONG_OPERATOR_VERSION}" \
  --wait \
  --timeout 5m

echo "==> Installing Argo CD (${ARGOCD_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_VERSION}" \
  --set configs.params."server\.insecure"=true \
  --wait \
  --timeout 5m

echo "==> Waiting for Argo CD server"
kubectl -n argocd rollout status deployment/argocd-server --timeout=5m

echo "==> Bootstrap complete"
