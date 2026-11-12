#!/usr/bin/env bash

set -euo pipefail
cd "${OPERATOR_DIR:-$PWD}"
MAGELLAN_BIN="${MAGELLAN_BIN:-magellan}"
umask 077
DEMO_DIR=$(mktemp -d)
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}172.24.0.3,127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}172.24.0.3,127.0.0.1,localhost"

run_step() {
  local command_text="$1"
  shift
  printf '\n$ %s\n' "$command_text" >&2
  IFS= read -r -p 'Press Enter to run this command (Ctrl-C to stop): ' _ </dev/tty
  "$@"
}

printf '\n=== Build and deploy the operator ===\n'
run_step 'make dev-up' make dev-up
run_step 'make build' make build
run_step 'make dev-deploy' make dev-deploy

printf '\n=== Delete the old demo control plane and data ===\n'
run_step 'kubectl delete openchamicontrolplane testcluster -n default --ignore-not-found --wait=true' \
  kubectl delete openchamicontrolplane testcluster -n default --ignore-not-found --wait=true
run_step 'kubectl delete namespace openchami-testcluster --ignore-not-found --wait=true' \
  kubectl delete namespace openchami-testcluster --ignore-not-found --wait=true

printf '\n=== Create the control plane ===\n'
run_step 'kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml' \
  kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml
run_step "kubectl patch openchamicontrolplane testcluster -n default --type=merge -p '{\"spec\":{\"services\":{\"magellan\":{\"enabled\":false}}}}'" \
  kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
run_step 'kubectl get pods -n openchami-testcluster' kubectl get pods -n openchami-testcluster
run_step 'kubectl get pods -n openchami-testcluster' kubectl get pods -n openchami-testcluster

printf '\n=== Connect to BSS ===\n'
start_forward() {
  exec 3< <(exec kubectl port-forward --address 127.0.0.1 \
    -n openchami-testcluster svc/boot-service :27778 2>&1)
  PF_PID=$!
  IFS= read -r FORWARD_LINE <&3
}
run_step 'kubectl port-forward --address 127.0.0.1 -n openchami-testcluster svc/boot-service :27778' start_forward
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
run_step 'printf "%s\\n" "$FORWARD_LINE"' printf '%s\n' "$FORWARD_LINE"
BSS_URL=$(run_step "sed -n 's/^Forwarding from \\(http:\\/\\/\\)\\{0,1\\}\\(127\\.0\\.0\\.1:[0-9]*\\) ->.*/http:\\/\\/\\2/p' <<< \"\$FORWARD_LINE\"" \
  sed -n 's/^Forwarding from \(http:\/\/\)\{0,1\}\(127\.0\.0\.1:[0-9]*\) ->.*/http:\/\/\2/p' \
  <<< "$FORWARD_LINE")
run_step 'kubectl exec -n openchami-testcluster deploy/tokensmith -- /usr/local/bin/tokensmith user-token create --subject demo-admin --audience boot-service --scopes boot:read,boot:write,node:read,node:write --key-file /var/lib/tokensmith/keys/private.pem --enable-local-user-mint > "$DEMO_DIR/token.txt"' \
  kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience boot-service \
  --scopes boot:read,boot:write,node:read,node:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint > "$DEMO_DIR/token.txt"
BSS_JWT=$(run_step "tr -d '\\r\\n' < \"\$DEMO_DIR/token.txt\"" \
  tr -d '\r\n' < "$DEMO_DIR/token.txt")
rm "$DEMO_DIR/token.txt"

printf '\n=== Discover 172.24.0.3 with Magellan ===\n'
BMC_USERNAME" read -r -p 'BMC username: ' BMC_USERNAME
BMC_PASSWORD" read -r -s -p 'BMC password: ' BMC_PASSWORD
printf '\n'
run_step 'magellan scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"' \
  "$MAGELLAN_BIN" scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"
run_step "magellan collect --cache \"\$DEMO_DIR/assets.db\" --insecure --username \"\$BMC_USERNAME\" --password \"\$BMC_PASSWORD\" --bmc-id-map '{\"map_key\":\"bmc-ip-addr\",\"id_map\":{\"172.24.0.3\":\"x1000c0s0b0\"}}' --output-format json --output-file \"\$DEMO_DIR/inventory.json\"" \
  "$MAGELLAN_BIN" collect --cache "$DEMO_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
  --output-format json --output-file "$DEMO_DIR/inventory.json"
run_step 'unset BMC_PASSWORD' unset BMC_PASSWORD
SYSTEM_FILTER='.[0].Systems | length > 0'
run_step "jq -e '$SYSTEM_FILTER' \"\$DEMO_DIR/inventory.json\"" \
  jq -e "$SYSTEM_FILTER" "$DEMO_DIR/inventory.json" > /dev/null
run_step 'jq .[].Systems "$DEMO_DIR/inventory.json"' \
  jq '.[].Systems' "$DEMO_DIR/inventory.json"
NODE_XNAME=$(run_step "jq -r '.[0].ID + \"n0\"' \"\$DEMO_DIR/inventory.json\"" \
  jq -r '.[0].ID + "n0"' "$DEMO_DIR/inventory.json")
MAC_FILTER='.[0].Systems[0].ethernet_interfaces[0].mac | ascii_downcase | gsub("-"; ":")'
BOOT_MAC=$(run_step "jq -r '$MAC_FILTER' \"\$DEMO_DIR/inventory.json\"" \
  jq -r "$MAC_FILTER" \
  "$DEMO_DIR/inventory.json")

printf '\n=== Register the discovered node in BSS ===\n'
run_step "jq -nc --arg node \"\$NODE_XNAME\" --arg mac \"\$BOOT_MAC\" '{apiVersion:\"boot.openchami.io/v1\",kind:\"Node\",metadata:{name:\$node},spec:{xname:\$node,bootMac:\$mac}}' > \"\$DEMO_DIR/node.json\"" \
  jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  '{apiVersion:"boot.openchami.io/v1",kind:"Node",metadata:{name:$node},spec:{xname:$node,bootMac:$mac}}' \
  > "$DEMO_DIR/node.json"
run_step 'curl -X POST "$BSS_URL/nodes" -d @"$DEMO_DIR/node.json"' \
  curl -fsS -X POST "$BSS_URL/nodes" -H "Authorization: Bearer $BSS_JWT" \
  -H 'Content-Type: application/json' -d "@$DEMO_DIR/node.json"

printf '\n=== Set Alpine Linux boot parameters ===\n'
NETBOOT=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot
run_step "jq -nc --arg node \"\$NODE_XNAME\" --arg mac \"\$BOOT_MAC\" --arg kernel \"\$NETBOOT/vmlinuz-lts\" --arg initrd \"\$NETBOOT/initramfs-lts\" --arg params 'ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=\$NETBOOT/modloop-lts' '{hosts:[\$node],macs:[\$mac],kernel:\$kernel,initrd:\$initrd,params:\$params}' > \"\$DEMO_DIR/boot-parameters.json\"" \
  jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$NETBOOT/vmlinuz-lts" --arg initrd "$NETBOOT/initramfs-lts" \
  --arg params "ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=$NETBOOT/modloop-lts" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' \
  > "$DEMO_DIR/boot-parameters.json"
run_step 'curl -X POST "$BSS_URL/boot/v1/bootparameters" -d @"$DEMO_DIR/boot-parameters.json"' \
  curl -fsS -X POST "$BSS_URL/boot/v1/bootparameters" \
  -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' \
  -d "@$DEMO_DIR/boot-parameters.json"

printf '\n=== iPXE script by node name ===\n'
run_step 'curl "$BSS_URL/boot/v1/bootscript?host=$NODE_XNAME"' \
  curl -fsS "$BSS_URL/boot/v1/bootscript?host=$NODE_XNAME"
printf '\n=== iPXE script by discovered MAC ===\n'
run_step 'curl "$BSS_URL/boot/v1/bootscript?mac=$BOOT_MAC"' \
  curl -fsS "$BSS_URL/boot/v1/bootscript?mac=$BOOT_MAC"