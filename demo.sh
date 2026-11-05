#!/usr/bin/env bash
# Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
OPERATOR_DIR="${OPERATOR_DIR:-$(dirname "${BASH_SOURCE[0]}")/../openchami-operator}"
cd "$OPERATOR_DIR"

CLUSTER_NAME="testcluster"
NS="openchami-${CLUSTER_NAME}"
MAGELLAN_BIN="${MAGELLAN_BIN:-magellan}"
BMC_IP="${BMC_IP:-172.24.0.3}"
BMC_XNAME="${BMC_XNAME:-x1000c0s0b0}"
S3_BUCKET="${CLUSTER_NAME}-boot-images"

command -v "$MAGELLAN_BIN" >/dev/null || { echo "Set MAGELLAN_BIN to your pre-built Magellan executable." >&2; exit 1; }
: "${BMC_USERNAME:?Set BMC_USERNAME before running the demo}"
if [[ -z "${BMC_PASSWORD:-}" ]]; then
  read -r -s -p "BMC password: " BMC_PASSWORD
  printf '\n'
fi
: "${BMC_PASSWORD:?A BMC password is required}"
if [[ -n "${BOOT_KERNEL_URL:-}${BOOT_INITRD_URL:-}" ]]; then
  : "${BOOT_KERNEL_URL:?Set both BOOT_KERNEL_URL and BOOT_INITRD_URL}"
  : "${BOOT_INITRD_URL:?Set both BOOT_KERNEL_URL and BOOT_INITRD_URL}"
  : "${BOOT_PARAMS:?Set BOOT_PARAMS for the real node}"
fi
umask 077
DISCOVERY_DIR="$(mktemp -d)"
cleanup() {
  kill "${PF_SMD_PID:-}" "${PF_BSS_PID:-}" 2>/dev/null || true
  rm -rf "$DISCOVERY_DIR"
  unset BMC_PASSWORD
}
trap cleanup EXIT

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_REGION="us-east-1"
export AWS_PAGER=""
LOCALSTACK_URL="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"

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
  if [[ "$http_code" != 2?? ]]; then
    return 1
  fi
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
echo "=== 2. Deploying Control Plane for Host-Side Magellan Discovery ==="
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
echo "=== 4. Verifying S3 Bucket in LocalStack ==="
aws --endpoint-url="${LOCALSTACK_URL}" s3 ls
aws --endpoint-url="${LOCALSTACK_URL}" s3 ls "s3://${S3_BUCKET}/"

echo ""
echo "=== 5. Starting Port-Forwards (SMD: 27779, BSS: 27778) ==="
kubectl port-forward -n "${NS}" svc/smd 27779:27779 >/dev/null 2>&1 &
PF_SMD_PID=$!
kubectl port-forward -n "${NS}" svc/boot-service 27778:27778 >/dev/null 2>&1 &
PF_BSS_PID=$!
PORT_FORWARDS_READY=false
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:27779/hsm/v2/service/ready >/dev/null 2>&1 && \
     curl -fsS http://127.0.0.1:27778/boot/v1/service/status >/dev/null 2>&1; then
    PORT_FORWARDS_READY=true
    break
  fi
  sleep 0.5
done
"$PORT_FORWARDS_READY" || { echo "Port-forwards did not become ready." >&2; exit 1; }
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
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1:27779/hsm/v2/State/Components \
  -H 'Content-Type: application/json' -d '{}')"
[[ "$HTTP_CODE" == 401 ]] || { echo "Expected HTTP 401, got $HTTP_CODE" >&2; exit 1; }

echo ""
echo "=== 8. Discovering BMC ${BMC_IP} with Magellan ==="
BMC_MAP="$(jq -nc --arg ip "$BMC_IP" --arg id "$BMC_XNAME" \
  '{map_key:"bmc-ip-addr",id_map:{($ip):$id}}')"
"$MAGELLAN_BIN" scan "https://${BMC_IP}:443" --insecure --cache "$DISCOVERY_DIR/assets.db"
"$MAGELLAN_BIN" collect --cache "$DISCOVERY_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map "$BMC_MAP" --output-format json --output-file "$DISCOVERY_DIR/inventory.json"
unset BMC_PASSWORD
jq -e 'if type == "array" then length > 0 else type == "object" and length > 0 end' \
  "$DISCOVERY_DIR/inventory.json" >/dev/null
ACCESS_TOKEN="$SMD_JWT" "$MAGELLAN_BIN" send --input-format json \
  --force-update --data "@$DISCOVERY_DIR/inventory.json" http://127.0.0.1:27779

echo ""
echo "=== 9. Inspecting Discovered SMD Nodes and Interfaces ==="
curl -fsS http://127.0.0.1:27779/hsm/v2/State/Components \
  -H "Authorization: Bearer $SMD_JWT" > "$DISCOVERY_DIR/components.json"
DISCOVERED_NODES="$(jq --arg prefix "${BMC_XNAME}n" \
  '[.Components[] | select(.Type == "Node" and (.ID | startswith($prefix)))]' \
  "$DISCOVERY_DIR/components.json")"
jq . <<< "$DISCOVERED_NODES"
if [[ -z "${NODE_XNAME:-}" ]]; then
  NODE_XNAME="$(jq -er 'if length == 1 then .[0].ID else error("Set NODE_XNAME to one discovered node") end' <<< "$DISCOVERED_NODES")"
fi
jq -e --arg node "$NODE_XNAME" 'any(.[]; .ID == $node)' <<< "$DISCOVERED_NODES" >/dev/null
curl -fsS http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces \
  -H "Authorization: Bearer $SMD_JWT" > "$DISCOVERY_DIR/interfaces.json"
NODE_INTERFACES="$(jq --arg node "$NODE_XNAME" \
  '[.[] | select(.ComponentID == $node)]' "$DISCOVERY_DIR/interfaces.json")"
jq . <<< "$NODE_INTERFACES"

if [[ -z "${BOOT_KERNEL_URL:-}" ]]; then
  echo "Discovery complete. Set BOOT_KERNEL_URL, BOOT_INITRD_URL and BOOT_PARAMS to also configure BSS."
  exit 0
fi
if [[ -z "${BOOT_MAC:-}" ]]; then
  BOOT_MAC="$(jq -er '[.[].MACAddress | select(. != null and . != "")] | unique |
    if length == 1 then .[0] else error("Set BOOT_MAC to the discovered PXE NIC MAC, not the BMC MAC") end' <<< "$NODE_INTERFACES")"
fi
jq -e --arg mac "$BOOT_MAC" 'any(.[]; (.MACAddress | ascii_downcase) == ($mac | ascii_downcase))' \
  <<< "$NODE_INTERFACES" >/dev/null

echo ""
echo "=== 10. Registering Real Boot Parameters in BSS ==="
BOOT_PAYLOAD="$(jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$BOOT_KERNEL_URL" --arg initrd "$BOOT_INITRD_URL" --arg params "$BOOT_PARAMS" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}')"
api_call POST http://127.0.0.1:27778/boot/v1/bootparameters "$BSS_JWT" "$BOOT_PAYLOAD"
api_call GET http://127.0.0.1:27778/boot/v1/bootparameters "$BSS_JWT"
api_call GET "http://127.0.0.1:27778/boot/v1/bootscript?host=${NODE_XNAME}"
api_call GET "http://127.0.0.1:27778/boot/v1/bootscript?mac=${BOOT_MAC}"

echo ""
echo "=== Demo Script Complete ==="
