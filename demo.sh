#!/usr/bin/env bash
# Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CLUSTER_NAME="testcluster"
NS="openchami-${CLUSTER_NAME}"
NODE_0="x1000c0s0b0n0"
NODE_1="x1000c0s0b0n1"
NODE_0_MAC="00:de:ad:be:ef:01"
NODE_0_IP="172.16.0.101"
GROUP_NAME="compute"
S3_BUCKET="${CLUSTER_NAME}-boot-images"

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_REGION="us-east-1"
export AWS_PAGER=""
LOCALSTACK_URL="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"
IN_CLUSTER_S3_URL="http://openchami-localstack-dev:4566"

RESET_CLUSTER=false
if [[ "${1:-}" == "--reset" ]]; then
  RESET_CLUSTER=true
fi

api_call() {
  local method="$1"
  local url="$2"
  local token="${3:-}"
  local payload="${4:-}"

  local tmp_body
  tmp_body="$(mktemp)"
  local curl_args=(-sS -X "$method" "$url" -o "$tmp_body" -w "%{http_code}")

  if [[ -n "$token" ]]; then
    curl_args+=(-H "Authorization: Bearer ${token}")
  fi
  if [[ -n "$payload" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$payload")
  fi

  local http_code
  http_code="$(curl "${curl_args[@]}")"
  echo "--> ${method} ${url} [HTTP ${http_code}]"

  if [[ -s "$tmp_body" ]]; then
    if jq -e . "$tmp_body" >/dev/null 2>&1; then
      jq . "$tmp_body"
    else
      cat "$tmp_body"
      echo ""
    fi
  fi
  rm -f "$tmp_body"
}

if "$RESET_CLUSTER"; then
  echo "=== 0. Resetting ${CLUSTER_NAME} (--reset specified) ==="
  kubectl delete openchamicontrolplane "${CLUSTER_NAME}" -n default --ignore-not-found --wait=true
  kubectl wait --for=delete namespace/"${NS}" --timeout=180s 2>/dev/null || true
fi

echo "=== 1. Previewing Manifest with ochami-admin (Dry-Run) ==="
if [[ -x "./bin/ochami-admin" ]]; then
  ./bin/ochami-admin describe -f test/fixtures/minimal-controlplane.yaml | head -n 25 || true
  echo "... (truncated dry-run output)"
else
  echo "Skipping dry-run preview (./bin/ochami-admin not built; run 'make build' to enable)."
fi

echo ""
echo "=== 2. Deploying Minimal Control Plane & Disabling Magellan ==="
kubectl apply -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane "${CLUSTER_NAME}" -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'

echo "Waiting up to 180s for OpenCHAMIControlPlane/${CLUSTER_NAME} to reach PHASE=Ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  "openchamicontrolplane/${CLUSTER_NAME}" -n default --timeout=180s

echo ""
echo "=== 3. Control Plane Status, Pods & Reconciled Conditions ==="
kubectl get openchamicontrolplane "${CLUSTER_NAME}" -n default
echo ""
kubectl get pods -n "${NS}"
echo ""
kubectl get openchamicontrolplane "${CLUSTER_NAME}" -n default \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'

echo ""
echo "=== 4. Verifying S3 Bucket in LocalStack & Uploading Dummy Boot Artifacts ==="
aws --endpoint-url="${LOCALSTACK_URL}" s3 ls
echo "dummy-kernel-payload" | aws --endpoint-url="${LOCALSTACK_URL}" s3 cp - "s3://${S3_BUCKET}/vmlinuz-6.8"
echo "dummy-initrd-payload" | aws --endpoint-url="${LOCALSTACK_URL}" s3 cp - "s3://${S3_BUCKET}/initramfs-6.8.img"
aws --endpoint-url="${LOCALSTACK_URL}" s3 ls "s3://${S3_BUCKET}/"

echo ""
echo "=== 5. Starting Port-Forwards (SMD: 27779, BSS: 27778, Metadata: 8081) ==="
kubectl port-forward -n "${NS}" svc/smd 27779:27779 >/dev/null 2>&1 &
PF_SMD_PID=$!
kubectl port-forward -n "${NS}" svc/boot-service 27778:27778 >/dev/null 2>&1 &
PF_BSS_PID=$!
kubectl port-forward -n "${NS}" svc/metadata-service 8081:8081 >/dev/null 2>&1 &
PF_MDS_PID=$!

cleanup() {
  kill "${PF_SMD_PID:-}" "${PF_BSS_PID:-}" "${PF_MDS_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

for i in {1..20}; do
  if curl -s http://127.0.0.1:27779/hsm/v2/service/ready >/dev/null 2>&1 && \
     curl -s http://127.0.0.1:27778/boot/v1/service/status >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
echo "Port-forwards active."

echo ""
echo "=== 6. Minting Admin JWTs via TokenSmith ==="
SMD_JWT=$(kubectl exec -n "${NS}" deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "hsm" \
  --scopes "node:read,node:write,group:read,group:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint | tr -d '\r\n')

BSS_JWT=$(kubectl exec -n "${NS}" deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "boot-service" \
  --scopes "boot:read,boot:write,node:read,node:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint | tr -d '\r\n')

echo "Minted SMD_JWT (${#SMD_JWT} bytes) and BSS_JWT (${#BSS_JWT} bytes)."

echo ""
echo "=== 7. Verifying SMD Rejects Unauthenticated Writes (Expected HTTP 401) ==="
api_call POST "http://127.0.0.1:27779/hsm/v2/State/Components" "" "{}"

echo ""
echo "=== 8. Cleaning Up Any Pre-Existing Demo Records (For Re-Run Idempotency) ==="
curl -sS -X DELETE "http://127.0.0.1:27779/hsm/v2/groups/${GROUP_NAME}" \
  -H "Authorization: Bearer ${SMD_JWT}" >/dev/null 2>&1 || true
curl -sS -X DELETE "http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces/${NODE_0_MAC//:/}" \
  -H "Authorization: Bearer ${SMD_JWT}" >/dev/null 2>&1 || true
curl -sS -X DELETE "http://127.0.0.1:27779/hsm/v2/State/Components/${NODE_0}" \
  -H "Authorization: Bearer ${SMD_JWT}" >/dev/null 2>&1 || true
curl -sS -X DELETE "http://127.0.0.1:27779/hsm/v2/State/Components/${NODE_1}" \
  -H "Authorization: Bearer ${SMD_JWT}" >/dev/null 2>&1 || true

for uid in $(curl -sS http://127.0.0.1:27778/nodes -H "Authorization: Bearer ${BSS_JWT}" | jq -r '.[].metadata.uid // empty' 2>/dev/null); do
  curl -sS -X DELETE "http://127.0.0.1:27778/nodes/${uid}" -H "Authorization: Bearer ${BSS_JWT}" >/dev/null 2>&1 || true
done
for uid in $(curl -sS http://127.0.0.1:27778/bootconfigurations -H "Authorization: Bearer ${BSS_JWT}" | jq -r '.[].metadata.uid // empty' 2>/dev/null); do
  curl -sS -X DELETE "http://127.0.0.1:27778/bootconfigurations/${uid}" -H "Authorization: Bearer ${BSS_JWT}" >/dev/null 2>&1 || true
done

echo ""
echo "=== 9. Registering Compute Nodes (${NODE_0}, ${NODE_1}) in SMD ==="
api_call POST "http://127.0.0.1:27779/hsm/v2/State/Components" "${SMD_JWT}" "{
  \"Components\": [
    {
      \"ID\": \"${NODE_0}\",
      \"Type\": \"Node\",
      \"State\": \"Ready\",
      \"Flag\": \"OK\",
      \"Enabled\": true,
      \"Role\": \"Compute\",
      \"NID\": 1,
      \"NetType\": \"Sling\",
      \"Arch\": \"X86\"
    },
    {
      \"ID\": \"${NODE_1}\",
      \"Type\": \"Node\",
      \"State\": \"Standby\",
      \"Flag\": \"OK\",
      \"Enabled\": true,
      \"Role\": \"Compute\",
      \"NID\": 2,
      \"NetType\": \"Sling\",
      \"Arch\": \"X86\"
    }
  ]
}"

echo ""
echo "=== 10. Querying SMD Component Inventory ==="
api_call GET "http://127.0.0.1:27779/hsm/v2/State/Components" "${SMD_JWT}"

echo ""
echo "=== 11. Registering Ethernet Interface (${NODE_0_MAC} -> ${NODE_0_IP}) in SMD ==="
api_call POST "http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces" "${SMD_JWT}" "{
  \"ComponentID\": \"${NODE_0}\",
  \"Description\": \"Node Management Network\",
  \"MACAddress\": \"${NODE_0_MAC}\",
  \"IPAddresses\": [{\"IPAddress\": \"${NODE_0_IP}\"}]
}"

echo ""
echo "=== 12. Creating Hardware Group (${GROUP_NAME}) in SMD ==="
api_call POST "http://127.0.0.1:27779/hsm/v2/groups" "${SMD_JWT}" "{
  \"label\": \"${GROUP_NAME}\",
  \"description\": \"Standard HPC compute nodes\",
  \"members\": {
    \"ids\": [\"${NODE_0}\", \"${NODE_1}\"]
  }
}"

api_call GET "http://127.0.0.1:27779/hsm/v2/groups/${GROUP_NAME}" "${SMD_JWT}"

echo ""
echo "=== 13. Registering Node Record in Boot Script Service (BSS) ==="
api_call POST "http://127.0.0.1:27778/nodes" "${BSS_JWT}" "{
  \"metadata\": {
    \"name\": \"${NODE_0}\"
  },
  \"spec\": {
    \"xname\": \"${NODE_0}\",
    \"nid\": 1,
    \"bootMac\": \"${NODE_0_MAC}\",
    \"role\": \"Compute\"
  }
}"

echo ""
echo "=== 14. Registering Boot Parameters in Boot Script Service (BSS) ==="
# Note: BootParametersRequest.nids expects []string (["1"])
BOOT_PAYLOAD="{
  \"hosts\": [\"${NODE_0}\"],
  \"macs\": [\"${NODE_0_MAC}\"],
  \"nids\": [\"1\"],
  \"kernel\": \"${IN_CLUSTER_S3_URL}/${S3_BUCKET}/vmlinuz-6.8\",
  \"initrd\": \"${IN_CLUSTER_S3_URL}/${S3_BUCKET}/initramfs-6.8.img\",
  \"params\": \"console=ttyS0,115200n8 ds=nocloud-net;s=https://${CLUSTER_NAME}.local/cloud-init/\"
}"

api_call POST "http://127.0.0.1:27778/boot/v1/bootparameters" "${BSS_JWT}" "${BOOT_PAYLOAD}"
api_call GET "http://127.0.0.1:27778/boot/v1/bootparameters" "${BSS_JWT}"

echo ""
echo "=== 15. Simulating Unauthenticated Node PXE Boot Request (by host, nid, & mac) ==="
echo "--- Querying by XName (?host=${NODE_0}) ---"
api_call GET "http://127.0.0.1:27778/boot/v1/bootscript?host=${NODE_0}"

echo "--- Querying by NID (?nid=1) ---"
api_call GET "http://127.0.0.1:27778/boot/v1/bootscript?nid=1"

echo "--- Querying by MAC (?mac=${NODE_0_MAC}) ---"
api_call GET "http://127.0.0.1:27778/boot/v1/bootscript?mac=${NODE_0_MAC}"

echo ""
echo "=== Demo Script Complete ==="
