# OpenCHAMI Live Demo

**Discover a real server, then generate its boot script.** The operator provides the services, Magellan reads the BMC at `172.24.0.3`, and Boot Script Service (BSS) turns the discovered node and boot configuration into iPXE instructions.

This walkthrough follows the working **Magellan -> BSS** path. It does not import inventory into SMD, configure DHCP, or reboot the physical server.

## Present the Demo

Run [demo-fresh.sh](demo-fresh.sh) from the operator checkout. It displays each command and waits for Enter so you can explain the step before executing it. Ctrl-C stops the demo.

**Fresh start deletes `testcluster` and its namespace, including namespaced demo data.** Kind, Vault, and LocalStack remain in place.

<details>
<summary>Commands: start the guided demo or a fast rerun</summary>

```bash
# Guided fresh start, from the operator checkout.
bash /path/to/operator-demo/demo-fresh.sh

# Alternative: reuse the existing deployment and collected inventory.
bash /path/to/operator-demo/demo.sh
```

</details>

## Walk Through the Operations

The sections below explain the calls without requiring you to read shell plumbing. Expand a command block only when you want to run that step manually. Use Bash, stay in the operator checkout, and run the blocks in order in the same shell. You need `make`, `kubectl`, `curl`, `jq`, and a pre-built `magellan` on PATH, plus access to the BMC.

### 1. Deploy the Operator

**Operation:** local development setup, not a BSS API call.

Start the development infrastructure, build the binaries, and deploy the operator into Kubernetes. The operator will reconcile the control-plane resource in step 3.

**Result:** the operator is running and ready to manage OpenCHAMI services.

<details>
<summary>Commands: build and deploy</summary>

```bash
make dev-up
make build
make dev-deploy
```

</details>

### 2. Reset the Demo Data

**Operation:** delete the Kubernetes control-plane resource and its namespace.

**Targets:** `OpenCHAMIControlPlane/testcluster` in `default`, then namespace `openchami-testcluster`.

**Result:** the next deployment starts without previous BSS nodes or boot configurations. This is the destructive step, not a reboot of the physical server.

<details>
<summary>Commands: delete the previous demo</summary>

```bash
kubectl delete openchamicontrolplane testcluster -n default --ignore-not-found --wait=true
kubectl delete namespace openchami-testcluster --ignore-not-found --wait=true
```

</details>

### 3. Create the Control Plane

**Operation:** submit the control-plane manifest to Kubernetes. The operator creates the services and their dependencies.

**Arguments:** the minimal control-plane fixture; namespace `default`; local Magellan discovery rather than the in-cluster scheduler.

**Result:** `testcluster` reaches `Ready`, and BSS and TokenSmith deployments are available.

<details>
<summary>Commands: apply the manifest and wait for services</summary>

```bash
kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=300s
kubectl rollout status deployment/boot-service -n openchami-testcluster --timeout=180s
kubectl rollout status deployment/tokensmith -n openchami-testcluster --timeout=180s
kubectl get pods -n openchami-testcluster
```

</details>

### 4. Connect to BSS

**Operation:** forward a local port to the Kubernetes `boot-service` service.

**Arguments:** service port `27778`; an automatically allocated local port on `127.0.0.1`.

**Result:** `BSS_URL` is the base URL used for all BSS requests below. Port forwarding is development access plumbing, not a BSS API operation.

<details>
<summary>Commands: open the connection and capture its URL</summary>

```bash
set -euo pipefail
umask 077
DEMO_DIR=$(mktemp -d)
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}172.24.0.3,127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}172.24.0.3,127.0.0.1,localhost"

exec 3< <(exec kubectl port-forward --address 127.0.0.1 \
  -n openchami-testcluster svc/boot-service :27778 2>&1)
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
IFS= read -r FORWARD_LINE <&3
printf '%s\n' "$FORWARD_LINE"
BSS_URL=$(printf '%s\n' "$FORWARD_LINE" |
  sed -n 's/^Forwarding from \(127\.0\.0\.1:[0-9]*\) ->.*/http:\/\/\1/p')
```

</details>

### 5. Authorize BSS Writes

**Operation:** run TokenSmith's token-creation CLI inside its deployment. No HTTP authentication endpoint is called in this demo.

| Argument | Value | Meaning |
| --- | --- | --- |
| Subject | `demo-admin` | Identity making the requests |
| Audience | `boot-service` | Service that accepts this token |
| Scopes | `boot:read`, `boot:write`, `node:read`, `node:write` | Allowed operations |

**Result:** `BSS_JWT` contains a signed token. Authenticated requests send it as `Authorization: Bearer <token>`; the value is not printed.

<details>
<summary>Commands: mint the BSS token</summary>

```bash
BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject demo-admin --audience boot-service \
  --scopes boot:read,boot:write,node:read,node:write \
  --key-file /var/lib/tokensmith/keys/private.pem \
  --enable-local-user-mint | tr -d '\r\n')
```

</details>

### 6. Discover the Physical Server

**Operation:** Magellan probes the BMC and follows its Redfish resources to collect system and NIC inventory. This is several requests, not one POST to OpenCHAMI.

| Endpoint or argument | Purpose |
| --- | --- |
| `https://172.24.0.3:443/redfish/v1/` | BMC Redfish service root |
| Linked `Systems` and `Managers` resources | Hardware and BMC inventory |
| BMC username and password | Authenticate to the BMC, separately from the BSS token |
| BMC ID map | Assign `172.24.0.3` the location name `x1000c0s0b0` |
| `--insecure` | Accept the lab BMC's certificate without verification |

**Result:** collected inventory includes the actual UUID, model, serial number, NIC MACs, and reported power state. The demo names the first discovered system `x1000c0s0b0n0` and uses its first reported NIC; those naming/selection choices are demo configuration, not additional discovered facts.

<details>
<summary>Commands: collect inventory and select the demo node</summary>

```bash
IFS= read -r -p 'BMC username: ' BMC_USERNAME
IFS= read -r -s -p 'BMC password: ' BMC_PASSWORD
printf '\n'
magellan scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"
magellan collect --cache "$DEMO_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
  --output-format json --output-file "$DEMO_DIR/inventory.json"
unset BMC_PASSWORD
jq '.[].Systems' "$DEMO_DIR/inventory.json"
NODE_XNAME=$(jq -r '.[0].ID + "n0"' "$DEMO_DIR/inventory.json")
BOOT_MAC=$(jq -r '.[0].Systems[0].ethernet_interfaces[0].mac | ascii_downcase | gsub("-"; ":")' \
  "$DEMO_DIR/inventory.json")
```

</details>

### 7. Register the Node in BSS

**Call:** `POST /nodes` at `BSS_URL`.

**Headers:** BSS bearer token and `Content-Type: application/json`.

| Body field | Value | Meaning |
| --- | --- | --- |
| `apiVersion`, `kind` | `boot.openchami.io/v1`, `Node` | Resource envelope |
| `metadata.name` | `NODE_XNAME` | Name of the BSS record |
| `spec.xname` | `NODE_XNAME` | Node identifier for host lookups |
| `spec.bootMac` | `BOOT_MAC` | Discovered MAC, normalized to colon notation |

**Result:** BSS returns the node record with its generated UID. This tells BSS which node a later host or MAC request refers to; it does not create hardware or change the BMC.

<details>
<summary>Commands: build the node body and POST it</summary>

```bash
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  '{apiVersion:"boot.openchami.io/v1",kind:"Node",metadata:{name:$node},spec:{xname:$node,bootMac:$mac}}' \
  > "$DEMO_DIR/node.json"
curl -fsS -X POST "$BSS_URL/nodes" \
  -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' \
  -d "@$DEMO_DIR/node.json" | jq .
```

</details>

### 8. Set the Boot Configuration

**Call:** `POST /boot/v1/bootparameters` at `BSS_URL`.

**Headers:** BSS bearer token and `Content-Type: application/json`.

| Body field | Meaning |
| --- | --- |
| `hosts` | Node XName to associate with the configuration |
| `macs` | Discovered NIC MAC to associate with the configuration |
| `kernel` | Alpine Linux netboot kernel URL |
| `initrd` | Matching Alpine initial RAM filesystem URL |
| `params` | Kernel arguments: DHCP networking, Alpine repository, and module image URL |

**Result:** BSS returns stored boot parameters for the registered node. These are chosen OS settings, not settings Magellan discovers from the BMC. The URLs use published Alpine 3.22 x86-64 netboot files.

<details>
<summary>Commands: build the boot configuration and POST it</summary>

```bash
NETBOOT=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$NETBOOT/vmlinuz-lts" --arg initrd "$NETBOOT/initramfs-lts" \
  --arg params "ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=$NETBOOT/modloop-lts" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' \
  > "$DEMO_DIR/boot-parameters.json"
curl -fsS -X POST "$BSS_URL/boot/v1/bootparameters" \
  -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' \
  -d "@$DEMO_DIR/boot-parameters.json" | jq .
```

</details>

### 9. Generate the iPXE Script

**Call:** `GET /boot/v1/bootscript` at `BSS_URL`. No bearer token is sent, matching an unauthenticated node boot request.

| Query argument | Example | Meaning |
| --- | --- | --- |
| `host` | `x1000c0s0b0n0` | Resolve the registered node by XName |
| `mac` | `a4:bf:01:3f:6b:40` | Resolve it by the selected discovered NIC |

Use one identifier per request. Both requests should resolve the same node and boot configuration.

**Result:** text starting with `#!ipxe`, containing the Alpine kernel and initrd URLs, and ending in a `boot` instruction. BSS has generated instructions; this demo does not execute them on the server.

<details>
<summary>Commands: fetch the script by host and by MAC</summary>

```bash
curl -fsS "$BSS_URL/boot/v1/bootscript?host=$NODE_XNAME"
curl -fsS "$BSS_URL/boot/v1/bootscript?mac=$BOOT_MAC"
```

</details>

### 10. Close the Local Connection

**Operation:** stop this walkthrough's port-forward and discard temporary files and credentials. The deployed services and BSS records remain available.

<details>
<summary>Commands: clean up the manual session</summary>

```bash
kill "$PF_PID"
trap - EXIT
exec 3<&-
unset BSS_JWT BMC_PASSWORD
rm -r "$DEMO_DIR"
```

</details>