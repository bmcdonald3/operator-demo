#!/usr/bin/env bash

set -euo pipefail
cd "${OPERATOR_DIR:-$PWD}"
MAGELLAN_BIN="${MAGELLAN_BIN:-magellan}"
umask 077
DEMO_DIR=$(mktemp -d)
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}172.24.0.3,127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}172.24.0.3,127.0.0.1,localhost"

printf '\n=== Build and deploy the operator ===\n'
make dev-up
make build
make dev-deploy

printf '\n=== Delete the old demo control plane and data ===\n'
kubectl delete openchamicontrolplane testcluster -n default --ignore-not-found --wait=true
kubectl delete namespace openchami-testcluster --ignore-not-found --wait=true

printf '\n=== Create the control plane ===\n'
kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=300s
kubectl rollout status deployment/boot-service -n openchami-testcluster --timeout=180s
kubectl rollout status deployment/tokensmith -n openchami-testcluster --timeout=180s
kubectl get pods -n openchami-testcluster

printf '\n=== Connect to BSS ===\n'
exec 3< <(exec kubectl port-forward --address 127.0.0.1 \
  -n openchami-testcluster svc/boot-service :27778 2>&1)
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
IFS= read -r FORWARD_LINE <&3
printf '%s\n' "$FORWARD_LINE"
BSS_URL=$(printf '%s\n' "$FORWARD_LINE" | sed -n 's/^Forwarding from \(http:\/\/\)\{0,1\}\(127\.0\.0\.1:[0-9]*\) ->.*/http:\/\/\2/p')
BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience boot-service \
  --scopes boot:read,boot:write,node:read,node:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')

printf '\n=== Discover 172.24.0.3 with Magellan ===\n'
IFS= read -r -p 'BMC username: ' BMC_USERNAME
IFS= read -r -s -p 'BMC password: ' BMC_PASSWORD
printf '\n'
"$MAGELLAN_BIN" scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"
"$MAGELLAN_BIN" collect --cache "$DEMO_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
  --output-format json --output-file "$DEMO_DIR/inventory.json"
unset BMC_PASSWORD
jq '.[].Systems' "$DEMO_DIR/inventory.json"
NODE_XNAME=$(jq -r '.[0].ID + "n0"' "$DEMO_DIR/inventory.json")
BOOT_MAC=$(jq -r '.[0].Systems[0].ethernet_interfaces[0].mac | ascii_downcase | gsub("-"; ":")' \
  "$DEMO_DIR/inventory.json")

printf '\n=== Register the discovered node in BSS ===\n'
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  '{apiVersion:"boot.openchami.io/v1",kind:"Node",metadata:{name:$node},spec:{xname:$node,bootMac:$mac}}' |
  curl -fsS -X POST "$BSS_URL/nodes" \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @- | jq .

printf '\n=== Set Alpine Linux boot parameters ===\n'
NETBOOT=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$NETBOOT/vmlinuz-lts" --arg initrd "$NETBOOT/initramfs-lts" \
  --arg params "ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=$NETBOOT/modloop-lts" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' |
  curl -fsS -X POST "$BSS_URL/boot/v1/bootparameters" \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @- | jq .

printf '\n=== iPXE script by node name ===\n'
curl -fsS "$BSS_URL/boot/v1/bootscript?host=$NODE_XNAME"
printf '\n=== iPXE script by discovered MAC ===\n'
curl -fsS "$BSS_URL/boot/v1/bootscript?mac=$BOOT_MAC"