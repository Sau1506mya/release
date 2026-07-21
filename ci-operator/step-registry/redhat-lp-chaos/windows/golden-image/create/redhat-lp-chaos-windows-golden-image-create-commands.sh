#!/bin/bash
#
# Cloud-Native Windows 11 Golden Image Creation - CI Orchestrator
#
# This script automates the deployment of a Windows VM using OpenShift Virtualization,
# monitors for sysprep completion, exports to qcow2, and uploads to S3.
#

set -euo pipefail

# Validate required parameters
if [[ -z "${WIN_GOLDEN_S3_BUCKET}" ]]; then
    echo "ERROR: WIN_GOLDEN_S3_BUCKET is required"
    exit 1
fi

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="/var/run/secrets/aws/credentials"
export AWS_CONFIG_FILE="/var/run/secrets/aws/config"

echo "=== Windows 11 Golden Image Creation Pipeline ==="
echo "Version: ${WIN_GOLDEN_IMAGE_VERSION}"
echo "Namespace: ${WIN_GOLDEN_IMAGE_NS}"
echo "VM Name: ${WIN_GOLDEN_VM_NAME}"
echo "S3 Bucket: ${WIN_GOLDEN_S3_BUCKET}"
echo "S3 Prefix: ${WIN_GOLDEN_S3_PREFIX}"
echo "=============================================="

# Create namespace
oc create namespace "${WIN_GOLDEN_IMAGE_NS}" --dry-run=client -o yaml | oc apply -f -
oc wait "Namespace/${WIN_GOLDEN_IMAGE_NS}" --for=create --timeout=60s > /dev/null

# Generate VirtualMachine manifest
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${WIN_GOLDEN_VM_NAME}
  namespace: ${WIN_GOLDEN_IMAGE_NS}
  labels:
    app: windows-image-builder
    purpose: golden-image
spec:
  running: true
  dataVolumeTemplates:
  - metadata:
      name: windows11-golden-disk
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
        blank: {}
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${WIN_GOLDEN_VM_NAME}
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
        memory:
          guest: 8Gi
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
            bootOrder: 1
          - name: windows-installer
            cdrom:
              bus: sata
            bootOrder: 2
          - name: virtio-drivers
            cdrom:
              bus: sata
            bootOrder: 3
          interfaces:
          - name: default
            masquerade: {}
            model: virtio
          tpm:
            persistent: true
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            spinlocks:
              spinlocks: 8191
            vapic: {}
            vpindex: {}
            frequencies: {}
            reenlightenment: {}
            tlbflush: {}
            ipi: {}
            runtime: {}
            synic: {}
            synictimer:
              direct: {}
            reset: {}
          smm:
            enabled: true
        firmware:
          bootloader:
            efi:
              secureBoot: false
        resources:
          requests:
            memory: 8Gi
            cpu: 4
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: windows11-golden-disk
      - name: windows-installer
        containerDisk:
          image: ${WIN_ISO_SOURCE}
      - name: virtio-drivers
        containerDisk:
          image: ${VIRTIO_WIN_IMAGE}
EOF

echo "Waiting for VM to be ready..."
oc wait vm "${WIN_GOLDEN_VM_NAME}" -n "${WIN_GOLDEN_IMAGE_NS}" --for=condition=Ready --timeout=10m

echo ""
echo "=========================================="
echo "VM deployed successfully!"
echo "=========================================="
echo ""
echo "MANUAL STEPS REQUIRED:"
echo "1. Access the VM console:"
echo "   virtctl vnc ${WIN_GOLDEN_VM_NAME} -n ${WIN_GOLDEN_IMAGE_NS}"
echo ""
echo "2. Install Windows 11:"
echo "   - Load VirtIO storage driver: viostor\\w11\\amd64"
echo "   - Complete Windows installation"
echo "   - Install all VirtIO drivers from Device Manager"
echo "   - Install QEMU Guest Agent (critical!)"
echo "   - Install CloudBase-Init"
echo "   - Apply Windows updates"
echo ""
echo "3. Run sysprep to generalize:"
echo "   C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown"
echo ""
echo "4. After VM shuts down, the pipeline will automatically:"
echo "   - Export the VM to qcow2 format"
echo "   - Upload to S3"
echo "   - Create DataSource"
echo ""
echo "=========================================="

# Save VM details for subsequent steps
cat > "${SHARED_DIR}/windows-golden-vm-info.json" <<EOF
{
  "vm_name": "${WIN_GOLDEN_VM_NAME}",
  "namespace": "${WIN_GOLDEN_IMAGE_NS}",
  "version": "${WIN_GOLDEN_IMAGE_VERSION}",
  "s3_bucket": "${WIN_GOLDEN_S3_BUCKET}",
  "s3_prefix": "${WIN_GOLDEN_S3_PREFIX}"
}
EOF

echo "VM information saved to: ${SHARED_DIR}/windows-golden-vm-info.json"

# NOTE: For CI automation, this step creates the VM and pauses.
# The export and upload would be handled by subsequent steps after manual installation.
# For fully automated workflows, consider using answer files (autounattend.xml)

echo "Pipeline initialized successfully. VM is ready for Windows installation."

true
