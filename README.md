# OpenCHAMI Operator Live Demo Guide

This demo discovers the real BMC at `172.24.0.3` using a pre-built Magellan CLI on your workstation, sends its Redfish inventory to the operator-managed SMD, and optionally generates a BSS boot script for a discovered node. It does not reset, power-cycle, or change boot settings on the server.

## Prerequisites

- A pre-built Magellan executable with `scan`, `collect`, and `send` commands.
- The OpenCHAMI operator checkout, including its development cluster and minimal control-plane fixture. The default location is `../openchami-operator` relative to this demo repository.
- `bash`, `make`, `kubectl`, `curl`, `jq`, and the AWS CLI on the workstation.
- A route from the workstation to `172.24.0.3:443` and a BMC account permitted to read Redfish inventory. The BMC IP is not the compute node's PXE IP or MAC address.

The current operator checkout does not implement the scheduled Magellan discovery pipeline: BMC credentials and SMD authentication are not wired into its CronJob. This guide disables only that in-cluster scheduler and uses the pre-built CLI for discovery. No Magellan build or container image is required.

## Part 1: Set Up the Operator

Run these commands from this demo repository:

```bash
export OPERATOR_DIR="${OPERATOR_DIR:-$PWD/../openchami-operator}"
export MAGELLAN_BIN="${MAGELLAN_BIN:-$PWD/../magellan/magellan}"
export BMC_IP=172.24.0.3
export BMC_XNAME=x1000c0s0b0

"$MAGELLAN_BIN" version
"$MAGELLAN_BIN" scan --help
"$MAGELLAN_BIN" collect --help
"$MAGELLAN_BIN" send --help

make -C "$OPERATOR_DIR" dev-up
make -C "$OPERATOR_DIR" build
make -C "$OPERATOR_DIR" dev-deploy
```

Set `MAGELLAN_BIN` to your existing executable if it is elsewhere. `BMC_XNAME` is an explicit demo location assignment for this BMC, not a value inferred from Redfish. Change it to your real cabinet/chassis/slot assignment if appropriate. Magellan derives node XNames under this BMC from the discovered systems.

Do not delete `testcluster` for an ordinary rerun. A reset removes the operator-managed control plane and its inventory; use `bash ./demo.sh --reset` only when you intentionally want a fresh development environment.

## Part 2: Discover the Real Hardware

Enter the BMC username locally; the script prompts for the password without echoing it. Do not paste credentials into this guide or commit them. Run the script in Bash, not by sourcing it.

```bash
printf 'BMC username: '
IFS= read -r BMC_USERNAME
export BMC_USERNAME
bash ./demo.sh
```

The script deploys `testcluster`, waits for `Ready`, checks the S3 bucket, starts SMD/BSS port-forwards, and mints TokenSmith JWTs. It verifies that SMD rejects unauthenticated writes, then uses this discovery flow:

```text
Magellan scan https://172.24.0.3:443
  -> Magellan collect (Redfish credentials and BMC XName map)
  -> Magellan send (SMD JWT)
  -> SMD node and Ethernet inventory
```

Only that BMC is scanned. Each run uses an isolated temporary cache, so old scan results cannot introduce unrelated hardware. The cache and inventory file are private and removed on exit. Existing SMD/BSS records are not deleted. Collection currently passes credentials using Magellan's CLI flags; avoid shell tracing (`bash -x`), debug logging, and running on a shared workstation where process arguments can be inspected.

Magellan `send --force-update` refreshes this mapped BMC if SMD rejects a duplicate registration. Reruns do not delete unrelated inventory or BSS records.

The script uses `--insecure` for BMC scan and collection to accommodate a self-signed lab certificate. This bypass applies to the BMC only, not to SMD. For a trusted BMC certificate, remove those flags and use your installed Magellan's CA options as supported by `--help`.

The script prints discovered node records and their Ethernet interfaces. It never writes fake compute nodes, MAC addresses, NIDs, or node IP addresses. If the BMC exposes multiple nodes, rerun with `NODE_XNAME` set to one of the printed IDs. If no node appears, inspect the Redfish inventory and SMD logs rather than creating a synthetic fallback.

## Part 3: Inspect the Provisioned Control Plane

```bash
kubectl get openchamicontrolplane testcluster -n default
kubectl get pods -n openchami-testcluster
kubectl get openchamicontrolplane testcluster -n default \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
```

To inspect SMD after the script exits, start a new port-forward and mint a new token in the same shell:

```bash
kubectl port-forward -n openchami-testcluster svc/smd 27779:27779 &
PF_SMD_PID=$!

export SMD_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience hsm \
  --scopes node:read,node:write,group:read,group:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')

curl -fsS http://127.0.0.1:27779/hsm/v2/Inventory/RedfishEndpoints \
  -H "Authorization: Bearer $SMD_JWT" | jq .
curl -fsS http://127.0.0.1:27779/hsm/v2/State/Components \
  -H "Authorization: Bearer $SMD_JWT" | jq .
curl -fsS http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces \
  -H "Authorization: Bearer $SMD_JWT" | jq .

kill "$PF_SMD_PID"
unset SMD_JWT
```

Wait for kubectl's `Forwarding from ...` message before issuing the curl requests.

## Part 4: Optional Real Boot Artifacts and BSS Script

Discovery does not require boot artifacts. To also configure BSS, provide an actual kernel, matching initrd, and kernel command line for your node. Do not use the old dummy payloads.

LocalStack remains a development S3 store. You may upload real files to the provisioned bucket:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1 AWS_PAGER=""

printf 'Path to kernel: '
IFS= read -r KERNEL_FILE
printf 'Path to initrd: '
IFS= read -r INITRD_FILE
aws --endpoint-url=http://127.0.0.1:4566 s3 cp "$KERNEL_FILE" s3://testcluster-boot-images/vmlinuz
aws --endpoint-url=http://127.0.0.1:4566 s3 cp "$INITRD_FILE" s3://testcluster-boot-images/initramfs.img
aws --endpoint-url=http://127.0.0.1:4566 s3 ls s3://testcluster-boot-images/
```

Set the artifact URLs to addresses reachable from the compute node's PXE network, with permission to download the objects. `127.0.0.1`, the Kind-only `openchami-localstack-dev` hostname, and a workstation-only port-forward are not valid artifact addresses for the physical node. Uploading files does not establish external routing or anonymous object access.

The prompts below avoid embedding invented network details:

```bash
printf 'Discovered node XName: '
IFS= read -r NODE_XNAME
printf 'Discovered PXE NIC MAC (not the BMC MAC): '
IFS= read -r BOOT_MAC
printf 'Node-reachable kernel URL: '
IFS= read -r BOOT_KERNEL_URL
printf 'Node-reachable initrd URL: '
IFS= read -r BOOT_INITRD_URL
printf 'Kernel command line for this node: '
IFS= read -r BOOT_PARAMS
export NODE_XNAME BOOT_MAC BOOT_KERNEL_URL BOOT_INITRD_URL BOOT_PARAMS

bash ./demo.sh
```

The script verifies the chosen node and MAC against SMD inventory, registers boot parameters with those discovered identifiers, then fetches unauthenticated iPXE scripts by host and MAC. It does not assume a NID or overwrite a node's discovered state/role. Multiple NICs require an explicit PXE MAC choice; a single reported NIC is selected automatically if `BOOT_MAC` is unset.

This demonstrates discovery and script generation, not a complete physical PXE boot. Actually booting requires DHCP/iPXE configuration, a node-reachable BSS endpoint, accessible artifacts, and any needed metadata service. Confirm those independently before changing boot order or powering the server.

## Part 5: Cleanup

The script stops its own port-forwards and removes temporary discovery files on exit. It leaves the control plane and discovered inventory intact. Clear local optional configuration after the demo:

```bash
unset BMC_USERNAME BMC_PASSWORD SMD_JWT BSS_JWT
unset NODE_XNAME BOOT_MAC BOOT_KERNEL_URL BOOT_INITRD_URL BOOT_PARAMS
```

## Offline Validation

These checks do not contact the BMC or modify the cluster:

```bash
bash -n ./demo.sh
bash ./tests/demo-test.sh
```
