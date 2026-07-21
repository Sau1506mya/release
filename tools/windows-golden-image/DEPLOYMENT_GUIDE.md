# Windows 11 Golden Image - Complete Deployment Guide

This guide walks through the end-to-end process of creating and deploying a generalized Windows 11 golden image for OpenShift Virtualization using cloud-native Kubernetes APIs.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: Initial Setup](#phase-1-initial-setup)
3. [Phase 2: Create Windows 11 Golden Image](#phase-2-create-windows-11-golden-image)
4. [Phase 3: Export and Upload to S3](#phase-3-export-and-upload-to-s3)
5. [Phase 4: Deploy as DataSource](#phase-4-deploy-as-datasource)
6. [Phase 5: Use in CI Jobs](#phase-5-use-in-ci-jobs)
7. [Verification](#verification)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### OpenShift Cluster
✅ OpenShift 4.18+ with OpenShift Virtualization operator installed  
✅ Storage class supporting `volumeMode: Block` (e.g., `gp3-csi`)  
✅ Worker nodes with metal instances (for nested virtualization)  
✅ At least 16GB RAM and 4 vCPUs available per VM

### Client Tools
```bash
# Install oc CLI
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/

# Install virtctl
sudo dnf install kubevirt-virtctl
# Or download from: https://github.com/kubevirt/kubevirt/releases

# Install AWS CLI
pip3 install awscli
aws configure  # Configure with your enterprise credentials
```

### Required Resources
- **Windows 11 ISO**: Container image or HTTP-accessible URL
- **S3 Bucket**: Enterprise S3 bucket with write access
- **VirtIO Drivers**: Available at `registry.redhat.io/container-native-virtualization/virtio-win:latest`

### Verify OpenShift Virtualization
```bash
# Check operator is installed
oc get csv -n openshift-cnv | grep kubevirt

# Check HCO (HyperConverged) is running
oc get hco -n openshift-cnv

# Verify worker nodes have virtualization enabled
oc get nodes -o json | jq '.items[].status.allocatable["devices.kubevirt.io/kvm"]'
```

---

## Phase 1: Initial Setup

### Step 1.1: Clone Repository and Navigate

```bash
cd /path/to/openshift/release
git checkout windows-vm-chaos-config  # Or your feature branch
cd tools/windows-golden-image
```

### Step 1.2: Prepare Windows 11 ISO

**Option A: Create Container Image** (Recommended)
```bash
# Create Dockerfile
cat > Dockerfile.windows11-iso <<'EOF'
FROM scratch
ADD Win11_23H2_English_x64.iso /disk/
EOF

# Build and push
podman build -f Dockerfile.windows11-iso -t quay.io/your-org/windows11-iso:23H2 .
podman push quay.io/your-org/windows11-iso:23H2
```

**Option B: Upload to S3**
```bash
aws s3 cp Win11_23H2_English_x64.iso \
    s3://your-bucket/ISOs/Win11_23H2_English_x64.iso \
    --profile your-enterprise-profile
```

### Step 1.3: Configure S3 Credentials

```bash
# Create namespace (if not exists)
oc create namespace openshift-virtualization-os-images

# Create S3 credentials secret
oc create secret generic s3-credentials \
    -n openshift-virtualization-os-images \
    --from-literal=accessKeyId="YOUR_ACCESS_KEY" \
    --from-literal=secretKey="YOUR_SECRET_KEY"

# Verify
oc get secret s3-credentials -n openshift-virtualization-os-images
```

### Step 1.4: Update Manifests with Your Values

Edit `manifests/01-windows11-scratch-vm.yaml`:
```yaml
# Line 101-102: Update with your ISO source
- name: windows-installer
  containerDisk:
    image: quay.io/your-org/windows11-iso:23H2
  # OR use HTTP source:
  # dataVolume:
  #   name: windows11-iso-dv
```

Edit `manifests/04-datasource-from-s3.yaml`:
```yaml
# Line 34: Update S3 URL (will be updated automatically after export)
cdi.kubevirt.io/storage.import.endpoint: "https://your-bucket.s3.amazonaws.com/golden-images/windows11/v1.0.0/windows11-golden.qcow2"

# Line 42: Storage class
storageClassName: gp3-csi  # Use your cluster's storage class
```

---

## Phase 2: Create Windows 11 Golden Image

### Step 2.1: Deploy VirtualMachine

```bash
# Create builder namespace
oc create namespace windows-image-builder

# Deploy VM
oc apply -f manifests/01-windows11-scratch-vm.yaml

# Verify VM is created
oc get vm -n windows-image-builder
oc get vmi -n windows-image-builder  # VMI = VirtualMachineInstance (running VM)
```

### Step 2.2: Access VM Console

```bash
# Open VNC connection
virtctl vnc windows11-golden-builder -n windows-image-builder

# Alternative: Web console VNC
# Navigate to: Virtualization → VirtualMachines → windows11-golden-builder → Console
```

### Step 2.3: Install Windows 11

**⚠️ CRITICAL: Load VirtIO Storage Driver First**

1. **Boot from Windows ISO**
   - Press any key to boot from CD
   - Click "Install Now"

2. **Load VirtIO Storage Driver** (REQUIRED!)
   - At disk selection screen, you'll see no disks
   - Click "Load driver"
   - Browse to VirtIO CD (usually `E:` or `D:`)
   - Navigate to: `viostor\w11\amd64`
   - Select "Red Hat VirtIO SCSI controller"
   - Click "OK" and install

3. **Now the 60GB disk appears!**
   - Select the disk
   - Click "Next" to install Windows

4. **Complete Windows Setup**
   - Set region, keyboard layout
   - **Create local administrator account** (skip Microsoft account)
   - Name: `Administrator`
   - Skip all privacy options for faster setup

### Step 2.4: Install VirtIO Drivers

After first boot, install remaining drivers:

```powershell
# Open Device Manager (devmgmt.msc)
# For each "Unknown device", right-click → Update driver → Browse → VirtIO CD

# Required drivers:
# - Network: E:\NetKVM\w11\amd64
# - Balloon: E:\Balloon\w11\amd64
# - Serial: E:\vioserial\w11\amd64
# - Display (optional): E:\qxldod\w11\amd64
```

### Step 2.5: Install QEMU Guest Agent (CRITICAL!)

```cmd
# From VirtIO CD, run as Administrator:
E:\guest-agent\qemu-ga-x86_64.msi

# Verify installation
sc query qemu-ga

# Should show: STATE = RUNNING
```

**Why QEMU Guest Agent is Critical:**
- Enables graceful shutdown/restart from OpenShift
- Required for Live Migration
- Allows virtctl commands to work
- Provides VM lifecycle management

### Step 2.6: Install CloudBase-Init

```powershell
# Download CloudBase-Init
Invoke-WebRequest -Uri "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi" `
    -OutFile "C:\cloudbase-init.msi"

# Install silently
msiexec /i C:\cloudbase-init.msi /qn /l*v C:\cloudbase-init-install.log

# DO NOT run sysprep when prompted - we'll do this manually
```

Configure CloudBase-Init:
```powershell
# Edit config file
notepad "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"

# Ensure these settings:
# username=Administrator
# inject_user_password=true
# config_drive_raw_hhd=true
# config_drive_cdrom=true
```

### Step 2.7: Install Benchmark Runner Prerequisites

```powershell
# Install Python 3.11+
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" `
    -OutFile "C:\python-installer.exe"
Start-Process "C:\python-installer.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait

# Install Git (if needed)
# Install benchmark frameworks
# Install monitoring agents
# etc.
```

### Step 2.8: Apply Windows Updates

```powershell
# Open Settings → Windows Update
# Click "Check for updates"
# Install all updates and restart as needed
# Repeat until no more updates
```

### Step 2.9: Prepare for Sysprep

```powershell
# Optional: Clear event logs
wevtutil el | ForEach-Object {wevtutil cl $_}

# Optional: Defragment (if using non-SSD storage)
Optimize-Volume -DriveLetter C -Defrag -Verbose

# Optional: Run DISM cleanup
Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase
```

### Step 2.10: Run Sysprep

```cmd
# Open Command Prompt as Administrator
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

**What Sysprep Does:**
- Removes Machine SID (Security Identifier)
- Clears hardware-specific configurations
- Resets Windows activation state
- Prepares image for cloning

**⏱️ Wait Time:** 5-15 minutes, then VM shuts down automatically

---

## Phase 3: Export and Upload to S3

### Step 3.1: Verify VM is Stopped

```bash
# Check VM status
oc get vm windows11-golden-builder -n windows-image-builder

# Should show: RUNNING = False
```

### Step 3.2: Create VirtualMachineExport

```bash
# Deploy export resource
oc apply -f manifests/03-vmexport-to-s3.yaml

# Monitor export progress
oc get vmexport windows11-golden-export -n windows-image-builder -w

# Wait for: PHASE = Ready
# This takes 5-10 minutes depending on disk size
```

### Step 3.3: Download qcow2 Image

```bash
# Download exported image
virtctl vmexport download windows11-golden-export \
    --namespace=windows-image-builder \
    --output=windows11-golden-v1.0.0.qcow2 \
    --volume=windows11-golden-disk \
    --insecure

# This downloads the PVC as a compressed qcow2 file
# Size: ~15-25GB (compressed from 60GB)
```

### Step 3.4: Calculate Checksum

```bash
# Calculate SHA256
sha256sum windows11-golden-v1.0.0.qcow2 > windows11-golden-v1.0.0.qcow2.sha256

# Save checksum
CHECKSUM=$(cat windows11-golden-v1.0.0.qcow2.sha256 | cut -d' ' -f1)
echo "SHA256: ${CHECKSUM}"
```

### Step 3.5: Upload to S3

```bash
# Set variables
export S3_BUCKET="your-enterprise-bucket"
export S3_PREFIX="golden-images/windows11"
export IMAGE_VERSION="v1.0.0"

# Upload image
aws s3 cp windows11-golden-v1.0.0.qcow2 \
    s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2 \
    --profile your-enterprise-profile

# Upload checksum
aws s3 cp windows11-golden-v1.0.0.qcow2.sha256 \
    s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2.sha256 \
    --profile your-enterprise-profile

# Verify upload
aws s3 ls s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/ \
    --profile your-enterprise-profile
```

### Step 3.6: Create Metadata File

```bash
cat > windows11-golden-metadata.json <<EOF
{
  "image_name": "windows11-golden",
  "version": "${IMAGE_VERSION}",
  "os_version": "Windows 11 23H2",
  "s3_bucket": "${S3_BUCKET}",
  "s3_key": "${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2",
  "s3_url": "s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2",
  "http_url": "https://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2",
  "sha256": "${CHECKSUM}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ}",
  "disk_size": "60Gi",
  "compressed_size": "$(du -h windows11-golden-v1.0.0.qcow2 | cut -f1)",
  "features": [
    "VirtIO drivers installed",
    "QEMU Guest Agent enabled",
    "CloudBase-Init configured",
    "Windows Update applied",
    "Generalized with sysprep"
  ]
}
EOF

# Upload metadata
aws s3 cp windows11-golden-metadata.json \
    s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/metadata.json \
    --profile your-enterprise-profile
```

### Step 3.7: Cleanup Export Resources

```bash
# Delete export (frees up resources)
oc delete vmexport windows11-golden-export -n windows-image-builder

# Optional: Keep VM for future updates or delete it
oc delete vm windows11-golden-builder -n windows-image-builder
```

---

## Phase 4: Deploy as DataSource

### Step 4.1: Update DataSource Manifest

```bash
# Update S3 URL in manifest
HTTP_URL="https://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}/${IMAGE_VERSION}/windows11-golden.qcow2"

sed -i "s|https://your-bucket.s3.amazonaws.com/golden-images/windows11/v1.0.0/windows11-golden.qcow2|${HTTP_URL}|g" \
    manifests/04-datasource-from-s3.yaml

# Update checksum
sed -i "s|sha256:REPLACE_WITH_ACTUAL_SHA256|sha256:${CHECKSUM}|g" \
    manifests/04-datasource-from-s3.yaml
```

### Step 4.2: Deploy DataSource

```bash
# Apply all resources
oc apply -f manifests/04-datasource-from-s3.yaml

# This creates:
# 1. PVC that imports from S3
# 2. DataSource pointing to the PVC
# 3. VirtualMachineClusterInstancetype (windows.large)
# 4. VirtualMachineClusterPreference (windows.11)
```

### Step 4.3: Monitor CDI Import

```bash
# Watch import progress
oc get pvc windows11-golden-import-pvc -n openshift-virtualization-os-images -w

# Check DataVolume status (created automatically by CDI)
oc get datavolume -n openshift-virtualization-os-images

# Watch CDI importer pod
oc get pods -n openshift-virtualization-os-images | grep importer
oc logs -f <importer-pod> -n openshift-virtualization-os-images
```

Import phases:
1. `ImportScheduled`: CDI scheduled the import
2. `ImportInProgress`: Downloading from S3
3. `Succeeded`: Import complete

**⏱️ Import Time:** 15-30 minutes depending on image size and network speed

### Step 4.4: Verify DataSource

```bash
# Check DataSource is ready
oc get datasource windows11-golden -n openshift-virtualization-os-images

# Verify instance type and preference
oc get virtualmachineclusterinstancetype windows.large
oc get virtualmachineclusterpreference windows.11

# Test: Create a VM from the DataSource
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows11-test
  namespace: default
spec:
  running: false
  dataVolumeTemplates:
  - metadata:
      name: windows11-test-disk
    spec:
      pvc:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 60Gi
        storageClassName: gp3-csi
        volumeMode: Block
      source:
        pvc:
          name: windows11-golden-import-pvc
          namespace: openshift-virtualization-os-images
  template:
    spec:
      domain:
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
      volumes:
      - name: rootdisk
        dataVolume:
          name: windows11-test-disk
EOF

# Start test VM
oc patch vm windows11-test -p '{"spec":{"running":true}}'

# Verify it boots
oc get vmi windows11-test
virtctl console windows11-test

# Cleanup test VM
oc delete vm windows11-test
```

---

## Phase 5: Use in CI Jobs

### Step 5.1: Update CI Configuration

Your CI config is already updated in:
```
ci-operator/config/redhat-chaos/lp-chaos/redhat-chaos-lp-chaos-main__ocp4.21-nightly--cnv-4.21-stable-windows-vm-chaos--aws.yaml
```

Key environment variables:
```yaml
LPC_LP_CNV__VM__DV_SOURCE_NAME: windows11-golden
LPC_LP_CNV__VM__DV_SOURCE_NS: openshift-virtualization-os-images
LPC_LP_CNV__VM__PREFERENCE: windows.11
LPC_LP_CNV__VM__INSTANCE_TYPE: windows.large
```

### Step 5.2: Test in CI

```bash
# Trigger the job manually
# In your PR, comment:
/test ocp4.21-nightly--cnv-4.21-stable-windows-vm-chaos--aws-windows-vm-chaos

# Monitor job execution in Prow dashboard
# https://prow.ci.openshift.org/
```

### Step 5.3: Verify VMs are Created from Golden Image

When the CI job runs, it will:
1. Clone the Windows golden image PVC
2. Create Windows VMs in `benchmark-runner` namespace
3. Initialize VMs (check Guest Agent, get IPs)
4. Run kubevirt-outage chaos tests

---

## Verification

### Verify Golden Image Components

```bash
# 1. Check S3 upload
aws s3 ls s3://${S3_BUCKET}/${S3_PREFIX}/${IMAGE_VERSION}/ --profile your-profile

# Expected files:
# - windows11-golden.qcow2
# - windows11-golden.qcow2.sha256
# - metadata.json

# 2. Check DataSource
oc get datasource windows11-golden -n openshift-virtualization-os-images -o yaml

# 3. Check import PVC
oc get pvc windows11-golden-import-pvc -n openshift-virtualization-os-images

# 4. Check instance types
oc get virtualmachineclusterinstancetype windows.large -o yaml
oc get virtualmachineclusterpreference windows.11 -o yaml

# 5. Test VM creation
oc get vm -n benchmark-runner
```

### Verify VM Functionality

Create a test VM and verify:
```bash
# Use the existing VM creation step
oc apply -f - <<EOF
# ... VM definition using windows11-golden DataSource ...
EOF

# Check VM boots
virtctl console <vm-name>

# Verify features:
# - Network connectivity
# - Guest agent running (virtctl guestosinfo <vm-name>)
# - CloudBase-Init completed (check C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\)
# - Unique machine SID (sysprep worked)
```

---

## Troubleshooting

### Issue: VirtIO Drivers Not Found During Installation

**Symptoms:** No disk visible during Windows installation

**Solution:**
```bash
# 1. Check VirtIO container disk is mounted
oc get vmi windows11-golden-builder -n windows-image-builder -o yaml | grep -A5 virtio-drivers

# 2. Verify VirtIO image is accessible
podman pull registry.redhat.io/container-native-virtualization/virtio-win:latest

# 3. In Windows installer:
# - Ensure you're browsing to correct CD drive (try D:, E:, F:)
# - Path must be: viostor\w11\amd64 (not just viostor)
```

### Issue: CDI Import Fails

**Symptoms:** PVC stuck in `ImportInProgress` or fails with error

**Solution:**
```bash
# 1. Check importer pod logs
oc get pods -n openshift-virtualization-os-images | grep importer
oc logs <importer-pod> -n openshift-virtualization-os-images

# Common errors:

# - "403 Forbidden": S3 credentials incorrect
oc get secret s3-credentials -n openshift-virtualization-os-images -o yaml
# Recreate with correct credentials

# - "Checksum mismatch": SHA256 incorrect
# Recalculate and update manifest

# - "Connection timeout": S3 URL not accessible
# Test from within cluster:
oc run test-curl --rm -it --image=curlimages/curl -- \
    curl -I "https://your-bucket.s3.amazonaws.com/path/to/image.qcow2"

# 2. Check CDI controller logs
oc logs -n openshift-cnv $(oc get pods -n openshift-cnv -l name=cdi-deployment -o name)
```

### Issue: QEMU Guest Agent Not Running

**Symptoms:** Cannot use `virtctl guestosinfo`, Live Migration fails

**Solution:**
```bash
# 1. Check guest agent status in Windows
# Services.msc → QEMU Guest Agent → Status

# 2. If not running, reinstall:
# From VirtIO CD: guest-agent\qemu-ga-x86_64.msi

# 3. Check VM has correct serial device
oc get vmi <vm-name> -o yaml | grep -A10 "channels:"
# Should have org.qemu.guest_agent.0 channel

# 4. Verify from OpenShift
oc get vmi <vm-name> -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'
# Should return: True
```

### Issue: VM Won't Boot After Clone

**Symptoms:** VM created from DataSource fails to boot

**Solution:**
```bash
# 1. Check boot order in VM spec
oc get vm <vm-name> -o yaml | grep -A5 bootOrder

# 2. Verify disk is attached
oc get vmi <vm-name> -o yaml | grep -A20 "volumes:"

# 3. Check virt-launcher pod logs
oc logs <virt-launcher-pod> -n <namespace>

# 4. Ensure using Block mode
oc get pvc <pvc-name> -o jsonpath='{.spec.volumeMode}'
# Should return: Block
```

### Issue: Sysprep Fails or Hangs

**Symptoms:** Sysprep never completes or errors

**Solution:**
```powershell
# 1. Check sysprep logs
notepad C:\Windows\System32\Sysprep\Panther\setupact.log

# 2. Common issues:
# - Modern apps not removed (run before sysprep):
Get-AppxPackage -AllUsers | Remove-AppxPackage

# - Windows activation issues:
# Ensure not activated with enterprise key

# 3. Clear and retry:
rd /s /q C:\Windows\System32\Sysprep\Panther
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

### Issue: High Storage Usage

**Symptoms:** qcow2 file larger than expected

**Solution:**
```bash
# 1. Compact image before export
# Inside Windows before sysprep:
Optimize-Volume -DriveLetter C -ReTrim

# 2. Use sparse cloning
# DataVolume clones are automatically sparse

# 3. Cleanup Windows temp files before sysprep
Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase
```

---

## Next Steps

1. **Update Versioning**
   - Tag git commit with image version
   - Update CI configs to reference correct DataSource

2. **Create Additional Variants**
   - Windows Server 2022
   - Windows with specific benchmark tools pre-installed

3. **Automate Updates**
   - Monthly Windows Update cycle
   - Automated image rebuild pipeline

4. **Documentation**
   - Document benchmark runner integration
   - Create runbooks for common tasks

---

## Summary Checklist

✅ Phase 1: Initial Setup
- [ ] OpenShift Virtualization installed
- [ ] Windows 11 ISO prepared (container or S3)
- [ ] S3 credentials created
- [ ] Manifests updated with your values

✅ Phase 2: Create Golden Image
- [ ] VM deployed and accessible
- [ ] Windows 11 installed with VirtIO storage driver
- [ ] All VirtIO drivers installed
- [ ] QEMU Guest Agent installed and running
- [ ] CloudBase-Init installed and configured
- [ ] Benchmark prerequisites installed
- [ ] Windows updates applied
- [ ] Sysprep completed successfully

✅ Phase 3: Export and Upload
- [ ] VM stopped after sysprep
- [ ] VirtualMachineExport created
- [ ] qcow2 downloaded
- [ ] SHA256 calculated
- [ ] Image uploaded to S3
- [ ] Metadata created

✅ Phase 4: Deploy as DataSource
- [ ] DataSource manifest updated
- [ ] Resources deployed
- [ ] CDI import completed
- [ ] DataSource verified
- [ ] Test VM created and boots

✅ Phase 5: CI Integration
- [ ] CI config updated
- [ ] Test job triggered
- [ ] VMs created from golden image
- [ ] Chaos tests executed

---

## Support

For issues or questions:
- OpenShift Virtualization: https://docs.openshift.com/container-platform/latest/virt/
- KubeVirt: https://kubevirt.io/
- This repo issues: https://github.com/openshift/release/issues
