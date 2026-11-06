# OpenCHAMI Live Demo

## Fresh-Start Demo

From the operator checkout:

```bash
bash /path/to/operator-demo/demo-fresh.sh
```

This deletes `testcluster` and its namespace, including namespaced demo data, rebuilds/deploys the operator, collects fresh Magellan inventory from `172.24.0.3`, and prints BSS iPXE scripts. It registers directly in BSS without writing SMD inventory. It leaves Kind, Vault, and LocalStack in place and does not reboot the server. No cached inventory, retries, or rerun checks. The existing [demo.sh](demo.sh) remains available for fast reruns.

## Run the Demo

From the operator checkout, with a pre-built `magellan` on PATH:

```bash
# First run: deploy and discover.
bash /path/to/operator-demo/demo.sh --setup --refresh

# Repeat: no rebuild, rescan, port cleanup, or readiness prompts.
bash /path/to/operator-demo/demo.sh

# Collect fresh hardware inventory when needed.
bash /path/to/operator-demo/demo.sh --refresh
```

Use `--setup` again only when rebuilding/redeploying. Set `OPERATOR_DIR` if running setup from another directory. The script chooses free local ports, stops only its own forwards, and updates existing demo records. Collected inventory is cached privately under `~/.cache/openchami-operator-demo/172.24.0.3` (or `$XDG_CACHE_HOME`); repeated runs display the saved power state, not a live power query. BMC credentials are requested only for collection and are not saved by the script.

The commands below are the manual walkthrough, not required when running the script.

## 1. Deploy the Operator and Services

```bash
make dev-up
make build
make dev-deploy
./bin/ochami-admin describe -f test/fixtures/minimal-controlplane.yaml
kubectl apply -n default -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=180s
kubectl get pods -n openchami-testcluster
```

Magellan runs locally because the operator's discovery scheduler is not wired yet. Use an SMD image with the empty NIC-IP fix from the previous run.

## 2. Connect and Authenticate

Wait for both port-forwards to print `Forwarding from` before continuing.

```bash
kubectl port-forward -n openchami-testcluster svc/smd 27779:27779 &
PF_SMD_PID=$!
kubectl port-forward -n openchami-testcluster svc/boot-service 27778:27778 &
PF_BSS_PID=$!

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
```

## 3. Discover the BMC and Import Inventory

`x1000c0s0b0` is the location assigned to this BMC, not synthetic hardware.

```bash
set -euo pipefail
umask 077
DEMO_DIR=$(mktemp -d)
read -r -p 'BMC username: ' BMC_USERNAME
read -r -s -p 'BMC password: ' BMC_PASSWORD
printf '\n'
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}172.24.0.3,127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}172.24.0.3,127.0.0.1,localhost"
magellan scan https://172.24.0.3:443 --insecure --cache "$DEMO_DIR/assets.db"
magellan collect --cache "$DEMO_DIR/assets.db" --insecure \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" \
  --bmc-id-map '{"map_key":"bmc-ip-addr","id_map":{"172.24.0.3":"x1000c0s0b0"}}' \
  --output-format json --output-file "$DEMO_DIR/inventory.json"
jq '.[].Systems' "$DEMO_DIR/inventory.json"
jq -c '.[]' "$DEMO_DIR/inventory.json" | while IFS= read -r endpoint; do
  HTTP_CODE=$(curl -sS -o "$DEMO_DIR/import-response.json" -w '%{http_code}' \
    -X POST http://127.0.0.1:27779/hsm/v2/Inventory/RedfishEndpoints \
    -H "Authorization: Bearer $SMD_JWT" -H 'Content-Type: application/json' \
    -d "$endpoint")
  case "$HTTP_CODE" in
    2??) cat "$DEMO_DIR/import-response.json" ;;
    409)
      ENDPOINT_ID=$(jq -er '.ID' <<< "$endpoint")
      curl -fsS -X PUT "http://127.0.0.1:27779/hsm/v2/Inventory/RedfishEndpoints/$ENDPOINT_ID" \
        -H "Authorization: Bearer $SMD_JWT" -H 'Content-Type: application/json' -d "$endpoint"
      ;;
    *) cat "$DEMO_DIR/import-response.json" >&2; exit 1 ;;
  esac
done
```

## 4. Show the Node in SMD and Its Power Status

Select the SMD node by its collected UUID, then add it to a hardware group and read its power status.

```bash
curl -fsS http://127.0.0.1:27779/hsm/v2/Inventory/ComponentEndpoints \
  -H "Authorization: Bearer $SMD_JWT" > "$DEMO_DIR/endpoints.json"
NODE_XNAME=$(jq -er --slurpfile inventory "$DEMO_DIR/inventory.json" '
  [.ComponentEndpoints[] | . as $endpoint |
    select(.RedfishEndpointID == $inventory[0][0].ID) |
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
magellan power "$NODE_UUID" --inventory-file "$DEMO_DIR/inventory.json" \
  --username "$BMC_USERNAME" --password "$BMC_PASSWORD" --insecure
unset BMC_PASSWORD
```

## 5. Generate a BSS Boot Script

Register the discovered node in BSS using its first reported NIC and Alpine Linux netboot files. This generates a script; it does not reboot the server or configure DHCP.

```bash
BOOT_MAC=$(jq -er --arg uuid "$NODE_UUID" '
  [.[].Systems[] | select(.uuid == $uuid) | .ethernet_interfaces[] |
    .mac | ascii_downcase | gsub("-"; ":") |
    select(. != "ff:ff:ff:ff:ff:ff" and . != "00:00:00:00:00:00")][0]
' "$DEMO_DIR/inventory.json")
KERNEL_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/vmlinuz-lts
INITRD_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/initramfs-lts
BOOT_PARAMS='ip=dhcp alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main modloop=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/modloop-lts'
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  '{apiVersion:"boot.openchami.io/v1",kind:"Node",metadata:{name:$node},spec:{xname:$node,bootMac:$mac}}' |
  curl -fsS -X POST http://127.0.0.1:27778/nodes \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
jq -nc --arg node "$NODE_XNAME" --arg mac "$BOOT_MAC" \
  --arg kernel "$KERNEL_URL" --arg initrd "$INITRD_URL" --arg params "$BOOT_PARAMS" \
  '{hosts:[$node],macs:[$mac],kernel:$kernel,initrd:$initrd,params:$params}' |
  curl -fsS -X POST http://127.0.0.1:27778/boot/v1/bootparameters \
    -H "Authorization: Bearer $BSS_JWT" -H 'Content-Type: application/json' -d @-
curl -fsS "http://127.0.0.1:27778/boot/v1/bootscript?host=$NODE_XNAME"
curl -fsS "http://127.0.0.1:27778/boot/v1/bootscript?mac=$BOOT_MAC"
```

## 6. Cleanup

```bash
kill "$PF_SMD_PID" "$PF_BSS_PID"
unset SMD_JWT BSS_JWT BMC_PASSWORD
rm -r "$DEMO_DIR"
```