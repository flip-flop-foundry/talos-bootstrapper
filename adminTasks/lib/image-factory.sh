#!/usr/bin/env bash
# Image Factory API library for Talos PXE boot
# Provides functions to create schematics and download PXE boot assets
# from https://factory.talos.dev

FACTORY_BASE_URL="https://factory.talos.dev"

# Detect container runtime CLI.
# Prefers TALOS_CONTAINER_CLI if set, then docker, then podman.
detect_container_runtime() {
  if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
    return 0
  fi

  local preferred="${TALOS_CONTAINER_CLI:-}"
  if [[ -n "$preferred" ]]; then
    if command -v "$preferred" >/dev/null 2>&1; then
      CONTAINER_RUNTIME="$preferred"
      return 0
    fi
    log_error "TALOS_CONTAINER_CLI is set to '$preferred' but not found in PATH."
    return 1
  fi

  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
  else
    log_error "No container runtime found. Install docker or podman, or set TALOS_CONTAINER_CLI."
    return 1
  fi

  return 0
}

# Create a schematic on the Image Factory and return the schematic ID.
# Uses TALOS_SCHEMATIC_EXTENSIONS and TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS arrays from env.
# Returns: schematic ID (hash) on stdout
create_schematic() {
  local schematic_yaml=""

  # Build the schematic YAML
  schematic_yaml="customization:"

  # Add extensions
  if [[ ${#TALOS_SCHEMATIC_EXTENSIONS[@]} -gt 0 ]]; then
    schematic_yaml+=$'\n  systemExtensions:'
    schematic_yaml+=$'\n    officialExtensions:'
    for ext in "${TALOS_SCHEMATIC_EXTENSIONS[@]}"; do
      schematic_yaml+=$'\n      - '"$ext"
    done
  fi

  # Add extra kernel args
  if [[ ${#TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[@]} -gt 0 ]]; then
    schematic_yaml+=$'\n  extraKernelArgs:'
    for arg in "${TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[@]}"; do
      schematic_yaml+=$'\n    - '"$arg"
    done
  fi

  log_info "Creating schematic on Image Factory..."
  log_info "Schematic YAML:"
  echo "$schematic_yaml" | while IFS= read -r line; do log_info "  $line"; done

  local response
  response=$(curl -sS -X POST "${FACTORY_BASE_URL}/schematics" \
    -H "Content-Type: application/yaml" \
    --data-raw "$schematic_yaml" 2>&1)

  local schematic_id
  schematic_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

  if [[ -z "$schematic_id" ]]; then
    log_error "Failed to create schematic. Response: $response"
    return 1
  fi

  log_success "Schematic created: $schematic_id"
  echo "$schematic_id"
}

# Create a Raspberry Pi 4 schematic on the Image Factory and return the schematic ID.
# Uses the same TALOS_SCHEMATIC_EXTENSIONS and TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS as the
# main schematic, but adds the rpi_generic overlay required for Pi 4 hardware support.
# Returns: schematic ID (hash) on stdout
create_rpi_schematic() {
  local schematic_yaml="overlay:
    image: siderolabs/sbc-raspberrypi
    name: rpi_generic
customization:"

  # Add extensions
  if [[ ${#TALOS_SCHEMATIC_EXTENSIONS[@]} -gt 0 ]]; then
    schematic_yaml+=$'\n  systemExtensions:'
    schematic_yaml+=$'\n    officialExtensions:'
    for ext in "${TALOS_SCHEMATIC_EXTENSIONS[@]}"; do
      schematic_yaml+=$'\n      - '"$ext"
    done
  fi


  local -a rpi_kernel_args=()
  #local -a rpi_kernel_args=()
  for arg in "${TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[@]+"${TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[@]}"}"; do
    rpi_kernel_args+=("$arg")
  done
  if [[ ${#rpi_kernel_args[@]} -gt 0 ]]; then
    schematic_yaml+=$'\n  extraKernelArgs:'
    for arg in "${rpi_kernel_args[@]}"; do
      schematic_yaml+=$'\n    - '"$arg"
    done
  fi

  log_info "Creating Raspberry Pi 4 schematic on Image Factory..."

  local response
  response=$(curl -sS -X POST "${FACTORY_BASE_URL}/schematics" \
    -H "Content-Type: application/yaml" \
    --data-raw "$schematic_yaml" 2>&1)

  local schematic_id
  schematic_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

  if [[ -z "$schematic_id" ]]; then
    log_error "Failed to create RPi schematic. Response: $response"
    return 1
  fi

  log_success "RPi schematic created: $schematic_id"
  echo "$schematic_id"
}

# Download PXE boot assets (kernel, initramfs, cmdline) to a local directory.
# Args:
#   $1 - schematic ID
#   $2 - Talos version (e.g. v1.12.4)
#   $3 - output directory
download_pxe_assets() {
  local schematic_id="$1"
  local talos_version="$2"
  local output_dir="$3"

  local version_dir="${output_dir}/${talos_version}"
  mkdir -p "$version_dir"

  local base_url="${FACTORY_BASE_URL}/image/${schematic_id}/${talos_version}"

  local assets=("kernel-amd64" "initramfs-amd64.xz" "cmdline-metal-amd64")

  for asset in "${assets[@]}"; do
    local target="${version_dir}/${asset}"
    if [[ -f "$target" && -s "$target" ]]; then
      log_info "Asset already cached: $asset"
      continue
    fi

    log_info "Downloading ${asset}..."
    if ! curl -sSfL -o "$target" "${base_url}/${asset}"; then
      log_error "Failed to download ${asset} from ${base_url}/${asset}"
      rm -f "$target"
      return 1
    fi
    log_success "Downloaded: $asset ($(du -h "$target" | cut -f1))"
  done

  log_success "All PXE assets downloaded to $version_dir"
}

# Clean up old versioned asset directories, keeping only the current version.
# Args:
#   $1 - assets base directory
#   $2 - current version to keep (e.g. v1.12.4)
cleanup_old_assets() {
  local assets_dir="$1"
  local current_version="$2"

  if [[ ! -d "$assets_dir" ]]; then
    return 0
  fi

  local cleaned=0
  for dir in "$assets_dir"/v*/; do
    [[ -d "$dir" ]] || continue
    local dir_name
    dir_name=$(basename "$dir")
    if [[ "$dir_name" != "$current_version" ]]; then
      log_info "Cleaning up old assets: $dir_name"
      rm -rf "$dir"
      ((cleaned++))
    fi
  done

  if [[ $cleaned -gt 0 ]]; then
    log_info "Cleaned up $cleaned old asset version(s)"
  fi
}

# Generate the iPXE boot script from a template.
# Args:
#   $1 - template file path
#   $2 - output file path
#   $3 - PXE server base URL (e.g. http://192.168.120.10:8080)
#   $4 - Talos version (e.g. v1.12.4)
generate_ipxe_script() {
  local template="$1"
  local output="$2"
  local pxe_server_url="$3"
  local talos_version="$4"

  PXE_SERVER_URL="$pxe_server_url" PXE_TALOS_VERSION="$talos_version" \
    envsubst '${PXE_SERVER_URL} ${PXE_TALOS_VERSION}' < "$template" > "$output"

  log_success "Generated iPXE boot script: $output"
}

# Build custom iPXE UEFI firmware with an embedded chainload script.
# The embedded script hardcodes the HTTP boot URL, avoiding DHCP boot-loop
# issues when using manual DHCP options (option 66+67) on a router.
# Caches the build and only rebuilds when the embed script changes.
# Args:
#   $1 - PXE server URL (e.g. http://10.117.5.18)
#   $2 - output directory for firmware files
#   $3 - PXE directory (contains Dockerfile.ipxe)
build_ipxe_firmware() {
  local pxe_server_url="$1"
  local output_dir="$2"
  local pxe_dir="$3"

  mkdir -p "$output_dir"

  # Generate the embedded iPXE script
  local embed_script="${pxe_dir}/embed.ipxe"
  cat > "$embed_script" <<EOF
#!ipxe
:retry
dhcp
chain ${pxe_server_url}/ipxe-boot.ipxe && exit
echo Chainload failed, retrying in 5 seconds...
sleep 5
goto retry
EOF

  # Check if firmware needs rebuilding (compare embed script hash)
  local hash_file="${output_dir}/.embed-hash"
  local current_hash
  current_hash=$(shasum -a 256 "$embed_script" | cut -d' ' -f1)

  if [[ -f "$hash_file" && -f "${output_dir}/ipxe.efi" ]]; then
    local cached_hash
    cached_hash=$(cat "$hash_file")
    if [[ "$cached_hash" == "$current_hash" ]]; then
      log_info "iPXE firmware is up to date (cached)"
      return 0
    fi
  fi

  log_info "Building iPXE UEFI firmware with embedded chainload script..."
  log_info "  Chainload URL: ${pxe_server_url}/ipxe-boot.ipxe"
  log_info "  First build is slow (~7min on Apple Silicon); subsequent builds only re-link (~10s)..."

  detect_container_runtime || return 1
  log_info "  Container runtime: ${CONTAINER_RUNTIME}"

  if [[ "$CONTAINER_RUNTIME" == "docker" ]] && docker buildx version >/dev/null 2>&1; then
    if ! docker buildx build \
      --platform linux/amd64 \
      -f "${pxe_dir}/Dockerfile.ipxe" \
      --output "type=local,dest=${output_dir}" \
      "${pxe_dir}"; then
      log_error "iPXE firmware build failed"
      return 1
    fi
  else
    local image_tag="talos-ipxe-builder:local"
    local container_id=""

    log_info "  Using compatible build fallback (no docker buildx)."
    if ! "$CONTAINER_RUNTIME" build \
      --platform linux/amd64 \
      -f "${pxe_dir}/Dockerfile.ipxe" \
      -t "$image_tag" \
      "${pxe_dir}"; then
      log_error "iPXE firmware build failed"
      return 1
    fi

    container_id=$("$CONTAINER_RUNTIME" create "$image_tag") || {
      log_error "Failed to create temporary container for artifact extraction"
      return 1
    }

    if ! "$CONTAINER_RUNTIME" cp "${container_id}:/ipxe.efi" "${output_dir}/ipxe.efi"; then
      "$CONTAINER_RUNTIME" rm -f "$container_id" >/dev/null 2>&1 || true
      log_error "Failed to extract ipxe.efi from build image"
      return 1
    fi

    "$CONTAINER_RUNTIME" rm -f "$container_id" >/dev/null 2>&1 || true
    "$CONTAINER_RUNTIME" rmi "$image_tag" >/dev/null 2>&1 || true
  fi

  # Save hash for cache validation
  echo "$current_hash" > "$hash_file"

  log_success "Built iPXE firmware: ipxe.efi (UEFI)"
}
