#!/usr/bin/env bash
# Copyright © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

set -euo pipefail
cd "${OPERATOR_DIR:-$PWD}"
SETUP=false
REFRESH=false
for argument in "$@"; do
  case "$argument" in
    --setup) SETUP=true ;;
    --refresh) REFRESH=true ;;
    --help)
      printf 'Usage: bash demo.sh [--setup] [--refresh]\n  --setup    Build and deploy the operator and control plane\n  --refresh  Collect fresh inventory from the BMC\n'
      exit 0 ;;
    *) printf 'Unknown option: %s\n' "$argument" >&2; exit 1 ;;
  esac
done
MAGELLAN_BIN="${MAGELLAN_BIN:-magellan}"
umask 077
DEMO_DIR="${DEMO_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/openchami-operator-demo/172.24.0.3}"
mkdir -p "$DEMO_DIR"
chmod 700 "$DEMO_DIR"
RUN_DIR=$(mktemp -d)
PF_PIDS=()
trap 'for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$RUN_DIR"; unset BMC_PASSWORD' EXIT
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}172.24.0.3,127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}172.24.0.3,127.0.0.1,localhost"

if "$SETUP"; then
  [[ -f test/fixtures/minimal-controlplane.yaml ]] || {
    printf 'For --setup, run from the operator checkout or set OPERATOR_DIR.\n' >&2
    exit 1
  }
  printf 'Deploying operator from %s\n' "$PWD"
  make dev-up
  make build
  make dev-deploy
  kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml
  kubectl patch openchamicontrolplane testcluster -n default --type=merge \
    -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
elif ! kubectl get openchamicontrolplane testcluster -n default >/dev/null; then
  printf 'Control plane unavailable. Use --setup for initial deployment.\n' >&2
  exit 1
fi
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=180s
kubectl get pods -n openchami-testcluster

start_forward() {
  local service="$1" remote_port="$2" log="$RUN_DIR/$1.log" pid port attempt
  kubectl port-forward --address 127.0.0.1 -n openchami-testcluster \
    "svc/$service" ":$remote_port" > "$log" 2>&1 &
  pid=$!
  PF_PIDS+=("$pid")
  for attempt in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then cat "$log" >&2; return 1; fi
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' "$log")
    if [[ -n "$port" ]] && curl --noproxy '*' -sS --connect-timeout 1 --max-time 2 \
      -o /dev/null "http://127.0.0.1:$port/"; then
      FORWARD_URL="http://127.0.0.1:$port"
      return 0
    fi
    sleep 0.1
  done
  cat "$log" >&2
  printf 'Timed out forwarding %s\n' "$service" >&2
  return 1
}
start_forward boot-service 27778
BSS_URL="$FORWARD_URL"
printf 'Connected: BSS %s\n' "$BSS_URL"

BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience boot-service \
  --scopes boot:read,boot:write,node:read,node:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')

if "$REFRESH" || ! jq -e 'length == 1 and .[0].ID == "x1000c0s0b0" and
  (.[0].Systems | length > 0) and all(.[0].Systems[]; (.uuid | type == "string" and length > 0))' \
  "$DEMO_DIR/inventory.json" >/dev/null 2>&1; then
  while :; do
    [[ -n "${BMC_USERNAME:-}" ]] || IFS= read -r -p 'BMC username: ' BMC_USERNAME
    if [[ -z "${BMC_PASSWORD:-}" ]]; then
      IFS= read -r -s -p 'BMC password: ' BMC_PASSWORD
      printf '\n'
    fi
    HTTP_CODE=$(curl --noproxy '*' -ksS --connect-timeout 10 --max-time 20 \
      --user "$BMC_USERNAME:$BMC_PASSWORD" -o "$RUN_DIR/redfish-check.json" \
      -w '%{http_code}' https://172.24.0.3/redfish/v1/Systems)
    case "$HTTP_CODE" in
      200) break ;;
      401)
        printf 'BMC rejected authenticated access to /redfish/v1/Systems (HTTP 401).\n' >&2
        unset BMC_USERNAME BMC_PASSWORD
        if [[ ! -t 0 ]]; then exit 1; fi
        IFS= read -r -p 'Retry BMC credentials? [y/N] ' RETRY
        [[ "$RETRY" == y || "$RETRY" == Y ]] || exit 1 ;;
      *)
        printf 'BMC Redfish check failed (HTTP %s).\n' "$HTTP_CODE" >&2
        cat "$RUN_DIR/redfish-check.json" >&2
        exit 1 ;;
    esac
  done
  "$MAGELLAN_BIN" scan https://172.24.0.3:443 --insecure --cache "$RUN_DIR/assets.db"
  "$MAGELLAN_BIN" collect --cache "$RUN_DIR/assets.db" --insecure \
    --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
    --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
    --output-format json --output-file "$RUN_DIR/inventory.json"
  unset BMC_PASSWORD
  if ! jq -e 'length == 1 and .[0].ID == "x1000c0s0b0" and
    (.[0].Systems | length > 0) and all(.[0].Systems[]; (.uuid | type == "string" and length > 0))' \
    "$RUN_DIR/inventory.json" >/dev/null; then
    printf 'Magellan did not collect valid systems; saved inventory was not replaced.\n' >&2
    printf 'If its log reports NoValidSession after the Redfish check passed, investigate Magellan/BMC session handling.\n' >&2
    exit 1
  fi
  mv "$RUN_DIR/inventory.json" "$DEMO_DIR/inventory.json"
else
  printf 'Using collected inventory from %s (use --refresh to rescan)\n' "$DEMO_DIR/inventory.json"
fi
jq '.[].Systems' "$DEMO_DIR/inventory.json"
NODE_UUID=$(jq -er '[.[].Systems[].uuid] | unique |
  if length == 1 then .[0] else error("Expected one discovered system for this demo") end' \
  "$DEMO_DIR/inventory.json")
NODE_XNAME=$(jq -er '.[0].ID + "n0"' "$DEMO_DIR/inventory.json")
printf 'Registering discovered system %s in BSS as %s\n' "$NODE_UUID" "$NODE_XNAME"
printf '\nPower state reported by the saved collection:\n'
jq --arg uuid "$NODE_UUID" '.[].Systems[] | select(.uuid == $uuid) | {uuid, power}' \
  "$DEMO_DIR/inventory.json"

BOOT_MAC=$(jq -er --arg uuid "$NODE_UUID" '
  [.[].Systems[] | select(.uuid == $uuid) | .ethernet_interfaces[] |
    .mac | ascii_downcase | gsub("-"; ":") |
    select(. != "ff:ff:ff:ff:ff:ff" and . != "00:00:00:00:00:00")][0]
' "$DEMO_DIR/inventory.json")
KERNEL_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/vmlinuz-lts
INITRD_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/initramfs-lts
BOOT_PARAMS='ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/modloop-lts'
curl -fsS "$BSS_URL/nodes" -H "Authorization: Bearer $BSS_JWT" > "$RUN_DIR/bss-nodes.json"
BSS_NODE=$(jq -ce --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" '
  [.[]? | select(.spec.xname == $node)] |
  sort_by([
    (if ((.spec.bootMac // "" | ascii_downcase | gsub("-"; ":")) == $mac) then 0 else 1 end),
    .metadata.uid
  ]) | .[0] // {}
' "$RUN_DIR/bss-nodes.json")
if [[ "$BSS_NODE" == '{}' ]]; then
  jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
    '{apiVersion:"boot.openchami.io/v1",kind:"Node",metadata:{name:$node},spec:{xname:$node,bootMac:$mac}}' |
    curl -fsS -X POST "$BSS_URL/nodes" \
      -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
else
  BSS_UID=$(jq -er '.metadata.uid' <<< "$BSS_NODE")
  jq --arg mac "$BOOT_MAC" '.spec.bootMac = $mac' <<< "$BSS_NODE" |
    curl -fsS -X PUT "$BSS_URL/nodes/$BSS_UID" \
      -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
fi
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$KERNEL_URL" --arg initrd "$INITRD_URL" --arg params "$BOOT_PARAMS" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' |
  curl -fsS -X POST "$BSS_URL/boot/v1/bootparameters" \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
for identifier in "host=$NODE_XNAME" "mac=$BOOT_MAC"; do
  SCRIPT_FILE="$DEMO_DIR/bootscript-${identifier%%=*}.ipxe"
  curl -fsS "$BSS_URL/boot/v1/bootscript?$identifier" > "$SCRIPT_FILE"
  cat "$SCRIPT_FILE"
  if ! grep -q '^#!ipxe' "$SCRIPT_FILE" || ! grep -Eq '^boot[[:space:]]*$' "$SCRIPT_FILE" ||
    grep -q '^# Error' "$SCRIPT_FILE"; then
    printf 'BSS did not generate a successful boot script: %s\n' "$SCRIPT_FILE" >&2
    exit 1
  fi
done
printf '\nDemo complete. Scripts saved in %s/bootscript-{host,mac}.ipxe\n' "$DEMO_DIR"