#!/usr/bin/env bash
# Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -euo pipefail
cd "${OPERATOR_DIR:-$(dirname "${BASH_SOURCE[0]}")/../openchami-operator}"
MAGELLAN_BIN="${MAGELLAN_BIN:-magellan}"
umask 077
DEMO_DIR=$(mktemp -d)

make dev-up
make build
make dev-deploy
./bin/ochami-admin describe -f test/fixtures/minimal-controlplane.yaml
kubectl apply -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=180s
kubectl get pods -n openchami-testcluster

kubectl port-forward -n openchami-testcluster svc/smd 27779:27779 &
PF_SMD_PID=$!
kubectl port-forward -n openchami-testcluster svc/boot-service 27778:27778 &
PF_BSS_PID=$!
trap 'kill "$PF_SMD_PID" "$PF_BSS_PID" 2>/dev/null || true' EXIT
read -r -p 'Press Enter when both port-forwards show Forwarding from: '

SMD_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience hsm \
  --scopes node:read,node:write,group:read,group:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')
BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience boot-service \
  --scopes boot:read,boot:write,node:read,node:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')

read -r -p 'BMC username: ' BMC_USERNAME
read -r -s -p 'BMC password: ' BMC_PASSWORD
printf '\n'
"$MAGELLAN_BIN" scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"
"$MAGELLAN_BIN" collect --cache "$DEMO_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
  --output-format json --output-file "$DEMO_DIR/inventory.json"
jq '.[].Systems' "$DEMO_DIR/inventory.json"
jq -c '.[]' "$DEMO_DIR/inventory.json" | while IFS= read -r endpoint; do
  curl -fsS -X POST http://127.0.0.1:27779/hsm/v2/Inventory/RedfishEndpoints \
    -H "Authorization: Bearer $SMD_JWT" -H 'Content-Type: application/json' \
    -d "$endpoint"
done

curl -fsS http://127.0.0.1:27779/hsm/v2/Inventory/ComponentEndpoints \
  -H "Authorization: Bearer $SMD_JWT" > "$DEMO_DIR/endpoints.json"
NODE_XNAME=$(jq -er --slurpfile inventory "$DEMO_DIR/inventory.json" '
  [.ComponentEndpoints[] | . as $endpoint |
    select(.RfEndpointID == $inventory[0][0].ID) |
    select(any($inventory[0][0].Systems[]; .uuid == $endpoint.UUID)) | .ID] | unique |
  if length == 1 then .[0] else error("Choose a node from the collected systems") end
' "$DEMO_DIR/endpoints.json")
curl -fsS "http://127.0.0.1:27779/hsm/v2/State/Components/$NODE_XNAME" \
  -H "Authorization: Bearer $SMD_JWT" | jq .

jq -nc --arg node "$NODE_XNAME" \
  '{label:"compute",description:"Discovered compute node",members:{ids:[$node]}}' |
  curl -fsS -X POST http://127.0.0.1:27779/hsm/v2/groups \
    -H "Authorization: Bearer $SMD_JWT" -H 'Content-Type: application/json' -d @-
curl -fsS http://127.0.0.1:27779/hsm/v2/groups/compute \
  -H "Authorization: Bearer $SMD_JWT" | jq .
NODE_UUID=$(jq -r --arg node "$NODE_XNAME" \
  '.ComponentEndpoints[] | select(.ID == $node) | .UUID' "$DEMO_DIR/endpoints.json")
"$MAGELLAN_BIN" power "$NODE_UUID" --inventory-file "$DEMO_DIR/inventory.json" \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" --insecure
unset BMC_PASSWORD

jq '.[].Systems[].ethernet_interfaces' "$DEMO_DIR/inventory.json"
read -r -p 'PXE MAC from the discovered interfaces: ' BOOT_MAC
read -r -p 'Node-reachable kernel URL: ' KERNEL_URL
read -r -p 'Node-reachable initrd URL: ' INITRD_URL
read -r -p 'Kernel command line: ' BOOT_PARAMS
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$KERNEL_URL" --arg initrd "$INITRD_URL" --arg params "$BOOT_PARAMS" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' |
  curl -fsS -X POST http://127.0.0.1:27778/boot/v1/bootparameters \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
curl -fsS "http://127.0.0.1:27778/boot/v1/bootscript?host=$NODE_XNAME"
curl -fsS "http://127.0.0.1:27778/boot/v1/bootscript?mac=$BOOT_MAC"