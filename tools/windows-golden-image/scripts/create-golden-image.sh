#!/bin/bash
#
# Cloud-Native Windows 11 Golden Image Creation Orchestrator
#
# This script orchestrates the complete workflow using OpenShift Virtualization APIs:
# 1. Deploy VirtualMachine with block storage and VirtIO driver injection
# 2. Monitor installation progress
# 3. Trigger sysprep generalization
# 4. Export to qcow2 using VirtualMachineExport
# 5. Upload to S3
# 6. Create DataSource for cluster-wide availability
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
readonly NAMESPACE="${NAMESPACE:-windows-image-builder}"
readonly VM_NAME="${VM_NAME:-windows11-golden-builder}"
readonly EXPORT_NAME="${EXPORT_NAME:-windows11-golden-export}"
readonly IMAGE_VERSION="${IMAGE_VERSION:-v1.0.0}"
readonly S3_BUCKET="${S3_BUCKET:-}"
readonly S3_PREFIX="${S3_PREFIX:-golden-images/windows11}"
readonly AWS_PROFILE="${AWS_PROFILE:-default}"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

function log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
function log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
function log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

function check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v oc &>/dev/null; then
        log_error "oc CLI not found"
        exit 1
    fi

    if ! command -v virtctl &>/dev/null; then
        log_error "virtctl not found. Install: sudo dnf install kubevirt-virtctl"
        exit 1
    fi

    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

function create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."

    if oc get namespace "${NAMESPACE}" &>/dev/null; then
        log_warn "Namespace ${NAMESPACE} already exists"
    else
        oc create namespace "${NAMESPACE}"
    fi
}

function deploy_vm() {
    log_info "Deploying Windows 11 VM from scratch..."

    oc apply -f "${MANIFESTS_DIR}/01-windows11-scratch-vm.yaml"

    log_info "Starting VM..."
    oc patch vm "${VM_NAME}" -n "${NAMESPACE}" --type merge -p '{"spec":{"running":true}}'

    log_info "Waiting for VM to be ready..."
    oc wait vm "${VM_NAME}" -n "${NAMESPACE}" --for=condition=Ready --timeout=5m

    log_info "VM deployed successfully"
    log_info "Access via VNC: virtctl vnc ${VM_NAME} -n ${NAMESPACE}"
    log_info "Or web console: virtctl vnc --proxy-only=false ${VM_NAME} -n ${NAMESPACE}"
}

function show_installation_guide() {
    cat <<'EOF'

================================================================================
              WINDOWS 11 INSTALLATION GUIDE (OpenShift Native)
================================================================================

Your Windows 11 VM is now running. Complete the following steps:

1. CONNECT TO VM
   Run: virtctl vnc windows11-golden-builder -n windows-image-builder

2. INSTALL WINDOWS 11
   - Boot from Windows ISO
   - At disk selection screen, click "Load driver"
   - Browse to VirtIO CD (usually D: or E:)
   - Navigate to: viostor\w11\amd64
   - Select Red Hat VirtIO SCSI controller and install
   - Now the disk will be visible - select it and continue installation

3. FIRST BOOT CONFIGURATION
   - Complete Windows OOBE (region, keyboard, network)
   - Create local administrator account (avoid Microsoft account)
   - Skip privacy options for faster setup

4. INSTALL VIRTIO DRIVERS
   From Device Manager, update drivers for unknown devices:
   - Network: NetKVM\w11\amd64
   - Balloon: Balloon\w11\amd64
   - Serial: vioserial\w11\amd64
   - Display: qxldod\w11\amd64 (if using QXL)

5. INSTALL QEMU GUEST AGENT (CRITICAL!)
   From VirtIO CD, run:
   - guest-agent\qemu-ga-x86_64.msi
   This enables OpenShift to manage the VM lifecycle and live migration

6. INSTALL CLOUDBASE-INIT
   Download and install: https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi
   Configuration file location: C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\
   DO NOT run sysprep at the end - we'll do this separately

7. INSTALL BENCHMARK RUNNER PREREQUISITES
   - Python 3.11+
   - Required benchmark frameworks
   - Monitoring agents

8. WINDOWS UPDATES
   Settings > Windows Update > Check for updates
   Restart as needed until fully updated

9. GENERALIZE WITH SYSPREP
   When ready, run:
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown

   This will:
   - Remove machine-specific identifiers (SIDs)
   - Generalize hardware profiles
   - Shut down the VM cleanly

10. AFTER SYSPREP SHUTDOWN
    The VM will stop automatically. Then run:
    ./create-golden-image.sh --export-and-upload

================================================================================

Current Status: Waiting for you to complete installation...

EOF
}

function wait_for_sysprep_shutdown() {
    log_info "Monitoring VM for sysprep shutdown..."

    local timeout=3600  # 1 hour max
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local vm_status
        vm_status=$(oc get vm "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.printableStatus}')

        if [[ "${vm_status}" == "Stopped" ]]; then
            log_info "VM has shut down - sysprep completed successfully"
            return 0
        fi

        sleep 10
        elapsed=$((elapsed + 10))

        if [[ $((elapsed % 300)) -eq 0 ]]; then
            log_info "Still waiting... VM status: ${vm_status}"
        fi
    done

    log_error "Timeout waiting for sysprep shutdown"
    return 1
}

function export_vm() {
    log_info "Creating VirtualMachineExport..."

    # Ensure VM is stopped
    local vm_running
    vm_running=$(oc get vm "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.running}')

    if [[ "${vm_running}" == "true" ]]; then
        log_warn "Stopping VM for export..."
        oc patch vm "${VM_NAME}" -n "${NAMESPACE}" --type merge -p '{"spec":{"running":false}}'
        sleep 10
    fi

    # Create export
    oc apply -f "${MANIFESTS_DIR}/03-vmexport-to-s3.yaml"

    log_info "Waiting for export to be ready..."
    oc wait vmexport "${EXPORT_NAME}" -n "${NAMESPACE}" \
        --for=condition=Ready --timeout=10m

    log_info "Export ready"
}

function download_and_upload_to_s3() {
    log_info "Downloading exported qcow2 image..."

    local output_file="windows11-golden-${IMAGE_VERSION}.qcow2"

    # Download using virtctl
    virtctl vmexport download "${EXPORT_NAME}" \
        --namespace="${NAMESPACE}" \
        --output="${output_file}" \
        --volume=windows11-golden-disk \
        --insecure

    log_info "Download complete: ${output_file}"

    # Calculate checksum
    local sha256sum
    sha256sum=$(sha256sum "${output_file}" | cut -d' ' -f1)
    log_info "SHA256: ${sha256sum}"

    # Upload to S3
    if [[ -z "${S3_BUCKET}" ]]; then
        log_warn "S3_BUCKET not set. Skipping upload."
        log_info "Image available at: $(pwd)/${output_file}"
        log_info "Manual upload command:"
        log_info "  aws s3 cp ${output_file} s3://YOUR_BUCKET/${S3_PREFIX}/${output_file}"
        return 0
    fi

    log_info "Uploading to S3..."

    local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${output_file}"

    aws s3 cp "${output_file}" "${s3_path}" \
        --profile "${AWS_PROFILE}"

    log_info "Upload complete: ${s3_path}"

    # Create metadata file
    cat > "windows11-golden-${IMAGE_VERSION}-metadata.json" <<EOF
{
  "image_name": "windows11-golden",
  "version": "${IMAGE_VERSION}",
  "s3_bucket": "${S3_BUCKET}",
  "s3_key": "${S3_PREFIX}/${output_file}",
  "s3_url": "${s3_path}",
  "sha256": "${sha256sum}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_vm": "${VM_NAME}",
  "namespace": "${NAMESPACE}"
}
EOF

    log_info "Metadata saved: windows11-golden-${IMAGE_VERSION}-metadata.json"

    # Update DataSource manifest with actual values
    log_info "Updating DataSource manifest..."

    local datasource_file="${MANIFESTS_DIR}/04-datasource-from-s3.yaml"
    local http_url="https://${S3_BUCKET}.s3.amazonaws.com/${S3_PREFIX}/${output_file}"

    sed -i "s|https://your-bucket.s3.amazonaws.com/golden-images/windows11/v1.0.0/windows11-golden.qcow2|${http_url}|g" "${datasource_file}"
    sed -i "s|sha256:REPLACE_WITH_ACTUAL_SHA256|sha256:${sha256sum}|g" "${datasource_file}"

    log_info "DataSource manifest updated. Deploy with:"
    log_info "  oc apply -f ${datasource_file}"
}

function create_datasource() {
    log_info "Creating DataSource in openshift-virtualization-os-images..."

    # Check if namespace exists
    if ! oc get namespace openshift-virtualization-os-images &>/dev/null; then
        log_error "Namespace openshift-virtualization-os-images does not exist"
        log_error "This namespace should be created by OpenShift Virtualization operator"
        exit 1
    fi

    # Apply DataSource manifest
    oc apply -f "${MANIFESTS_DIR}/04-datasource-from-s3.yaml"

    log_info "DataSource created successfully"
    log_info "Waiting for CDI import to complete..."

    oc wait pvc windows11-golden-import-pvc \
        -n openshift-virtualization-os-images \
        --for=jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/storage\.pod\.phase}'=Succeeded \
        --timeout=30m

    log_info "Import complete! Windows 11 golden image is now available cluster-wide"
    log_info "Use in VMs with:"
    log_info "  LPC_LP_CNV__VM__DV_SOURCE_NAME=windows11-golden"
    log_info "  LPC_LP_CNV__VM__DV_SOURCE_NS=openshift-virtualization-os-images"
}

function cleanup_export() {
    log_info "Cleaning up export resources..."

    oc delete vmexport "${EXPORT_NAME}" -n "${NAMESPACE}" --ignore-not-found=true

    log_info "Export resources cleaned up"
}

function show_usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Cloud-native Windows 11 golden image creation using OpenShift Virtualization

COMMANDS:
    deploy                  Deploy VM and start installation
    export-and-upload       Export VM to qcow2 and upload to S3 (after sysprep)
    create-datasource       Create DataSource from S3 image
    full-workflow           Complete workflow (requires manual installation steps)
    cleanup                 Clean up VM and export resources

ENVIRONMENT VARIABLES:
    NAMESPACE               Namespace for image builder (default: windows-image-builder)
    VM_NAME                 VM name (default: windows11-golden-builder)
    IMAGE_VERSION           Image version tag (default: v1.0.0)
    S3_BUCKET               S3 bucket for image storage
    S3_PREFIX               S3 prefix (default: golden-images/windows11)
    AWS_PROFILE             AWS CLI profile (default: default)

EXAMPLES:
    # Deploy VM and start installation
    $0 deploy

    # After completing installation and sysprep
    S3_BUCKET=my-bucket $0 export-and-upload

    # Create cluster-wide DataSource
    $0 create-datasource

EOF
}

function main() {
    local command="${1:-}"

    case "${command}" in
        deploy)
            check_prerequisites
            create_namespace
            deploy_vm
            show_installation_guide
            ;;
        export-and-upload)
            check_prerequisites
            export_vm
            download_and_upload_to_s3
            cleanup_export
            ;;
        create-datasource)
            check_prerequisites
            create_datasource
            ;;
        full-workflow)
            check_prerequisites
            create_namespace
            deploy_vm
            show_installation_guide
            log_warn "Complete Windows installation and sysprep, then run:"
            log_warn "  $0 export-and-upload"
            ;;
        cleanup)
            log_info "Cleaning up resources..."
            oc delete vm "${VM_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
            oc delete vmexport "${EXPORT_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
            log_info "Cleanup complete"
            ;;
        --help|-h|"")
            show_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
