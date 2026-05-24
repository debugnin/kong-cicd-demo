#!/usr/bin/env bash
#
# reseed-vault.sh
# Re-seed the Kong-related secrets into in-cluster Vault.
#
# Vault is deployed in dev mode (in-memory), so every Vault pod restart
# wipes all secrets and Kong DP crashloops on its next config sync.
# Run this after a Vault restart to restore:
#   - secret/kong/dp/cluster-cert       (DP↔CP mTLS, needed at Kong DP boot)
#   - secret/kong/platform/server-cert  (platform server cert, resolved at runtime)
#
# Cert/key files are sourced from ../terraform-platform-cp/certs/ by default.
#
# Usage:
#   reseed-vault.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS     Vault namespace (default: vault)
#   -p, --pod NAME         Vault pod name (default: vault-0)
#   -t, --token TOKEN      Vault root token (default: root)
#   -c, --certs-dir DIR    Directory holding client.{crt,key} and server.{crt,key}
#                          (default: <script-dir>/../terraform-platform-cp/certs)
#   -h, --help             Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="vault"
POD="vault-0"
VAULT_TOKEN="root"
CERTS_DIR="${SCRIPT_DIR}/../terraform-platform-cp/certs"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -p|--pod)        POD="$2"; shift 2 ;;
    -t|--token)      VAULT_TOKEN="$2"; shift 2 ;;
    -c|--certs-dir)  CERTS_DIR="$2"; shift 2 ;;
    -h|--help)       sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v kubectl >/dev/null || die "'kubectl' not found in PATH."

DP_CRT="$CERTS_DIR/dp-client.crt"
DP_KEY="$CERTS_DIR/dp-client.key"
SRV_CRT="$CERTS_DIR/server.crt"
SRV_KEY="$CERTS_DIR/server.key"

for f in "$DP_CRT" "$DP_KEY" "$SRV_CRT" "$SRV_KEY"; do
  [[ -r "$f" ]] || die "Missing or unreadable: $f"
done

kubectl -n "$NAMESPACE" get pod "$POD" >/dev/null 2>&1 \
  || die "Vault pod '$POD' not found in namespace '$NAMESPACE'."

info "Cluster context : $(kubectl config current-context)"
info "Vault pod       : $NAMESPACE/$POD"
info "Certs dir       : $CERTS_DIR"

info "Copying cert/key files into $POD..."
kubectl -n "$NAMESPACE" cp "$DP_CRT"  "$POD:/tmp/dp.crt"
kubectl -n "$NAMESPACE" cp "$DP_KEY"  "$POD:/tmp/dp.key"
kubectl -n "$NAMESPACE" cp "$SRV_CRT" "$POD:/tmp/srv.crt"
kubectl -n "$NAMESPACE" cp "$SRV_KEY" "$POD:/tmp/srv.key"

info "Writing secrets to Vault..."
kubectl -n "$NAMESPACE" exec "$POD" -- env VAULT_TOKEN="$VAULT_TOKEN" sh -c '
  set -e
  vault kv put secret/kong/dp/cluster-cert \
    tls.crt=@/tmp/dp.crt  tls.key=@/tmp/dp.key  >/dev/null
  vault kv put secret/kong/platform/server-cert \
    tls.crt=@/tmp/srv.crt tls.key=@/tmp/srv.key >/dev/null
  rm -f /tmp/dp.crt /tmp/dp.key /tmp/srv.crt /tmp/srv.key
'

info "Verifying..."
kubectl -n "$NAMESPACE" exec "$POD" -- env VAULT_TOKEN="$VAULT_TOKEN" sh -c '
  echo "── secret/kong/dp ──"
  vault kv list secret/kong/dp
  echo
  echo "── secret/kong/platform ──"
  vault kv list secret/kong/platform
'

echo
ok "Vault re-seeded."
echo
info "If any Kong DP pod was crashlooping, kick it now:"
echo "    kubectl -n kong rollout restart deploy/kong-dp-kong"
