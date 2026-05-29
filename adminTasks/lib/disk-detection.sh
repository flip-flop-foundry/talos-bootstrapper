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
# Args: $1 = node hostname/IP
#       $2 = talosconfig path (optional)
#       $3 = machine config file (optional) — used during maintenance mode to
#            resolve the install disk from machine.install.disk / diskSelector
# Env:  LONGHORN_IGNORE_USB_DISKS - if "true", disks with transport "usb" are excluded
detect_node_disks() {
    local node="$1"
    local talosconfig="${2:-}"
    local machine_config_file="${3:-}"
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
            log_error "Command used: ${talosctl_cmd[*]} get disks --nodes $node --endpoints $node --insecure -o json"
            return 1
        fi
    else
        log_error "Failed to query disks from node $node"
        log_error "Error: $error_output"
        log_error "Command used: ${talosctl_cmd[*]} get disks --nodes $node --endpoints $node -o json"
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
    local systemdisk_json=""
    local systemdisk_error=""
    if systemdisk_error=$("${talosctl_cmd[@]}" get systemdisk --nodes "$node" --endpoints "$node" -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex"); then
        # Authenticated query succeeded
        systemdisk_json="$systemdisk_error"
    elif echo "$systemdisk_error" | grep -qE "certificate signed by unknown authority|certificate is not valid for any names"; then
        # TLS cert mismatch — node is in maintenance/pre-install mode; retry without cert verification
        log_warn "Looks like non bootstrapped node, retrying systemdisk query with --insecure flag for node $node"
        local insecure_rc=0
        local insecure_output=""
        insecure_output=$("${talosctl_cmd[@]}" get systemdisk --nodes "$node" --endpoints "$node" --insecure -o json 2>&1 | grep -v '^WARNING:' | sed "$normalize_hex") || insecure_rc=$?
        # Validate that the output is actual JSON, regardless of exit code.
        # Without pipefail the pipeline may exit 0 even if talosctl failed, and
        # non-JSON error text would reach the jq devPath extractor and silently
        # return empty, bypassing the machine-config fallback below.
        if [[ $insecure_rc -eq 0 ]] && echo "$insecure_output" | jq empty 2>/dev/null; then
            systemdisk_json="$insecure_output"
        else
            [[ -n "$insecure_output" ]] && log_warn "systemdisk (--insecure) output on $node: $(echo "$insecure_output" | head -3)"
            # systemdisk unavailable even insecurely — expected for a pre-install node where
            # the resource does not yet exist in the maintenance-mode API.
            # Try to infer the install disk from the generated machine config instead.
            if [[ -n "$machine_config_file" && -f "$machine_config_file" ]]; then
                log_info "systemdisk unavailable on $node (pre-install); resolving install disk from machine config..."
                system_disk=$(_resolve_install_disk_from_config "$machine_config_file" "$disks_json" "$node")
                if [[ -n "$system_disk" ]]; then
                    log_info "Resolved install disk on $node (from machine config): $system_disk"
                else
                    log_warn "Could not resolve install disk from machine config for $node — skipping additional disk detection."
                    log_warn "Set machine.install.disk explicitly, or ensure machine.install.diskSelector.size targets a single disk."
                    return 0
                fi
            else
                log_warn "systemdisk not available on $node and no machine config provided — skipping additional disk detection."
                log_warn "Re-run cluster-initialSetup.sh after the node is bootstrapped to apply data-disk configs."
                return 0
            fi
        fi
    else
        # Non-TLS failure (network issue, auth expiry, wrong endpoint, etc.) — hard fail
        log_error "Failed to query systemdisk on $node: $systemdisk_error"
        return 1
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
        else
            # JSON was returned but devPath could not be extracted — unexpected API schema
            log_error "systemdisk query returned JSON on $node but devPath could not be extracted"
            log_error "Raw systemdisk JSON (first 5 lines): $(echo "$systemdisk_json" | head -5)"
            return 1
        fi
    fi

    if [ -z "$system_disk" ]; then
        # Safety net — should be unreachable with the flow above
        log_warn "Cannot identify system disk on $node — skipping additional disk detection."
        return 0
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

# Resolve the Talos install (system) disk from a generated machine config file.
# Called on pre-install nodes where the systemdisk resource is not yet available.
# Args: $1 = machine_config_file path
#       $2 = disks_json (from talosctl get disks --insecure)
#       $3 = node name (for logging only)
# Outputs: resolved /dev/... path on stdout, empty on failure
_resolve_install_disk_from_config() {
    local machine_config_file="$1"
    local disks_json="$2"
    local node="${3:-unknown}"

    # 1. Explicit machine.install.disk — the simplest and most reliable case.
    local install_disk
    install_disk=$(yq 'select(di == 0) | .machine.install.disk // ""' "$machine_config_file" 2>/dev/null | tr -d '"' | tr -d "'" | xargs)
    if [[ -n "$install_disk" && "$install_disk" != "null" ]]; then
        echo "$install_disk"
        return 0
    fi

    # 2. machine.install.diskSelector.size  (e.g. ">= 64GB")
    # Talos evaluates diskSelector using CEL; here we handle the common size-only
    # constraint and mirror Talos's tie-breaking rule (alphabetically first match).
    local size_selector
    size_selector=$(yq 'select(di == 0) | .machine.install.diskSelector.size // ""' "$machine_config_file" 2>/dev/null | tr -d '"' | tr -d "'" | xargs)
    if [[ -z "$size_selector" || "$size_selector" == "null" ]]; then
        return 1
    fi

    local op num unit threshold
    op=$(echo "$size_selector"   | grep -oE '>=|<=|>|<|=='        | head -n1)
    num=$(echo "$size_selector"  | grep -oE '[0-9]+(\.[0-9]+)?'   | head -n1)
    unit=$(echo "$size_selector" | grep -oiE 'TiB|GiB|MiB|KiB|TB|GB|MB|KB' | head -n1 | tr '[:lower:]' '[:upper:]')

    if [[ -z "$op" || -z "$num" || -z "$unit" ]]; then
        log_warn "Cannot parse diskSelector.size \"$size_selector\" on $node — only simple size comparisons (e.g. >= 64GB) are supported"
        return 1
    fi

    # Reject decimal sizes — bash arithmetic is integer-only, and Talos disk
    # selectors in practice always use whole-number units (e.g. 64GB, 1TB).
    if echo "$num" | grep -q '\.'; then
        log_warn "Decimal disk size \"$num\" in diskSelector.size on $node is not supported — use a whole-number value (e.g. >= 64GB)"
        return 1
    fi

    # Convert size to bytes (GB = 10^9, GiB = 2^30, matching Talos bytesize)
    case "$unit" in
        KB)  threshold=$((num * 1000)) ;;
        MB)  threshold=$((num * 1000000)) ;;
        GB)  threshold=$((num * 1000000000)) ;;
        TB)  threshold=$((num * 1000000000000)) ;;
        KIB) threshold=$((num * 1024)) ;;
        MIB) threshold=$((num * 1048576)) ;;
        GIB) threshold=$((num * 1073741824)) ;;
        TIB) threshold=$((num * 1099511627776)) ;;
        *)   log_warn "Unknown size unit \"$unit\" in diskSelector on $node"; return 1 ;;
    esac

    # Filter disk list: include only real block devices that satisfy the size constraint.
    # jq arithmetic comparisons require integers; .spec.size is already in bytes.
    local matching_disks
    matching_disks=$(echo "$disks_json" | jq -r \
        --argjson thr "$threshold" \
        --arg op "$op" '
        ( .items? // (if type=="array" then . else [.] end) )[] as $obj |
        ($obj.spec.dev_path // $obj.spec.devicePath // "") as $dev |
        ($obj.spec.size // 0) as $sz |
        select($dev | test("^/dev/([sv]d[a-z]|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$")) |
        select(
            if   $op == ">=" then $sz >= $thr
            elif $op == ">"  then $sz >  $thr
            elif $op == "<=" then $sz <= $thr
            elif $op == "<"  then $sz <  $thr
            else $sz == $thr end
        ) |
        $dev
    ' 2>/dev/null | sort)

    if [[ -z "$matching_disks" ]]; then
        log_warn "No disks on $node satisfy diskSelector.size \"$size_selector\" (threshold: ${threshold} bytes)"
        return 1
    fi

    local match_count
    match_count=$(echo "$matching_disks" | wc -l | tr -d ' ')
    if [[ "$match_count" -gt 1 ]]; then
        log_warn "$match_count disks on $node match diskSelector.size \"$size_selector\": $(echo "$matching_disks" | tr '\n' ' ')"
        log_warn "Using first (alphabetically) — this mirrors Talos's selection behaviour. Set machine.install.disk explicitly to suppress this warning."
    fi

    echo "$matching_disks" | head -n1
    return 0
}

# Main function to detect disks and generate configs for a node
# Args: $1 = node hostname/IP, $2 = output file path, $3 = KMS endpoint (optional),
#       $4 = talosconfig (optional), $5 = machine config file (optional)
generate_node_disk_configs() {
    local node="$1"
    local output_file="$2"
    local kms_endpoint="${3:-}"
    local talosconfig="${4:-}"
    local machine_config_file="${5:-}"
    
    log_info "Generating disk configurations for node: $node"
    
    # Detect disks
    local disks
    if ! disks=$(detect_node_disks "$node" "$talosconfig" "$machine_config_file"); then
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
export -f _resolve_install_disk_from_config
export -f generate_volume_config
export -f generate_node_disk_configs
