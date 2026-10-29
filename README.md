# OpenCHAMI Operator Live Demo Guide

## Pre-Demo Setup (Run 5 Minutes Before Presenting)

```bash
# 1. Start Kind, Vault, LocalStack, and prerequisite controllers (~2-3 mins if cold)
make dev-up

# 2. Build binaries and deploy the OpenCHAMI operator into the cluster (~1 min)
make build
make dev-deploy

# 3. Clean up any previous testcluster run so the demo starts fresh
kubectl delete openchamicontrolplane testcluster --ignore-not-found --wait=true
```

---

## Part 1: Preview & Deploy the OpenCHAMI Control Plane

### 1.1 Dry-Run Preview with `ochami-admin`
Preview the Kubernetes, Vault, and networking resources the operator will generate from `test/fixtures/minimal-controlplane.yaml`:

```bash
./bin/ochami-admin describe -f test/fixtures/minimal-controlplane.yaml
```

### 1.2 Apply the Control Plane Manifest
Deploy `testcluster` and disable `magellan` so the control plane reaches `PHASE=Ready`:

```bash
kubectl apply -f test/fixtures/minimal-controlplane.yaml
kubectl patch openchamicontrolplane testcluster -n default --type=merge \
  -p '{"spec":{"services":{"magellan":{"enabled":false}}}}'
```

### 1.3 Watch the Control Plane Reconcile to `Ready`
Wait for the operator to provision the namespace, PostgreSQL databases, S3 bucket, TLS certificates, Envoy Gateway routes, and OpenCHAMI pods (60–90 seconds):

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  openchamicontrolplane/testcluster -n default --timeout=180s

kubectl get openchamicontrolplane testcluster
kubectl get pods -n openchami-testcluster
```

---

## Part 2: Inspect What the Operator Provisioned Automatically

### 2.1 Check All 17 Operator Status Conditions
```bash
kubectl get openchamicontrolplane testcluster \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
```

### 2.2 Verify S3 Boot Image Bucket & Upload Boot Artifacts
Verify that the operator created `testcluster-boot-images` in S3 (LocalStack) and upload a kernel and initrd:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1 AWS_PAGER=""

aws --endpoint-url=http://127.0.0.1:4566 s3 ls
echo "dummy-kernel-payload" | aws --endpoint-url=http://127.0.0.1:4566 s3 cp - s3://testcluster-boot-images/vmlinuz-6.8
echo "dummy-initrd-payload" | aws --endpoint-url=http://127.0.0.1:4566 s3 cp - s3://testcluster-boot-images/initramfs-6.8.img
aws --endpoint-url=http://127.0.0.1:4566 s3 ls s3://testcluster-boot-images/
```

---

## Part 3: Authenticate via TokenSmith & Populate SMD Inventory

### 3.1 Start Port-Forwards to SMD and Boot Script Service (BSS)
```bash
kubectl port-forward -n openchami-testcluster svc/smd 27779:27779 >/dev/null 2>&1 &
PF_SMD_PID=$!
kubectl port-forward -n openchami-testcluster svc/boot-service 27778:27778 >/dev/null 2>&1 &
PF_BSS_PID=$!
```

### 3.2 Verify JWT Enforcement & Mint Admin Tokens via TokenSmith
```bash
# 1. Show that unauthenticated writes are rejected by SMD (HTTP 401 "no token found")
curl -i -X POST http://127.0.0.1:27779/hsm/v2/State/Components

# 2. Mint an admin JWT for SMD
export SMD_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "hsm" \
  --scopes "node:read,node:write,group:read,group:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint | tr -d '\r\n')

# 3. Mint an admin JWT for Boot Script Service (BSS)
export BSS_JWT=$(kubectl exec -n openchami-testcluster deploy/tokensmith -- \
  /usr/local/bin/tokensmith user-token create \
  --subject "demo-admin" \
  --audience "boot-service" \
  --scopes "boot:read,boot:write,node:read,node:write" \
  --key-file "/var/lib/tokensmith/keys/private.pem" \
  --enable-local-user-mint | tr -d '\r\n')
```

### 3.3 Register 2 Compute Nodes in SMD
```bash
curl -sS -X POST http://127.0.0.1:27779/hsm/v2/State/Components \
  -H "Authorization: Bearer ${SMD_JWT}" \
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

# Query SMD to verify both nodes are stored in PostgreSQL
curl -sS http://127.0.0.1:27779/hsm/v2/State/Components \
  -H "Authorization: Bearer ${SMD_JWT}" | jq .
```

### 3.4 Register Node MAC/IP Mapping & Hardware Group in SMD
```bash
# Register Ethernet interface (00:de:ad:be:ef:01 -> 172.16.0.101) for x1000c0s0b0n0
curl -sS -X POST http://127.0.0.1:27779/hsm/v2/Inventory/EthernetInterfaces \
  -H "Authorization: Bearer ${SMD_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "ComponentID": "x1000c0s0b0n0",
    "Description": "Node Management Network",
    "MACAddress": "00:de:ad:be:ef:01",
    "IPAddresses": [{"IPAddress": "172.16.0.101"}]
  }' | jq .

# Create a "compute" group in SMD containing both nodes
curl -sS -X POST http://127.0.0.1:27779/hsm/v2/groups \
  -H "Authorization: Bearer ${SMD_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "compute",
    "description": "Standard HPC compute nodes",
    "members": {
      "ids": ["x1000c0s0b0n0", "x1000c0s0b0n1"]
    }
  }' | jq .

# Query the group back from SMD
curl -sS http://127.0.0.1:27779/hsm/v2/groups/compute \
  -H "Authorization: Bearer ${SMD_JWT}" | jq .
```

---

## Part 4: Boot Script Service (BSS) & PXE Boot Script Generation

### 4.1 Register the Node and Boot Parameters in BSS
```bash
# Register node record in BSS
curl -sS -X POST http://127.0.0.1:27778/nodes \
  -H "Authorization: Bearer ${BSS_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {"name": "x1000c0s0b0n0"},
    "spec": {
      "xname": "x1000c0s0b0n0",
      "nid": 1,
      "bootMac": "00:de:ad:be:ef:01",
      "role": "Compute"
    }
  }' | jq .

# Register kernel, initrd, and kernel cmdline parameters in BSS
curl -sS -X POST http://127.0.0.1:27778/boot/v1/bootparameters \
  -H "Authorization: Bearer ${BSS_JWT}" \
  -H "Content-Type: application/json" \
  -d '{
    "hosts": ["x1000c0s0b0n0"],
    "macs": ["00:de:ad:be:ef:01"],
    "nids": ["1"],
    "kernel": "http://openchami-localstack-dev:4566/testcluster-boot-images/vmlinuz-6.8",
    "initrd": "http://openchami-localstack-dev:4566/testcluster-boot-images/initramfs-6.8.img",
    "params": "console=ttyS0,115200n8 ds=nocloud-net;s=https://testcluster.local/cloud-init/"
  }' | jq .

# Inspect stored boot parameters
curl -sS http://127.0.0.1:27778/boot/v1/bootparameters \
  -H "Authorization: Bearer ${BSS_JWT}" | jq .
```

### 4.2 Simulate an Unauthenticated Node PXE Boot Request
```bash
# Fetch iPXE script by XName
curl -sS "http://127.0.0.1:27778/boot/v1/bootscript?host=x1000c0s0b0n0"

# Fetch iPXE script by NID
curl -sS "http://127.0.0.1:27778/boot/v1/bootscript?nid=1"

# Fetch iPXE script by MAC address
curl -sS "http://127.0.0.1:27778/boot/v1/bootscript?mac=00:de:ad:be:ef:01"
```

---

## Part 5: Cleanup Port-Forwards

```bash
kill "$PF_SMD_PID" "$PF_BSS_PID" 2>/dev/null || true
```
