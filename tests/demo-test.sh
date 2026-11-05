#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OPERATOR_DIR="$ROOT_DIR"
export MAGELLAN_BIN=magellan_mock
export BMC_USERNAME=offline-test-user BMC_PASSWORD=offline-test-password
export BMC_IP=172.24.0.3 BMC_XNAME=x1000c0s0b0
export TEST_MULTIPLE_NICS=false TEST_MULTIPLE_NODES=false
unset NODE_XNAME BOOT_MAC BOOT_KERNEL_URL BOOT_INITRD_URL BOOT_PARAMS

kubectl() {
  if [[ "$1" == exec ]]; then
    printf 'offline-test-token\n'
  fi
}

aws() { return 0; }

magellan_mock() {
  local operation="$1"
  shift
  case "$operation" in
    scan)
      [[ "$1" == https://172.24.0.3:443 ]] || return 1
      ;;
    collect)
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == --output-file ]]; then
          printf '[{"ID":"x1000c0s0b0"}]\n' > "$2"
          return 0
        fi
        shift
      done
      return 1
      ;;
    send)
      [[ "$ACCESS_TOKEN" == offline-test-token ]] || return 1
      [[ " $* " == *" --force-update "* ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

curl() {
  local url='' output='' method=GET
  while [[ $# -gt 0 ]]; do
    case "$1" in
      http://*) url="$1" ;;
      -o) output="$2"; shift ;;
      -X) method="$2"; shift ;;
      -d)
        if [[ "$url" == */bootparameters ]]; then
          jq -e '.hosts == ["x1000c0s0b0n0"] and .macs == ["02:11:22:33:44:55"] and
            .kernel == "http://boot.test/vmlinuz" and (has("nids") | not)' <<< "$2" >/dev/null || return 1
        fi
        shift
        ;;
    esac
    shift
  done
  case "$url" in
    */State/Components)
      if [[ "$method" == POST ]]; then
        printf 401
      else
        if [[ "$TEST_MULTIPLE_NODES" == true ]]; then
          printf '%s\n' '{"Components":[{"ID":"x1000c0s0b0n0","Type":"Node"},{"ID":"x1000c0s0b0n1","Type":"Node"}]}'
        else
          printf '%s\n' '{"Components":[{"ID":"x1000c0s0b0n0","Type":"Node"}]}'
        fi
      fi
      ;;
    */Inventory/EthernetInterfaces)
      if [[ "$TEST_MULTIPLE_NICS" == true ]]; then
        printf '%s\n' '[{"ComponentID":"x1000c0s0b0n0","MACAddress":"02:11:22:33:44:55"},{"ComponentID":"x1000c0s0b0n0","MACAddress":"02:11:22:33:44:66"}]'
      else
        printf '%s\n' '[{"ComponentID":"x1000c0s0b0n0","MACAddress":"02:11:22:33:44:55"}]'
      fi
      ;;
    *)
      if [[ -n "$output" ]]; then
        printf '{}\n' > "$output"
        printf 200
      else
        printf '{}\n'
      fi
      ;;
  esac
}
export -f kubectl aws magellan_mock curl

result="$(bash "$ROOT_DIR/demo.sh")"
[[ "$result" == *'Discovery complete.'* ]]
[[ "$result" == *'02:11:22:33:44:55'* ]]
printf 'PASS: real-BMC target and discovered SMD array parsing\n'

export BMC_PASSWORD=offline-test-password
export BOOT_KERNEL_URL=http://boot.test/vmlinuz
export BOOT_INITRD_URL=http://boot.test/initramfs.img
export BOOT_PARAMS=console=ttyS0
result="$(bash "$ROOT_DIR/demo.sh")"
[[ "$result" == *'Registering Real Boot Parameters'* ]]
[[ "$result" == *'Demo Script Complete'* ]]
printf 'PASS: BSS uses discovered node and NIC without a fabricated NID\n'

export BMC_PASSWORD=offline-test-password
export BOOT_MAC=02:aa:bb:cc:dd:ee
if bash "$ROOT_DIR/demo.sh" >/dev/null 2>&1; then
  printf 'FAIL: an undiscovered MAC was accepted\n' >&2
  exit 1
fi
printf 'PASS: undiscovered NIC rejected\n'

unset BOOT_MAC
export TEST_MULTIPLE_NICS=true
if bash "$ROOT_DIR/demo.sh" >/dev/null 2>&1; then
  printf 'FAIL: multiple NICs were selected automatically\n' >&2
  exit 1
fi
printf 'PASS: multiple NICs require an explicit selection\n'

export BOOT_MAC=02:11:22:33:44:55
result="$(bash "$ROOT_DIR/demo.sh")"
[[ "$result" == *'Demo Script Complete'* ]]
printf 'PASS: explicit discovered PXE NIC accepted\n'

export TEST_MULTIPLE_NODES=true
if bash "$ROOT_DIR/demo.sh" >/dev/null 2>&1; then
  printf 'FAIL: multiple nodes were selected automatically\n' >&2
  exit 1
fi
printf 'PASS: multiple nodes require an explicit selection\n'