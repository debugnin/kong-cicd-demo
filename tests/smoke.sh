#!/usr/bin/env bash
# smoke.sh — gateway-up check.
#
# Requires: kubectl (current context), curl.
# Env:
#   GATEWAY_URL  (default: http://localhost:8080) — kind extraPortMapping target

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"

echo "==> Waiting for Gateway kong/kong to be Programmed"
kubectl -n kong wait gateway/kong \
  --for=condition=Programmed=True \
  --timeout=300s

echo "==> Checking attachedRoutes > 0"
ATTACHED=$(kubectl -n kong get gateway kong \
  -o jsonpath='{.status.listeners[?(@.name=="http")].attachedRoutes}')
if [[ -z "${ATTACHED}" || "${ATTACHED}" -lt 1 ]]; then
  echo "FAIL: expected attachedRoutes >= 1, got '${ATTACHED}'"
  kubectl -n kong get gateway kong -o yaml
  exit 1
fi
echo "    attachedRoutes=${ATTACHED}"

echo "==> Curl ${GATEWAY_URL}/status/200 with retries (gateway may take a few seconds after Programmed)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/status/200" || true)
  if [[ "${STATUS}" == "200" ]]; then
    echo "    OK after ${i} attempt(s)"
    exit 0
  fi
  echo "    attempt ${i}: ${STATUS} — sleeping 3s"
  sleep 3
done

echo "FAIL: never got 200 from ${GATEWAY_URL}/status/200"
exit 1
