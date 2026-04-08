#!/bin/bash
# disk-detection.sh
# Dynamically detects all disks on Talos nodes and generates UserVolumeConfig manifests
# Supports any number of disks per node

# Source logging library if available
if [ -f "$(dirname "$0")/lib/logging.sh" ]; then
    source "$(dirname "$0")/lib/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
fi

# Detect all non-system disks on a given node
# Args: $1 = node hostname/IP, $2 = talosconfig path (optional)
# Env:  LONGHORN_IGNORE_USB_DISKS - if "true", disks with transport "usb" are excluded
detect_node_disks() {
    local node="$1"
    local talosconfig="${2:-}"
    local ignore_usb="${LONGHORN_IGNORE_USB_DISKS:-false}"
    local talosctl_cmd=(talosctl)
    
    if [ -n "$talosconfig" ] && [ -f "$talosconfig" ]; then
        talosctl_cmd=(talosctl --talosconfig "$talosconfig")
    fi
    
    log_info "Detecting disks on node: $node"

    local normalize_hex='s/\\x\([0-9a-fA-F]\{2\}\)/\\u00\1/g'

    # Query disks from node, filter out WARNING lines
    # Normalize \xNN hex escapes (not valid JSON but emitted by talosctl) to \u00NN
    local disks_json
    local error_output
    if error_output=$("${talosctl_cmd[@]}" get disks --nodes "$node" --endpoints "$node" -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex"); then
        disks_json="$error_output"
    elif echo "$error_output" | grep -qE "certificate signed by unknown authority|certificate is not valid for any names"; then
        log_warn "Looks like non bootstrapped node, retrying with --insecure flag for node $node"
        if ! disks_json=$("${talosctl_cmd[@]}" get disks --nodes "$node" --endpoints "$node" --insecure -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex"); then
            log_error "Failed to query disks from node $node (even with --insecure)"
            log_error "Error: $disks_json"
            return 1
        fi
    else
        log_error "Failed to query disks from node $node"
        log_error "Error: $error_output"
        return 1
    fi

    # Validate JSON
    if ! echo "$disks_json" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from node $node"
        log_error "Response: $disks_json"
        return 1
    fi

    # Detect the boot/system disk via Talos SystemDisk resource.
    # Prefer devPath from talosctl output to avoid brittle mount-based inference.
    local system_disk=""
    local systemdisk_json
    local systemdisk_error
    if systemdisk_error=$("${talosctl_cmd[@]}" get systemdisk --nodes "$node" --endpoints "$node" -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex"); then
        systemdisk_json="$systemdisk_error"
    elif echo "$systemdisk_error" | grep -qE "certificate signed by unknown authority|certificate is not valid for any names"; then
        log_warn "Looks like non bootstrapped node, retrying systemdisk query with --insecure flag for node $node"
        if ! systemdisk_json=$("${talosctl_cmd[@]}" get systemdisk --nodes "$node" --endpoints "$node" --insecure -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex"); then
            log_warn "Failed to query systemdisk on $node (even with --insecure); will use fallback exclusion"
        fi
    else
        log_warn "Failed to query systemdisk on $node; will use fallback exclusion"
    fi

    if [ -n "$systemdisk_json" ]; then
        system_disk=$(echo "$systemdisk_json" | jq -r '
            ( .items? // (if type=="array" then . else [.] end) )[] |
            (
                .spec.devPath //
                .spec.dev_path //
                .spec.devicePath //
                .spec.device_path //
                .devPath //
                .dev_path //
                ""
            ) |
            select(. != "")
        ' 2>/dev/null | head -n1)
        if [ -n "$system_disk" ]; then
            log_info "Detected system disk on $node: $system_disk (from systemdisk devPath)"
        fi
    fi

    if [ -z "$system_disk" ]; then
        local detected_disks
        detected_disks=$(echo "$disks_json" | jq -r '
            ( .items? // (if type=="array" then . else [.] end) )[] |
            (
                .spec.devPath //
                .spec.dev_path //
                .spec.devicePath //
                .spec.device_path //
                ""
            ) |
            select(. != "")
        ' 2>/dev/null | paste -sd ', ' -)

        log_error "Could not detect system disk on $node via systemdisk; aborting disk detection"
        if [ -n "$systemdisk_error" ]; then
            log_error "systemdisk command output: $systemdisk_error"
        fi
        if [ -n "$systemdisk_json" ]; then
            log_error "systemdisk JSON payload: $systemdisk_json"
        fi
        if [ -n "$detected_disks" ]; then
            log_error "Disks reported on node $node: $detected_disks"
        fi
        return 1
    fi


    local non_system_disks
    non_system_disks=$(echo "$disks_json" | jq -r --arg system_disk "$system_disk" '
        ( .items? // (if type=="array" then . else [.] end) )[] as $obj |
        ($obj.spec.dev_path // $obj.spec.devicePath // "") as $dev |
        select($dev != "" ) |
        ($obj.spec.model // "unknown") as $model |
        ($obj.spec.transport // "") as $transport |
        select($dev != $system_disk) |
        select($dev | test("^/dev/([sv]d[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$")) |
        select($model != "VIRTUAL-DISK") |
        {
            path: $dev,
            size: ($obj.spec.size // 0),
            rotational: ($obj.spec.rotational // false),
            model: $model,
            transport: $transport
        }
    ' 2>/dev/null)

    # Apply USB filter post-jq if enabled
    if [ "$ignore_usb" = "true" ] && [ -n "$non_system_disks" ]; then
        non_system_disks=$(echo "$non_system_disks" | jq -r '
            select((.transport // "" | test("usb"; "i")) | not)
        ' 2>/dev/null)
    fi
    
    if [ -z "$non_system_disks" ]; then
        log_info "No additional disks found on node $node (only system disk present)"
        return 0
    fi
    
    # Output detected disks
    echo "$non_system_disks"
}

# Generate UserVolumeConfig for a disk
# Args: $1 = disk path, $2 = size, $3 = is_rotational (true/false), $4 = index, $5 = KMS endpoint
generate_volume_config() {
    local disk_path="$1"
    local size="$2"
    local is_rotational="$3"
    local index="$4"
    local kms_endpoint="${5:-}"
    
    # Extract disk name from path (e.g., /dev/sdb -> sdb)
    local disk_name
    disk_name=$(basename "$disk_path")
    
    # Determine volume name
    local volume_name="disk${index}"
    if [ "$is_rotational" = "true" ]; then
        volume_name="${volume_name}Hdd"
    else
        volume_name="${volume_name}Ssd"
    fi
    
    # Calculate minimum size (90% of disk size to allow for overhead)
    # local min_size
    # min_size=$(echo "$size * 0.9 / 1" | bc)
    # min_size="${min_size%.*}" # Convert to integer bytes
    local min_size="10GB"  # For simplicity, set a fixed minimum size (can be adjusted as needed)
    
    # Generate the UserVolumeConfig YAML
    cat <<EOF
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: $volume_name
provisioning:
  diskSelector:
    match: disk.dev_path == "$disk_path" && disk.rotational == $is_rotational
  grow: true
  minSize: ${min_size}
EOF

    # Add encryption if KMS endpoint is provided
    if [ -n "$kms_endpoint" ]; then

        cat <<EOF
encryption:
  provider: luks2
  keys:
    - slot: 0
      kms:
        endpoint: $kms_endpoint
EOF
    fi
}

# Main function to detect disks and generate configs for a node
# Args: $1 = node hostname/IP, $2 = output file path, $3 = KMS endpoint (optional), $4 = talosconfig (optional)
generate_node_disk_configs() {
    local node="$1"
    local output_file="$2"
    local kms_endpoint="${3:-}"
    local talosconfig="${4:-}"
    
    log_info "Generating disk configurations for node: $node"
    
    # Detect disks
    local disks
    if ! disks=$(detect_node_disks "$node" "$talosconfig"); then
        log_error "Disk detection failed for node $node"
        return 1
    fi
    
    if [ -z "$disks" ]; then
        log_info "No additional disks to configure for node $node"
        return 0
    fi
    
    # Count disks
    local disk_count
    disk_count=$(echo "$disks" | jq -s 'length')
    
    if [ "$disk_count" -eq 0 ]; then
        log_info "No additional disks to configure for node $node"
        return 0
    fi
    
    log_info "Found $disk_count additional disk(s) on node $node"
    
    # Generate configs for each disk
    local index=1
    echo "$disks" | jq -c '.' | while IFS= read -r disk; do
        local disk_path
        disk_path=$(echo "$disk" | jq -r '.path')
        local size
        size=$(echo "$disk" | jq -r '.size')
        local rotational
        rotational=$(echo "$disk" | jq -r '.rotational')
        local model
        model=$(echo "$disk" | jq -r '.model')
        
        log_info "  Disk $index: $disk_path (Size: $size bytes, Rotational: $rotational, Model: $model)"
        
        # Generate config
        generate_volume_config "$disk_path" "$size" "$rotational" "$index" "$kms_endpoint" >> "$output_file"
        
        ((index++))
    done
    
    log_info "Disk configurations written to: $output_file"
}

# Export functions for use in other scripts
export -f detect_node_disks
export -f generate_volume_config
export -f generate_node_disk_configs
