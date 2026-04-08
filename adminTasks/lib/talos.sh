#!/bin/bash

# ============================================================================
# adminTasks/lib/talos.sh — Talos cluster management utilities
# ============================================================================
# Shared helper functions for Talos node configuration, reset, apply,
# health checking, and kubeconfig management.
#
# Dependencies: talosctl, yq, logging.sh, disk-detection.sh
# Globals read: TALOSCONFIG, TALOS_DISK_ENCRYPTION_KMS_URL
# ============================================================================

# Generate per-node Talos machine config from a base template.
# Copies base config, applies per-node overlay patch (if exists), detects disks,
# sets HostnameConfig + certSANs, appends manifests.
# Usage: generate_node_config <node_fqdn> <base_yaml> <output_file> <overlay_dir> [append_manifests...]
generate_node_config() {
  local node="$1"
  local base_yaml="$2"
  local config_file="$3"
  local overlay_dir="$4"
  shift 4
  local append_manifests=("$@")

  log_info "  Creating config for node $node -> $config_file"
  cp "$base_yaml" "$config_file"

  # Apply per-node patch if it exists (merges into first YAML document only)
  local node_hostname
  node_hostname=$(echo "$node" | cut -d'.' -f1)
  local node_patch="$overlay_dir/talos/nodes/${node_hostname}.yaml"
  if [[ -f "$node_patch" ]]; then
    log_info "  Applying per-node patch: $node_patch"
    local tmp_main tmp_rest tmp_merged
    tmp_main=$(mktemp)
    tmp_rest=$(mktemp)
    tmp_merged=$(mktemp)
    yq 'select(di == 0)' "$config_file" > "$tmp_main"
    yq 'select(di > 0)' "$config_file" > "$tmp_rest"
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$tmp_main" "$node_patch" > "$tmp_merged"
    cat "$tmp_merged" > "$config_file"
    if [[ -s "$tmp_rest" ]]; then
      echo "---" >> "$config_file"
      cat "$tmp_rest" >> "$config_file"
    fi
    rm -f "$tmp_main" "$tmp_rest" "$tmp_merged"
  fi

  # Disk detection
  log_info "  Detecting disks on node $node..."
  local disk_configs
  disk_configs=$(detect_node_disks "$node" "$TALOSCONFIG")

  if [ -n "$disk_configs" ]; then
    log_info "  Additional disks detected on $node, generating disk configs..."
    generate_node_disk_configs "$node" "$config_file" "$TALOS_DISK_ENCRYPTION_KMS_URL" "$TALOSCONFIG"
  else
    log_info "    No additional disks found on $node (only system disk detected)"
  fi

  # Set hostname in HostnameConfig document
  NODE_FQDN="$node" yq -i '
    select(.kind == "HostnameConfig").hostname = env(NODE_FQDN) |
    select(.kind == "HostnameConfig").auto = "off"
  ' "$config_file"

  # Add FQDN to machine.certSANs (first YAML document only)
  NODE_FQDN="$node" yq -i '
    (select(di == 0).machine.certSANs // []) as $existing |
    select(di == 0).machine.certSANs = ($existing + [env(NODE_FQDN)] | unique)
  ' "$config_file"

  # Append additional manifests
  for manifest in ${append_manifests[@]+"${append_manifests[@]}"}; do
    log_info "  Appending manifest $manifest to $config_file"
    echo "---" >> "$config_file"
    envsubst < "$manifest" >> "$config_file"
    echo "" >> "$config_file"
  done
}

# Reset a single Talos node. Skips if already in maintenance mode.
# Tries authenticated reset first, falls back to insecure.
# Usage: reset_talos_node <node_fqdn> [talosconfig_path]
reset_talos_node() {
  local node="$1"
  local talosconfig="${2:-}"

  local maintenance_check
  set +e
  maintenance_check=$(talosctl get machinestatus --nodes "$node" --endpoints "$node" --insecure 2>&1 &
               PID=$!; sleep 2 && kill "$PID" && echo "timed out" 2>/dev/null & wait "$PID")
  set -e

  if echo "$maintenance_check" | grep -qi "maintenance"; then
    log_success "Node $node is already in maintenance mode, no reset needed."
    return 0
  elif echo "$maintenance_check" | grep -qi "timed out"; then
    log_warn "Node $node did not respond to maintenance check, assuming it's down or unreachable."
    return 0
  fi

  log_warn "Node $node is not in maintenance mode, resetting..."

  set +e
  local reset_rc=1
  if [[ -n "$talosconfig" && -f "$talosconfig" ]]; then
    talosctl reset --graceful=false --reboot --wait=false \
      --talosconfig "$talosconfig" --nodes "$node" --endpoints "$node" 2>/dev/null
    reset_rc=$?
  fi

  if [[ $reset_rc -ne 0 ]]; then
    log_info "Authenticated reset failed for $node, trying --insecure..."
    talosctl reset --graceful=false --reboot --wait=false \
      --nodes "$node" --endpoints "$node" --insecure 2>&1 || true
  fi
  set -e

  log_info "Reset command sent to $node (not waiting for reboot)."
}

# Apply Talos config to a node. Auto-detects whether --insecure is needed.
# If dry_run is "true", uses --dry-run to show what would change without applying.
# Usage: apply_talos_config <node_fqdn> <config_file> [dry_run]
apply_talos_config() {
  local node="$1"
  local config_file="$2"
  local dry_run="${3:-false}"

  local insecure=""
  if ! talosctl get members --nodes "$node" &>/dev/null; then
    insecure=" --insecure"
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "  [DRY RUN] Showing diff for $node (no changes will be applied)"
    talosctl apply-config${insecure} --nodes "$node" --file "$config_file" --dry-run
  else
    talosctl apply-config${insecure} --nodes "$node" --file "$config_file"
  fi
}

# Wait for a Talos node to reach "booting" or "running" state.
# Outputs "booting" or "running" to stdout to indicate node status.
# "booting" means the node needs bootstrapping; "running" means already bootstrapped.
# Usage: wait_for_node_ready <node_fqdn> [timeout_seconds]
# Returns: 0 on success, 1 on timeout
wait_for_node_ready() {
  local node="$1"
  local timeout_seconds="${2:-300}"

  local start_time
  start_time=$(date +%s)
  log_info "Waiting for node $node to become ready (timeout: ${timeout_seconds}s)..."

  while true; do
    set +e
    local health_status
    health_status=$(talosctl get machinestatus --nodes "$node" --endpoints "$node" 2>&1)
    set -e

    if echo "$health_status" | grep -q "booting"; then
      log_success "Node $node is up and running (booting)."
      echo "booting"
      return 0
    elif echo "$health_status" | grep -q "running   true"; then
      log_success "Node $node is up and running."
      echo "running"
      return 0
    fi

    local elapsed=$(( $(date +%s) - start_time ))
    if [[ $elapsed -ge $timeout_seconds ]]; then
      log_error "Timeout waiting for node $node after ${timeout_seconds}s."
      return 1
    fi
    sleep 2
  done
}

# Update talosconfig with endpoint and node list.
# Works around talosctl not accepting an array of nodes by patching via yq.
# Usage: update_talosconfig_context <cluster_name> <talosconfig_path> <endpoint> <nodes...>
update_talosconfig_context() {
  local cluster_name="$1"
  local talosconfig="$2"
  local endpoint="$3"
  shift 3
  local nodes=("$@")

  log_info "Updating talosconfig context for $cluster_name"
  talosctl config endpoint "$endpoint" --talosconfig "$talosconfig"

  local nodes_csv
  nodes_csv=$(IFS=','; echo "${nodes[*]}")
  _TALOS_NODES_CSV="$nodes_csv" yq -i \
    ".contexts.${cluster_name}.nodes = (env(_TALOS_NODES_CSV) | split(\",\"))" "$talosconfig"
}

# Fetch kubeconfig from a Talos node with retry logic.
# Usage: fetch_kubeconfig <node_fqdn> [retries] [delay]
# Returns: 0 on success, 1 on failure after all retries
fetch_kubeconfig() {
  local node="$1"
  local retries="${2:-5}"
  local delay="${3:-5}"

  log_info "Fetching kubeconfig from $node..."
  for attempt in $(seq 1 "$retries"); do
    if talosctl kubeconfig --merge --force --nodes "$node" ~/.kube/config; then
      log_success "Kubeconfig fetched successfully."
      return 0
    elif [[ $attempt -lt $retries ]]; then
      log_warn "Attempt $attempt failed, retrying in ${delay}s..."
      sleep "$delay"
    else
      log_error "Failed to fetch kubeconfig after $retries attempts."
      return 1
    fi
  done
}
