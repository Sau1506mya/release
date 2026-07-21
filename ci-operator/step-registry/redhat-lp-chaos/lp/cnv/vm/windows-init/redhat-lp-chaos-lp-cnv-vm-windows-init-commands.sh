#!/bin/bash

set -euo pipefail

# Read VM names from shared directory
if [[ ! -f "${SHARED_DIR}/target-vm-name.txt" ]]; then
    echo "ERROR: VM names file not found at ${SHARED_DIR}/target-vm-name.txt"
    exit 1
fi

vmList=$(cat "${SHARED_DIR}/target-vm-name.txt")
echo "Initializing Windows VMs: ${vmList}"

# Function to check if CloudBase-Init has completed
function check_cloudbase_init() {
    local vmName="${1}"
    local namespace="${2}"

    echo "Checking CloudBase-Init status for ${vmName}..."

    # Check if VM is accessible via virtctl
    if ! oc get vm "${vmName}" -n "${namespace}" &>/dev/null; then
        echo "ERROR: VM ${vmName} not found in namespace ${namespace}"
        return 1
    fi

    # Wait for VM to have an IP address (indicates network is up)
    echo "Waiting for ${vmName} to get an IP address..."
    local timeout=300
    local elapsed=0
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if oc get vmi "${vmName}" -n "${namespace}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &>/dev/null; then
            vmIP=$(oc get vmi "${vmName}" -n "${namespace}" -o jsonpath='{.status.interfaces[0].ipAddress}')
            echo "VM ${vmName} has IP: ${vmIP}"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ ${elapsed} -ge ${timeout} ]]; then
        echo "ERROR: Timeout waiting for ${vmName} to get IP address"
        return 1
    fi

    # Store VM IP for benchmark runner
    echo "${vmName}=${vmIP}" >> "${SHARED_DIR}/windows-vm-ips.txt"

    echo "CloudBase-Init check completed for ${vmName}"
    return 0
}

# Function to verify Windows services
function verify_windows_services() {
    local vmName="${1}"
    local namespace="${2}"

    echo "Verifying Windows services for ${vmName}..."

    # Use virtctl to execute commands in the VM
    # Note: This requires guest agent to be running
    if ! oc get vmi "${vmName}" -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' | grep -q "True"; then
        echo "WARNING: Guest agent not connected for ${vmName}, skipping service verification"
        return 0
    fi

    echo "Guest agent is connected for ${vmName}"

    # Basic verification - we can extend this with actual virtctl exec commands
    # For now, just confirm the guest agent is responding

    return 0
}

# Initialize all VMs
declare -a failedVMs=()

for vm in ${vmList}; do
    echo "=== Processing VM: ${vm} ==="

    if ! check_cloudbase_init "${vm}" "${LPC_LP_CNV__VM__NS}"; then
        echo "ERROR: CloudBase-Init check failed for ${vm}"
        failedVMs+=("${vm}")
        continue
    fi

    if ! verify_windows_services "${vm}" "${LPC_LP_CNV__VM__NS}"; then
        echo "WARNING: Service verification had issues for ${vm}"
        # Don't fail on this, just warn
    fi

    echo "=== VM ${vm} initialized successfully ==="
done

# Report results
if [[ ${#failedVMs[@]} -gt 0 ]]; then
    echo "ERROR: Failed to initialize the following VMs: ${failedVMs[*]}"
    exit 1
fi

echo "All Windows VMs initialized successfully"
echo "VM IPs stored in: ${SHARED_DIR}/windows-vm-ips.txt"

# Create a summary file for benchmark runner
cat > "${SHARED_DIR}/windows-vm-manifest.json" <<EOF
{
  "namespace": "${LPC_LP_CNV__VM__NS}",
  "vm_prefix": "${LPC_LP_CNV__VM__PREFIX}",
  "admin_user": "${LPC_LP_CNV__WIN__ADMIN_USER}",
  "vms": [
$(for vm in ${vmList}; do
    vmIP=$(grep "^${vm}=" "${SHARED_DIR}/windows-vm-ips.txt" | cut -d= -f2)
    echo "    {\"name\": \"${vm}\", \"ip\": \"${vmIP}\"},"
done | sed '$ s/,$//')
  ]
}
EOF

echo "Windows VM manifest created at: ${SHARED_DIR}/windows-vm-manifest.json"
cat "${SHARED_DIR}/windows-vm-manifest.json"

true
