#!/usr/bin/env bash
#
# deploy-redis.sh
# Install Redis (Bitnami chart) in the local kind cluster as a single-node
# standalone instance — sized for sandbox use, not production.
#
# What you get:
#   - architecture=standalone (one master, zero replicas)
#   - auth.enabled=true with a known password (default: "redis")
#   - persistence disabled (restarting the pod wipes data)
#   - Service: <release>-master.<namespace>.svc.cluster.local:6379
#
# Usage:
#   deploy-redis.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Kubernetes namespace (default: redis)
#   -r, --release NAME     Helm release name (default: redis)
#   -p, --password PWD     Redis auth password (default: redis)
#   --no-wait              Do not pass --wait to helm
#   -h, --help             Show this help
#

set -euo pipefail

NAMESPACE="redis"
RELEASE="redis"
PASSWORD="redis"
WAIT_FLAG="--wait"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -p|--password)  PASSWORD="$2"; shift 2 ;;
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
info "Password        : $PASSWORD"

info "Adding Bitnami Helm repo..."
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null

info "Installing Redis (standalone, no persistence)..."
helm upgrade --install "$RELEASE" bitnami/redis \
  -n "$NAMESPACE" --create-namespace \
  --set "architecture=standalone" \
  --set "auth.enabled=true" \
  --set "auth.password=$PASSWORD" \
  --set "master.persistence.enabled=false" \
  --set "master.resources.requests.cpu=50m" \
  --set "master.resources.requests.memory=64Mi" \
  --set "master.resources.limits.cpu=250m" \
  --set "master.resources.limits.memory=256Mi" \
  $WAIT_FLAG

echo
ok "Redis deployed."
kubectl -n "$NAMESPACE" get pod,svc -l "app.kubernetes.io/instance=$RELEASE"

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
  Next steps
──────────────────────────────────────────────────────────────────────────────

  In-cluster endpoint (for Kong DP, app pods, etc.):
    ${RELEASE}-master.${NAMESPACE}.svc.cluster.local:6379

  Port-forward to test from your laptop:
    kubectl -n $NAMESPACE port-forward svc/${RELEASE}-master 6379:6379 &
    redis-cli -a $PASSWORD PING

  One-shot test from inside the cluster (no local redis-cli needed):
    kubectl run --rm -it redis-test --image=bitnami/redis --restart=Never -- \\
      redis-cli -h ${RELEASE}-master.${NAMESPACE}.svc.cluster.local \\
                -a $PASSWORD PING

EOF
