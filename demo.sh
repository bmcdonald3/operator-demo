#!/usr/bin/env bash
# Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

CLUSTER_NAME="testcluster"
NS="openchami-${CLUSTER_NAME}"

echo "=== 1. Deploying Minimal Control Plane & Disabling Magellan ==="
kubectl apply -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane "${CLUSTER_NAME}" -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'

echo "Waiting for OpenCHAMIControlPlane/${CLUSTER_NAME} to reach PHASE=Ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  "openchamicontrolplane/${CLUSTER_NAME}" -n default --timeout=180s

echo ""
echo "=== 2. Control Plane & Pod Status ==="
kubectl get openchamicontrolplane "${CLUSTER_NAME}" -n default
kubectl get pods -n "${NS}"

echo ""
echo "=== 3. Minting Admin JWT via TokenSmith Break-Glass CLI ==="
JWT=$(kubectl exec -n "${NS}" deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "hsm" \
  --scopes "node:read,node:write,group:read" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint)

echo "Minted JWT successfully."

echo ""
echo "=== 4. Setting up Port-Forward for SMD ==="
SMD_SVC="$(kubectl get svc -n "${NS}" -o name | grep -E 'smd' | head -n1)"
kubectl port-forward -n "${NS}" "${SMD_SVC}" 27779:27779 >/dev/null 2>&1 &
PF_SMD_PID=$!
trap 'kill ${PF_SMD_PID} 2>/dev/null || true' EXIT

# Wait for port-forward to become active
for i in {1..10}; do
  if nc -z 127.0.0.1 27779 2>/dev/null || curl -s http://127.0.0.1:27779/hsm/v2/service/ready >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

NODE_XNAME="x1000c0s0b0n0"

echo ""
echo "=== 5. Registering Compute Node (${NODE_XNAME}) in SMD ==="
curl -sS -X POST http://127.0.0.1:27779/hsm/v2/State/Components \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d "{
      \"Components\": [
        {
          \"ID\": \"${NODE_XNAME}\",
          \"Type\": \"Node\",
          \"State\": \"Ready\",
          \"Flag\": \"OK\",
          \"Enabled\": true,
          \"Role\": \"Compute\",
          \"NID\": 1,
          \"NetType\": \"Sling\",
          \"Arch\": \"X86\"
        }
      ]
    }" | jq . || true

echo ""
echo "=== 6. Querying SMD Component Inventory ==="
curl -sS "http://127.0.0.1:27779/hsm/v2/State/Components/${NODE_XNAME}" \
  -H "Authorization: Bearer ${JWT}" | jq .