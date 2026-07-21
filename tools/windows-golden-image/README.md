# Cloud-Native Windows 11 Golden Image Creation

This directory contains **OpenShift Virtualization native** manifests and scripts for creating generalized Windows 11 golden images using Kubernetes APIs.

## Architecture Overview

This solution follows cloud-native principles using KubeVirt/OpenShift Virtualization APIs:

1. **Host Infrastructure & Storage Provisioning**: Unified `VirtualMachine` declarative resource with `volumeMode: Block` for high-performance storage
2. **VirtIO Driver Injection**: Secondary optical drive mapping `registry.redhat.io/container-native-virtualization/virtio-win` container disk
3. **Guest OS Initialization**: Install Windows, VirtIO drivers, QEMU Guest Agent, and CloudBase-Init
4. **Generalization (Sysprep)**: Execute `sysprep.exe /oobe /generalize /shutdown` to scrub Machine SIDs
5. **Cloud-Native Artifact Export**: Use `VirtualMachineExport` API to stream-convert PVC to compressed qcow2
6. **S3 Storage**: Push artifact to enterprise S3 for Python Benchmark Runner framework

## Quick Start

### Option 1: Using Scripts (Recommended)

```bash
cd tools/windows-golden-image/scripts

# Deploy VM and start installation
./create-golden-image.sh deploy

# Complete Windows installation via VNC (see instructions)
# After sysprep shutdown:
S3_BUCKET=your-bucket ./create-golden-image.sh export-and-upload

# Create cluster-wide DataSource
./create-golden-image.sh create-datasource
```

### Option 2: Using Manifests Directly

```bash
cd tools/windows-golden-image/manifests

# 1. Deploy Windows VM
oc create namespace windows-image-builder
oc apply -f 01-windows11-scratch-vm.yaml

# 2. Access VM and complete installation
virtctl vnc windows11-golden-builder -n windows-image-builder

# 3. After sysprep, export to qcow2
oc apply -f 03-vmexport-to-s3.yaml
virtctl vmexport download windows11-golden-export --output=windows11-golden.qcow2

# 4. Upload to S3 and create DataSource
aws s3 cp windows11-golden.qcow2 s3://your-bucket/golden-images/windows11/
oc apply -f 04-datasource-from-s3.yaml
```

## Prerequisites

### OpenShift Cluster
- OpenShift 4.18+ with OpenShift Virtualization operator installed
- Storage class supporting `volumeMode: Block` (e.g., `gp3-csi`, `ocs-storagecluster-ceph-rbd`)
- Sufficient worker node resources (16GB RAM, 4 vCPUs per VM)

### Client Tools
```bash
# Install virtctl
sudo dnf install kubevirt-virtctl

# Install oc CLI
# Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/

# Install AWS CLI (for S3 operations)
pip install awscli
aws configure
```

### Windows Resources
- **Windows 11 ISO**: Container image or HTTP/S3 accessible URL
- **VirtIO Drivers**: `registry.redhat.io/container-native-virtualization/virtio-win:latest`

## Manifests

### 01-windows11-scratch-vm.yaml
VirtualMachine with blank `volumeMode: Block` disk and VirtIO driver injection:
- **Storage**: 60Gi block device (bypasses filesystem overhead)
- **VirtIO-Win**: Injects viostor (storage) and NetKVM (network) drivers
- **TPM**: Required for Windows 11
- **Hyper-V Enlightenments**: Performance optimizations

### 02-windows11-template-clone-vm.yaml
Fast-track template cloning from existing Windows baseline PVC/snapshot.

### 03-vmexport-to-s3.yaml
VirtualMachineExport API resource for extracting qcow2 from PVC.

### 04-datasource-from-s3.yaml
Complete DataSource setup with:
- PVC import from S3
- DataSource for cluster-wide availability
- VirtualMachineClusterInstancetype (resource templates)
- VirtualMachineClusterPreference (OS optimizations)

### s3-credentials-secret.yaml
S3 authentication for CDI (Containerized Data Importer) image imports.

## Installation Workflow

### Phase 1: Deploy VM

```bash
oc create namespace windows-image-builder
oc apply -f manifests/01-windows11-scratch-vm.yaml
```

The VM starts with:
- Blank 60Gi block device
- Windows 11 ISO mounted
- VirtIO drivers container disk mounted

### Phase 2: Windows Installation (Manual)

Access the VM console:
```bash
virtctl vnc windows11-golden-builder -n windows-image-builder
```

**Critical Steps:**

1. **Load VirtIO Storage Driver**
   - At disk selection screen: "Load driver"
   - Browse to VirtIO CD → `viostor\w11\amd64`
   - Install Red Hat VirtIO SCSI controller
   - Now the blank disk becomes visible

2. **Complete Windows Installation**
   - Select the disk and install Windows
   - Configure OOBE (region, keyboard, local account)

3. **Install VirtIO Drivers** (Device Manager)
   - Network: `NetKVM\w11\amd64`
   - Balloon: `Balloon\w11\amd64`
   - Serial: `vioserial\w11\amd64`
   - Display: `qxldod\w11\amd64`

4. **Install QEMU Guest Agent** (CRITICAL!)
   ```cmd
   # From VirtIO CD
   D:\guest-agent\qemu-ga-x86_64.msi
   ```
   Enables OpenShift lifecycle control and Live Migration.

5. **Install CloudBase-Init**
   ```powershell
   Invoke-WebRequest -Uri https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi -OutFile cloudbase-init.msi
   msiexec /i cloudbase-init.msi /qn
   ```

6. **Apply Windows Updates**
   ```
   Settings → Windows Update → Check for updates
   ```

7. **Install Benchmark Runner Prerequisites**
   - Python 3.11+
   - Required benchmark frameworks

### Phase 3: Sysprep Generalization

When ready to generalize:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

This:
- Removes Machine Security Identifiers (SIDs)
- Clears hardware-specific configurations
- Shuts down VM cleanly

**The VM will stop automatically** - this signals completion to OpenShift.

### Phase 4: Export to qcow2

```bash
# Create export
oc apply -f manifests/03-vmexport-to-s3.yaml

# Wait for export to be ready
oc wait vmexport windows11-golden-export -n windows-image-builder --for=condition=Ready --timeout=30m

# Download qcow2
virtctl vmexport download windows11-golden-export \
    --namespace=windows-image-builder \
    --output=windows11-golden-v1.0.0.qcow2 \
    --volume=windows11-golden-disk \
    --insecure
```

### Phase 5: Upload to S3

```bash
# Calculate checksum
sha256sum windows11-golden-v1.0.0.qcow2

# Upload to S3
aws s3 cp windows11-golden-v1.0.0.qcow2 \
    s3://your-bucket/golden-images/windows11/v1.0.0/windows11-golden.qcow2

# Update manifests/04-datasource-from-s3.yaml with:
# - S3 URL
# - SHA256 checksum
```

### Phase 6: Create DataSource

```bash
# Create S3 credentials secret
oc create secret generic s3-credentials \
    -n openshift-virtualization-os-images \
    --from-literal=accessKeyId=YOUR_ACCESS_KEY \
    --from-literal=secretKey=YOUR_SECRET_KEY

# Deploy DataSource
oc apply -f manifests/04-datasource-from-s3.yaml

# Wait for CDI import
oc wait pvc windows11-golden-import-pvc \
    -n openshift-virtualization-os-images \
    --for=jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/storage\.pod\.phase}'=Succeeded \
    --timeout=30m
```

## CI Integration

### Step-Registry Components

```yaml
# ci-operator/config/your-org/your-repo/config.yaml
tests:
- as: create-windows-golden-image
  steps:
    cluster_profile: aws-lp-chaos
    env:
      WIN_GOLDEN_S3_BUCKET: your-enterprise-bucket
      WIN_GOLDEN_IMAGE_VERSION: v1.0.0
      WIN_ISO_SOURCE: quay.io/your-org/windows11-iso:23H2
    test:
    - ref: redhat-lp-chaos-windows-golden-image-create
    - ref: redhat-lp-chaos-windows-golden-image-export
    workflow: ipi-aws-ovn
```

### Using the Golden Image

Update your existing CI config:

```yaml
# Update ci-operator/config/redhat-chaos/lp-chaos/...yaml
env:
  LPC_LP_CNV__VM__DV_SOURCE_NAME: windows11-golden
  LPC_LP_CNV__VM__DV_SOURCE_NS: openshift-virtualization-os-images
  LPC_LP_CNV__VM__PREFERENCE: windows.11
  LPC_LP_CNV__VM__INSTANCE_TYPE: windows.large  # Use Windows-optimized instance type
```

## Key Differences from Legacy Hypervisor Approach

| Legacy (virt-install) | Cloud-Native (KubeVirt) |
|-----------------------|-------------------------|
| Manual KVM host setup | Declarative Kubernetes manifests |
| Local qcow2 file | PVC with `volumeMode: Block` |
| Manual driver ISOs | Container disk injection |
| `qemu-img convert` | `VirtualMachineExport` API |
| SSH/rsync for transfer | S3 object storage |
| One-time artifact | Cluster-wide DataSource template |

## Troubleshooting

### VirtIO Drivers Not Found
**Symptom**: Disk not visible during Windows installation

**Solution**: 
```bash
# Verify virtio-win container disk is mounted
oc get vmi windows11-golden-builder -n windows-image-builder -o yaml | grep virtio

# Check CDROMs visible to VM
virtctl console windows11-golden-builder -n windows-image-builder
# In Windows: Check disk management for CD drives
```

### QEMU Guest Agent Not Running
**Symptom**: Cannot perform Live Migration

**Solution**:
```bash
# Check guest agent connection
oc get vmi windows11-golden-builder -n windows-image-builder \
    -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'

# Inside Windows: Services.msc → QEMU Guest Agent → Status
```

### Export Timeout
**Symptom**: VirtualMachineExport stuck in Pending

**Solution**:
```bash
# Check export pod logs
oc get pods -n windows-image-builder | grep export
oc logs <export-pod> -n windows-image-builder

# Common issues:
# - VM still running (must be stopped)
# - Insufficient storage for export operation
# - Network policy blocking export service
```

### CDI Import Fails
**Symptom**: DataVolume stuck in ImportInProgress

**Solution**:
```bash
# Check CDI importer pod
oc get pods -n openshift-virtualization-os-images | grep importer
oc logs <importer-pod> -n openshift-virtualization-os-images

# Common issues:
# - S3 credentials incorrect
# - S3 URL not accessible
# - Checksum mismatch
# - Insufficient storage
```

## Performance Optimization

### Storage
- Use `volumeMode: Block` (bypasses filesystem overhead)
- Use high-performance storage class (gp3, io2, ocs-rbd)
- Consider dedicated storage nodes for image building

### VM Resources
```yaml
# Increase for faster installation
cpu:
  cores: 8  # Instead of 4
memory:
  guest: 16Gi  # Instead of 8Gi
```

### Network
```yaml
# Use bridge networking for higher throughput (if available)
interfaces:
- name: default
  bridge: {}
```

## Security Considerations

### Image Hardening
Before sysprep:
- Apply Windows Security Baselines
- Disable unnecessary services
- Configure Windows Defender
- Remove default accounts
- Clear event logs

### Secrets Management
```bash
# Never include passwords in the image
# Use CloudBase-Init for runtime injection

# Rotate S3 credentials regularly
oc delete secret s3-credentials -n openshift-virtualization-os-images
oc create secret generic s3-credentials --from-literal=...
```

### RBAC
```yaml
# Limit access to image builder namespace
kind: RoleBinding
metadata:
  name: image-builder-admin
  namespace: windows-image-builder
roleRef:
  kind: ClusterRole
  name: admin
subjects:
- kind: ServiceAccount
  name: ci-operator
  namespace: ci
```

## Advanced: Automated Installation

For fully automated workflows, create an `autounattend.xml` answer file:

```xml
<!-- autounattend.xml -->
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>60000</Size>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                </Disk>
            </DiskConfiguration>
        </component>
    </settings>
</unattend>
```

Inject via ConfigMap and cloudInitNoCloud volume.

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [KubeVirt User Guide](https://kubevirt.io/user-guide/)
- [VirtualMachineExport API](https://kubevirt.io/api-reference/main/definitions.html#_v1alpha1_virtualmachineexport)
- [CDI Documentation](https://github.com/kubevirt/containerized-data-importer)
- [CloudBase-Init](https://cloudbase-init.readthedocs.io/)
- [VirtIO Drivers](https://github.com/virtio-win/kvm-guest-drivers-windows)
