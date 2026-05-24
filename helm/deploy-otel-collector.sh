#!/usr/bin/env bash
#
# deploy-otel-collector.sh
# Deploy the OpenTelemetry Collector onto the local kind cluster.
#
# What it does:
#   1. Verify kubectl + helm
#   2. Add/update the open-telemetry helm repo
#   3. Ensure the namespace exists
#   4. helm upgrade --install with values.yaml — Service is pinned to
#      `otel-collector` so the endpoint baked into Konnect's OTel plugin
#      (http://otel-collector:4318) resolves correctly.
#
# Usage:
#   deploy-otel-collector.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Kubernetes namespace (default: observability)
#   -r, --release NAME     Helm release name (default: otel-collector)
#   -f, --values FILE      Helm values file (default: <script-dir>/otel-values.yaml)
#   --no-wait              Do not pass --wait to helm
#   -h, --help             Show this help
#
# The collector lives in its own namespace; Kong DPs reach it via the FQDN
# `otel-collector.observability.svc.cluster.local:4318` configured in
# the Konnect OTel plugin (see platform.tf).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="observability"
RELEASE="otel-collector"
VALUES="${SCRIPT_DIR}/otel-values.yaml"
WAIT_FLAG="--wait"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -f|--values)    VALUES="$2"; shift 2 ;;
    --no-wait)      WAIT_FLAG=""; shift ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH."
done
[[ -r "$VALUES" ]] || die "Values file not readable: $VALUES"

info "Cluster context : $(kubectl config current-context)"
info "Namespace       : $NAMESPACE"
info "Release         : $RELEASE"
info "Values          : $VALUES"

if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  info "Creating namespace '$NAMESPACE'..."
  kubectl create ns "$NAMESPACE"
fi

info "Adding open-telemetry helm repo..."
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

info "Running helm upgrade --install..."
helm upgrade --install "$RELEASE" open-telemetry/opentelemetry-collector \
  -n "$NAMESPACE" \
  -f "$VALUES" \
  $WAIT_FLAG

echo
ok "Deployed."
kubectl -n "$NAMESPACE" get pod,svc -l "app.kubernetes.io/instance=$RELEASE"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
  Next steps
──────────────────────────────────────────────────────────────────────────────

  Tail collector logs (debug exporter prints incoming telemetry):
    kubectl -n $NAMESPACE logs -l app.kubernetes.io/name=opentelemetry-collector -f

  Send a test trace from inside the cluster (curl from any namespace):
    kubectl run --rm -it otel-test --image=curlimages/curl --restart=Never -- \\
      -X POST http://otel-collector.${NAMESPACE}.svc.cluster.local:4318/v1/traces \\
      -H 'Content-Type: application/json' \\
      -d '{"resourceSpans":[]}'

  Enable the Konnect OTel plugin (in platform.tf):
    konnect_gateway_plugin_opentelemetry.platform_opentelemetry_plugin
      enabled = true
  Then: terraform apply

EOF
