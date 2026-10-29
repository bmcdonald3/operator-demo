# OpenCHAMI Operator Live Demo Guide

## Pre-Demo Setup (Run 5 Minutes Before Presenting)

Ensure the local Kind cluster, Vault, LocalStack, CloudNativePG, Envoy Gateway, and the OpenCHAMI Operator are running:

```bash
# 1. Start Kind, Vault, LocalStack, and prerequisite controllers (~2-3 mins if cold)
make dev-up

# 2. Build and deploy the OpenCHAMI operator into the cluster (~1 min)
make dev-deploy

# 3. Clean up any previous testcluster run so the demo starts fresh
kubectl delete openchamicontrolplane testcluster --ignore-not-found --wait=true
```

---

## Part 1: Preview & Deploy the OpenCHAMI Control Plane

### 1.1 Dry-Run Preview with `ochami-admin`
Before applying anything to the cluster, preview the resources the operator will generate from `test/fixtures/minimal-controlplane.yaml`:

```bash
./bin/ochami-admin describe -f test/fixtures/minimal-controlplane.yaml
```

### 1.2 Apply the Control Plane Manifest
Deploy `testcluster` and disable `magellan` (which is not yet wired in the dev fixture) so the control plane reaches `PHASE=Ready`:

```bash
kubectl apply -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
```

### 1.3 Watch the Control Plane Reconcile to `Ready`
Wait for the operator to provision the namespace, PostgreSQL databases, S3 bucket, TLS certificates, Envoy Gateway routes, and OpenCHAMI pods (typically 45–90 seconds):

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=180s

kubectl get openchamicontrolplane testcluster
kubectl get pods -n openchami-testcluster
```

---

## Part 2: Inspect What the Operator Provisioned Automatically

### 2.1 Check All 17 Operator Status Conditions
Show that Vault policies, S3 buckets, CloudNativePG databases, mTLS service identities, Envoy Gateway, and 16 NetworkPolicies were reconciled automatically:

```bash
kubectl get openchamicontrolplane testcluster \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
```

### 2.2 Verify S3 Boot Image Bucket & Upload a Dummy Kernel
Verify that the operator created `testcluster-boot-images` in S3 (LocalStack) and upload a placeholder kernel and initrd:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1

aws --endpoint-url=[http://127.0.0.1:4566](http://127.0.0.1:4566) s3 ls
echo "dummy-kernel-binary" | aws --endpoint-url=[http://127.0.0.1:4566](http://127.0.0.1:4566) s3 cp - s3://testcluster-boot-images/vmlinuz-6.8
echo "dummy-initrd-binary" | aws --endpoint-url=[http://127.0.0.1:4566](http://127.0.0.1:4566) s3 cp - s3://testcluster-boot-images/initramfs-6.8.img
aws --endpoint-url=[http://127.0.0.1:4566](http://127.0.0.1:4566) s3 ls s3://testcluster-boot-images/
```

---

## Part 3: Authenticate via TokenSmith & Populate SMD Inventory

### 3.1 Start Port-Forwards to SMD and Boot Script Service (BSS)
Forward SMD (`27779`) and BSS (`27778`) to `localhost`:

```bash
kubectl port-forward -n openchami-testcluster svc/smd 27779:27779 >/dev/null 2>&1 &
PF_SMD_PID=$!
kubectl port-forward -n openchami-testcluster svc/boot-service 27778:27778 >/dev/null 2>&1 &
PF_BSS_PID=$!
```

### 3.2 Mint an Admin JWT via TokenSmith
Verify that SMD rejects unauthenticated writes, then mint a signed JWT from TokenSmith holding `node:read`, `node:write`, `group:read`, `group:write`, and `boot-service` scopes:

```bash
# 1. Show that unauthenticated writes are rejected by SMD (returns "no token found")
curl -i -X POST [http://127.0.0.1:27779/hsm/v2/State/Components](http://127.0.0.1:27779/hsm/v2/State/Components)

# 2. Mint an admin JWT via TokenSmith
export JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "hsm" \
  --scopes "node:read,node:write,group:read,group:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint)

echo "Token minted (length: ${#JWT} bytes)"
```

### 3.3 Register 2 Compute Nodes in SMD
Register `x1000c0s0b0n0` (NID 1) and `x1000c0s0b0n1` (NID 2) in SMD:

```bash
curl -sS -X POST [http://127.0.0.1:27779/hsm/v2/State/Components](http://127.0.0.1:27779/hsm/v2/State/Components) \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "Components": [
      {
        "ID": "x1000c0s0b0n0",
        "Type": "Node",
        "State": "Ready",
        "Flag": "OK",
        "Enabled": true,
        "Role": "Compute",
        "NID": 1,
        "NetType": "Sling",
        "Arch": "X86"
      },
      {
        "ID": "x1000c0s0b0n1",
        "Type": "Node",
        "State": "Standby",
        "Flag": "OK",
        "Enabled": true,
        "Role": "Compute",
        "NID": 2,
        "NetType": "Sling",
        "Arch": "X86"
      }
    ]
  }'
```

Query SMD to verify both nodes are stored in PostgreSQL:

```bash
curl -sS [http://127.0.0.1:27779/hsm/v2/State/Components](http://127.0.0.1:27779/hsm/v2/State/Components) \
  -H "Authorization: Bearer ${JWT}" | jq .
```

### 3.4 Register Node MAC/IP Mapping & Hardware Group in SMD
Bind MAC address `00:de:ad:be:ef:01` to `x1000c0s0b0n0` and create a `compute` group in SMD:

```bash
# Register Ethernet interface for x1000c0s0b0n0
curl -sS -X POST [http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces](http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces) \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "ComponentID": "x1000c0s0b0n0",
    "Description": "Management NIC",
    "MACAddress": "00:de:ad:be:ef:01",
    "IPAddresses": [{"IPAddress": "172.16.0.101"}]
  }' | jq .

# Create a "compute" group in SMD containing both nodes
curl -sS -X POST [http://127.0.0.1:27779/hsm/v2/groups](http://127.0.0.1:27779/hsm/v2/groups) \
  -H "Authorization: Bearer ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "compute",
    "description": "Standard HPC compute nodes",
    "members": {
      "ids": ["x1000c0s0b0n0", "x1000c0s0b0n1"]
    }
  }' | jq .

# Query the group back from SMD
curl -sS [http://127.0.0.1:27779/hsm/v2/groups/compute](http://127.0.0.1:27779/hsm/v2/groups/compute) \
  -H "Authorization: Bearer ${JWT}" | jq .
```

---

## Part 4: Boot Script Service (BSS) & Service-to-Service Integration

### 4.1 Configure Boot Parameters in BSS
Mint a token targeting BSS (or reuse `$JWT`), register boot parameters for `x1000c0s0b0n0` pointing to the S3 bucket, and simulate a PXE boot:

```bash
# Mint a token with boot-service scopes/audience if BSS validates specific claims
export BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "boot-service" \
  --scopes "boot:read,boot:write,node:read,node:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint)

# Register kernel, initrd, and kernel parameters for x1000c0s0b0n0
curl -sS -i -X POST [http://127.0.0.1:27778/boot/v1/bootparameters](http://127.0.0.1:27778/boot/v1/bootparameters) \
  -H "Authorization: Bearer ${BSS_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "hosts": ["x1000c0s0b0n0"],
    "macs": ["00:de:ad:be:ef:01"],
    "kernel": "s3://testcluster-boot-images/vmlinuz-6.8",
    "initrd": "s3://testcluster-boot-images/initramfs-6.8.img",
    "params": "console=ttyS0,115200n8 ds=nocloud-net;s=[https://testcluster.local/cloud-init/](https://testcluster.local/cloud-init/)"
  }'
```

### 4.2 Simulate an Unauthenticated Node PXE Boot Request
Fetch the iPXE boot script using only the node's MAC address (`00:de:ad:be:ef:01`), matching what an actual compute node's iPXE firmware executes on power-on:

```bash
curl -sS "[http://127.0.0.1:27778/boot/v1/bootscript?mac=00:de:ad:be:ef:01](http://127.0.0.1:27778/boot/v1/bootscript?mac=00:de:ad:be:ef:01)"
```

---

## Part 5: Cleanup Port-Forwards

```bash
kill ${PF_SMD_PID}${PF_BSS_PID} 2>/dev/null || true
```
