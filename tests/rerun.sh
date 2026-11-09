#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export DEMO_DIR="$TEST_DIR/cache" TRACE="$TEST_DIR/trace"
mkdir -p "$DEMO_DIR"
printf '%s\n' '[{"ID":"x1000c0s0b0","Systems":[{"uuid":"real-uuid","power":{"state":"Off"},"ethernet_interfaces":[{"mac":"a4-bf-01-3f-6b-40"}]}]}]' > "$DEMO_DIR/inventory.json"

make() { printf 'Unexpected setup\n' >&2; return 1; }
magellan() {
  if [[ "$TEST_MODE" != session-failure && "$TEST_MODE" != refresh ]]; then
    printf 'Unexpected BMC request\n' >&2
    return 1
  fi
  printf 'magellan %s\n' "$1" >> "$TRACE"
  if [[ "$1" == collect ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output-file ]]; then
        if [[ "$TEST_MODE" == session-failure ]]; then printf '[]\n' > "$2"
        else cp "$DEMO_DIR/inventory.json" "$2"; fi
        return 0
      fi
      shift
    done
    return 1
  fi
}
kubectl() {
  case "$1" in
    port-forward)
      if [[ "$TEST_MODE" == forward-failure ]]; then
        printf 'Simulated port-forward failure\n' >&2
        return 1
      fi
      case "$*" in
        *svc/smd*) printf 'Forwarding from 127.0.0.1:39101 -> 27779\n' ;;
        *) printf 'Forwarding from 127.0.0.1:39102 -> 27778\n' ;;
      esac
      printf '%s\n' "$BASHPID" >> "$TRACE.pids"
      while :; do sleep 0.1; done
      ;;
    exec) printf 'test-token\n' ;;
    *) return 0 ;;
  esac
}
curl() {
  local method=GET url='' output='' write_code=false payload='' code=200 body='{}'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift ;;
      -o) output="$2"; shift ;;
      -w) write_code=true; shift ;;
      -H|--connect-timeout|--max-time|--noproxy) shift ;;
      --user)
        [[ "$2" == 'test-root: pass ' ]] || return 1
        shift ;;
      -d)
        payload="$2"
        if [[ "$payload" == @- ]]; then payload=$(cat); fi
        shift ;;
      http://*|https://*) url="$1" ;;
    esac
    shift
  done
  printf '%s %s\n' "$method" "$url" >> "$TRACE"
  [[ "$url" == http://127.0.0.1:3910[12]/* || "$url" == https://172.24.0.3/redfish/v1/Systems ]] || return 1
  case "$url" in
    https://172.24.0.3/redfish/v1/Systems)
      if [[ "$TEST_MODE" == auth-failure ]]; then code=401; fi ;;
    */Inventory/RedfishEndpoints)
      case "$TEST_MODE" in
        existing|member) code=409 ;;
        import-failure) code=400; body='{"error":"rejected inventory"}' ;;
      esac ;;
    */Inventory/ComponentEndpoints)
      if [[ "$TEST_MODE" == import-failure || ( "$TEST_MODE" == new && ! -f "$TRACE.registered" ) ]]; then
        body='{"ComponentEndpoints":[{"ID":"x1000c0s0b0n1","RedfishEndpointID":"x1000c0s0b0","UUID":"stale-uuid"}]}'
        touch "$TRACE.registered"
      else
        body='{"ComponentEndpoints":[{"ID":"x1000c0s0b0n0","RedfishEndpointID":"x1000c0s0b0","UUID":"real-uuid"},{"ID":"x1000c0s0b0n1","RedfishEndpointID":"x1000c0s0b0","UUID":"stale-uuid"}]}'
      fi ;;
    */groups/compute)
      if [[ "$TEST_MODE" == new && "$method" == GET ]]; then code=404
      elif [[ "$TEST_MODE" == member ]]; then
        body='{"members":{"ids":["another-node","x1000c0s0b0n0"]}}'
      else body='{"members":{"ids":["another-node"]}}'; fi ;;
    */nodes)
      if [[ "$method" == GET ]]; then
        if [[ "$TEST_MODE" == existing || "$TEST_MODE" == member ]]; then
          body='[{"metadata":{"uid":"node-uid"},"spec":{"xname":"x1000c0s0b0n0","role":"Compute","bootMac":"old"}}]'
        else body='[]'; fi
      fi ;;
    */nodes/node-uid)
      jq -e '.spec.role == "Compute" and .spec.bootMac == "a4:bf:01:3f:6b:40"' <<< "$payload" >/dev/null || return 1 ;;
    */boot/v1/bootparameters)
      jq -e '.hosts == ["x1000c0s0b0n0"] and .macs == ["a4:bf:01:3f:6b:40"]' <<< "$payload" >/dev/null || return 1 ;;
    */boot/v1/bootscript*)
      if [[ "$TEST_MODE" == script-failure ]]; then body=$'#!ipxe\n# Error: node not found\nhalt'
      else body=$'#!ipxe\nboot'; fi ;;
  esac
  if [[ -n "$output" ]]; then printf '%s\n' "$body" > "$output"
  else printf '%s\n' "$body"; fi
  if "$write_code"; then printf '%s' "$code"; fi
}
export -f make magellan kubectl curl
export MAGELLAN_BIN=magellan
unset OPERATOR_DIR BMC_USERNAME BMC_PASSWORD
for TEST_MODE in new existing member; do
  export TEST_MODE
  : > "$TRACE"
  : > "$TRACE.pids"
  bash "$ROOT/demo.sh" > "$TEST_DIR/output"
  grep -q 'Using collected inventory' "$TEST_DIR/output"
  grep -q 'Demo complete' "$TEST_DIR/output"
  if grep -q 'hsm/v2' "$TRACE"; then
    printf 'BSS demo must not depend on SMD requests\n' >&2
    exit 1
  fi
  grep -q '^boot$' "$DEMO_DIR/bootscript-host.ipxe"
  grep -q '^boot$' "$DEMO_DIR/bootscript-mac.ipxe"
  if [[ "$TEST_MODE" == existing || "$TEST_MODE" == member ]]; then
    grep -q 'PUT .*nodes/node-uid' "$TRACE"
  else
    grep -q 'POST .*nodes$' "$TRACE"
  fi
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Forward still running: %s\n' "$pid" >&2
      exit 1
    fi
  done < "$TRACE.pids"
  printf 'PASS: %s resources, cached discovery, no build, dynamic ports, forward cleanup\n' "$TEST_MODE"
done

for TEST_MODE in auth-failure session-failure refresh; do
  export TEST_MODE BMC_USERNAME=test-root BMC_PASSWORD=' pass '
  : > "$TRACE"
  : > "$TRACE.pids"
  before=$(cksum < "$DEMO_DIR/inventory.json")
  if bash "$ROOT/demo.sh" --refresh > "$TEST_DIR/output" 2>&1; then
    [[ "$TEST_MODE" == refresh ]]
    grep -q 'Demo complete' "$TEST_DIR/output"
  else
    [[ "$TEST_MODE" != refresh ]]
    [[ "$(cksum < "$DEMO_DIR/inventory.json")" == "$before" ]]
  fi
  if [[ "$TEST_MODE" == auth-failure ]]; then
    grep -q 'BMC rejected authenticated access' "$TEST_DIR/output"
    if grep -q '^magellan' "$TRACE"; then exit 1; fi
  elif [[ "$TEST_MODE" == session-failure ]]; then
    grep -q 'saved inventory was not replaced' "$TEST_DIR/output"
    if grep -q 'Inventory/RedfishEndpoints' "$TRACE"; then exit 1; fi
  fi
  printf 'PASS: %s authentication/collection path\n' "$TEST_MODE"
done
unset BMC_USERNAME BMC_PASSWORD

for TEST_MODE in script-failure forward-failure; do
  export TEST_MODE
  : > "$TRACE"
  : > "$TRACE.pids"
  if bash "$ROOT/demo.sh" > "$TEST_DIR/output" 2>&1; then
    printf 'FAIL: %s was ignored\n' "$TEST_MODE" >&2
    exit 1
  fi
  if [[ "$TEST_MODE" == forward-failure ]] && grep -q '/boot/v1/bootparameters' "$TRACE"; then
    printf 'FAIL: continued after %s\n' "$TEST_MODE" >&2
    exit 1
  fi
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Forward still running after failure: %s\n' "$pid" >&2
      exit 1
    fi
  done < "$TRACE.pids"
  printf 'PASS: %s stops the run and cleans up owned forwards\n' "$TEST_MODE"
done