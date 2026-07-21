#!/bin/bash
#
# Export generalized Windows VM to qcow2 and upload to S3
#

set -euo pipefail

# Load VM information from previous step
if [[ ! -f "${SHARED_DIR}/windows-golden-vm-info.json" ]]; then
    echo "ERROR: VM info file not found. Run create step first."
    exit 1
fi

vm_name=$(jq -r '.vm_name' "${SHARED_DIR}/windows-golden-vm-info.json")
namespace=$(jq -r '.namespace' "${SHARED_DIR}/windows-golden-vm-info.json")
version=$(jq -r '.version' "${SHARED_DIR}/windows-golden-vm-info.json")
s3_bucket=$(jq -r '.s3_bucket' "${SHARED_DIR}/windows-golden-vm-info.json")
s3_prefix=$(jq -r '.s3_prefix' "${SHARED_DIR}/windows-golden-vm-info.json")

export_name="${vm_name}-export"
output_file="windows11-golden-${version}.qcow2"

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="/var/run/secrets/aws/credentials"
export AWS_CONFIG_FILE="/var/run/secrets/aws/config"

echo "=== Windows VM Export to S3 ==="
echo "VM: ${vm_name}"
echo "Namespace: ${namespace}"
echo "Export: ${export_name}"
echo "Output: ${output_file}"
echo "==============================="

# Wait for VM to be stopped (after sysprep)
echo "Waiting for VM to stop (sysprep shutdown)..."
timeout="${WIN_GOLDEN_EXPORT_TIMEOUT}"
while [[ $(oc get vm "${vm_name}" -n "${namespace}" -o jsonpath='{.spec.running}') == "true" ]]; do
    echo "VM still running... waiting for sysprep to complete"
    sleep 30
done

echo "VM stopped successfully"

# Ensure VM is not running
oc patch vm "${vm_name}" -n "${namespace}" --type merge -p '{"spec":{"running":false}}'

# Create VirtualMachineExport
cat <<EOF | oc apply -f -
apiVersion: export.kubevirt.io/v1alpha1
kind: VirtualMachineExport
metadata:
  name: ${export_name}
  namespace: ${namespace}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${vm_name}
  ttlDuration: 2h
EOF

echo "Waiting for export to be ready..."
oc wait vmexport "${export_name}" -n "${namespace}" \
    --for=condition=Ready \
    --timeout="${WIN_GOLDEN_EXPORT_TIMEOUT}"

echo "Export ready. Downloading qcow2 image..."

# Download using virtctl
virtctl vmexport download "${export_name}" \
    --namespace="${namespace}" \
    --output="${output_file}" \
    --volume=windows11-golden-disk \
    --insecure

echo "Download complete"

# Calculate checksum
sha256sum=$(sha256sum "${output_file}" | cut -d' ' -f1)
echo "SHA256: ${sha256sum}"

# Upload to S3
s3_path="s3://${s3_bucket}/${s3_prefix}/${output_file}"
echo "Uploading to: ${s3_path}"

aws s3 cp "${output_file}" "${s3_path}"

echo "Upload successful"

# Create metadata
cat > "${SHARED_DIR}/windows-golden-metadata.json" <<EOF
{
  "image_name": "windows11-golden",
  "version": "${version}",
  "s3_bucket": "${s3_bucket}",
  "s3_key": "${s3_prefix}/${output_file}",
  "s3_url": "${s3_path}",
  "http_url": "https://${s3_bucket}.s3.amazonaws.com/${s3_prefix}/${output_file}",
  "sha256": "${sha256sum}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_vm": "${vm_name}",
  "namespace": "${namespace}"
}
EOF

echo "Metadata saved"
cat "${SHARED_DIR}/windows-golden-metadata.json"

# Cleanup export
oc delete vmexport "${export_name}" -n "${namespace}"

echo "Export complete!"

true
