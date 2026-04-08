#!/usr/bin/env bash
# PXE Setup — Creates schematic, downloads boot assets, starts iPXE server
# Usage: ./adminTasks/pxe-setup.sh overlays/<cluster>/<cluster>.env

set -euo pipefail

# ============================================================================
# ARGUMENT PARSING AND CONFIGURATION LOADING
# ============================================================================

if [ $# -ne 1 ]; then
  echo "Usage: $0 <config-file>"
  exit 1
fi

CONFIG_FILE="$1"
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
# shellcheck source=./lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }
# shellcheck source=./lib/image-factory.sh
source "$SCRIPT_DIR/lib/image-factory.sh" || { log_error "Failed to load image-factory.sh"; exit 1; }

PXE_DIR="$SCRIPT_DIR/pxe"
ASSETS_DIR="$PXE_DIR/assets"
TFTP_DIR="$PXE_DIR/tftp"
PROXY_DHCP_ENABLED="${TALOS_PXE_PROXY_DHCP_ENABLED:-false}"

# ============================================================================
# VALIDATE CONFIGURATION
# ============================================================================

if [[ "${TALOS_PXE_ENABLED:-false}" != "true" ]]; then
  log_error "TALOS_PXE_ENABLED is not set to true. Set it in your .env file to use PXE boot."
  exit 1
fi

if [[ -z "${TALOS_PXE_SERVER_IP:-}" ]]; then
  log_error "TALOS_PXE_SERVER_IP must be set in your .env file."
  exit 1
fi

if [[ ${#TALOS_SCHEMATIC_EXTENSIONS[@]} -eq 0 ]]; then
  log_warn "TALOS_SCHEMATIC_EXTENSIONS is empty — schematic will have no extensions."
fi

if [[ -z "${TALOS_INSTALL_VERSION:-}" ]]; then
  log_error "TALOS_INSTALL_VERSION must be set in your .env file."
  exit 1
fi

PXE_PORT="${TALOS_PXE_SERVER_PORT:-80}"
if [[ "$PXE_PORT" == "80" ]]; then
  PXE_SERVER_URL="http://${TALOS_PXE_SERVER_IP}"
else
  PXE_SERVER_URL="http://${TALOS_PXE_SERVER_IP}:${PXE_PORT}"
fi

log_info "PXE Setup Configuration:"
log_info "  Talos version:  $TALOS_INSTALL_VERSION"
log_info "  PXE server:     $PXE_SERVER_URL"
log_info "  ProxyDHCP+TFTP: $PROXY_DHCP_ENABLED"
log_info "  Extensions:     ${TALOS_SCHEMATIC_EXTENSIONS[*]}"
log_info "  Extra args:     ${TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[*]:-<none>}"

TOTAL_STEPS=5
STEP=0

# ============================================================================
# CREATE SCHEMATIC
# ============================================================================

((++STEP))
log_info "Step ${STEP}/${TOTAL_STEPS}: Creating Image Factory schematic..."
SCHEMATIC_ID=$(create_schematic)

if [[ -z "$SCHEMATIC_ID" ]]; then
  log_error "Failed to create schematic."
  exit 1
fi

log_success "Schematic ID: $SCHEMATIC_ID"
log_info "Manual ISO download (for nodes that can't PXE boot):"
log_info "  ${FACTORY_BASE_URL}/image/${SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-amd64.iso"
log_info "  ${FACTORY_BASE_URL}/image/${SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-amd64-secureboot.iso"

RPI_SCHEMATIC_ID=$(create_rpi_schematic)
if [[ -z "$RPI_SCHEMATIC_ID" ]]; then
  log_warn "Failed to create RPi schematic — skipping Raspberry Pi 4 image URL."
else
  log_info "Raspberry Pi 4 SD card image (rpi_generic schematic, includes U-Boot — no separate UEFI firmware needed):"
  log_info "  ${FACTORY_BASE_URL}/image/${RPI_SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-arm64.raw.xz"
  log_info "  Flash with: xz -d -c metal-arm64.raw.xz | sudo dd conv=fsync bs=16m of=/dev/rdiskN"
fi
# ============================================================================
# DOWNLOAD PXE ASSETS
# ============================================================================

((++STEP))
log_info "Step ${STEP}/${TOTAL_STEPS}: Downloading PXE boot assets..."
mkdir -p "$ASSETS_DIR"

download_pxe_assets "$SCHEMATIC_ID" "$TALOS_INSTALL_VERSION" "$ASSETS_DIR"

# Clean up old version directories
cleanup_old_assets "$ASSETS_DIR" "$TALOS_INSTALL_VERSION"

# ============================================================================
# GENERATE IPXE BOOT SCRIPT
# ============================================================================

((++STEP))
log_info "Step ${STEP}/${TOTAL_STEPS}: Generating iPXE boot script..."

# Add extra kernel args to the iPXE template if configured
generate_ipxe_script \
  "$PXE_DIR/ipxe-boot.ipxe.template" \
  "$ASSETS_DIR/ipxe-boot.ipxe" \
  "$PXE_SERVER_URL" \
  "$TALOS_INSTALL_VERSION"

# ============================================================================
# MODE-SPECIFIC SETUP (PROXYDHCP OR MANUAL DHCP WITH IPXE BUILD)
# ============================================================================

((++STEP))
if [[ "$PROXY_DHCP_ENABLED" == "true" ]]; then
  log_info "Step ${STEP}/${TOTAL_STEPS}: Generating dnsmasq proxyDHCP configuration..."

  PXE_DHCP_RANGE="${TALOS_PXE_DHCP_RANGE:-}"
  if [[ -z "$PXE_DHCP_RANGE" ]]; then
    log_error "TALOS_PXE_DHCP_RANGE must be set when proxyDHCP is enabled."
    log_error "Example: export TALOS_PXE_DHCP_RANGE=\"10.117.5.0,proxy,255.255.255.0\""
    exit 1
  fi

  PXE_BOOT_SCRIPT_URL="${PXE_SERVER_URL}/ipxe-boot.ipxe"
  PXE_DHCP_RANGE="$PXE_DHCP_RANGE" PXE_BOOT_SCRIPT_URL="$PXE_BOOT_SCRIPT_URL" \
    envsubst '${PXE_DHCP_RANGE} ${PXE_BOOT_SCRIPT_URL}' \
    < "$PXE_DIR/dnsmasq.conf.template" > "$PXE_DIR/dnsmasq.conf"

  log_success "Generated dnsmasq.conf (proxyDHCP range: $PXE_DHCP_RANGE)"
else
  log_info "Step ${STEP}/${TOTAL_STEPS}: Building iPXE firmware for TFTP (manual DHCP mode)..."
  build_ipxe_firmware "$PXE_SERVER_URL" "$TFTP_DIR" "$PXE_DIR"
fi

# ============================================================================
# START DOCKER PXE SERVER(S)
# ============================================================================

((++STEP))
log_info "Step ${STEP}/${TOTAL_STEPS}: Starting PXE server(s)..."

detect_container_runtime || exit 1
log_info "Using container runtime: ${CONTAINER_RUNTIME}"

if ! "$CONTAINER_RUNTIME" compose version >/dev/null 2>&1; then
  log_error "${CONTAINER_RUNTIME} compose is not available."
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    log_error "Install podman-compose or enable podman compose support."
  fi
  exit 1
fi

# Export the port for docker-compose
export TALOS_PXE_SERVER_PORT="${PXE_PORT}"

# Select compose profile based on mode
COMPOSE_ARGS=(-f "$PXE_DIR/docker-compose.yml")
if [[ "$PROXY_DHCP_ENABLED" == "true" ]]; then
  COMPOSE_ARGS+=(--profile proxydhcp)
else
  COMPOSE_ARGS+=(--profile tftp)
fi

# Check if already running
if "$CONTAINER_RUNTIME" ps --format '{{.Names}}' | grep -q '^talos-pxe-server$'; then
  log_info "PXE server container(s) already running, restarting for updated assets..."
  "$CONTAINER_RUNTIME" compose "${COMPOSE_ARGS[@]}" up -d --force-recreate
else
  "$CONTAINER_RUNTIME" compose "${COMPOSE_ARGS[@]}" up -d
fi

# ============================================================================
# PRINT BOOT INFORMATION
# ============================================================================

log_success "PXE server is running and serving boot assets."
echo ""

if [[ "$PROXY_DHCP_ENABLED" == "true" ]]; then
  log_info "============================================="
  log_info " ProxyDHCP Mode — No Router Config Needed"
  log_info "============================================="
  echo ""
  log_info "dnsmasq is running as a proxyDHCP server alongside your existing DHCP."
  log_info "It automatically directs PXE clients to load iPXE firmware via TFTP,"
  log_info "then chainloads to the HTTP boot script."
  echo ""
  log_info "Boot flow:"
  log_info "  1. Node PXE boots → existing DHCP assigns IP"
  log_info "  2. dnsmasq proxyDHCP responds with TFTP boot info"
  log_info "  3. Node loads iPXE firmware via TFTP from ${TALOS_PXE_SERVER_IP}"
  log_info "  4. iPXE chainloads ${PXE_SERVER_URL}/ipxe-boot.ipxe"
  log_info "  5. Kernel + initramfs loaded via HTTP → Talos maintenance mode"
  echo ""
  log_info "Requirement: PXE server and nodes must be on the same L2 subnet."
  log_info "No changes needed on your router/DHCP server."
else
  log_info "============================================="
  log_info " Manual DHCP Mode — Router Config Required"
  log_info "============================================="
  echo ""
  log_info "Custom iPXE firmware (with embedded chainload) is served via TFTP."
  log_info "Your router/DHCP server must direct PXE clients to this TFTP server."
  echo ""
  log_info "--- UniFi (UDM / UDM Pro / USG) ---"
  log_info "  Settings → Networks → [your network] → Advanced"
  log_info "    → DHCP Options → Add Option → Network Boot"
  log_info "  Server (Option 66): ${TALOS_PXE_SERVER_IP}"
  log_info "  Filename (Option 67): ipxe.efi"
  echo ""
  log_info "--- Generic DHCP server ---"
  log_info "  Option 66 (next-server): ${TALOS_PXE_SERVER_IP}"
  log_info "  Option 67 (boot filename): ipxe.efi"
  echo ""
  log_info "Boot flow:"
  log_info "  1. Node PXE boots → router DHCP assigns IP + boot options"
  log_info "  2. Node TFTPs ipxe.efi from ${TALOS_PXE_SERVER_IP}"
  log_info "  3. Embedded script chainloads ${PXE_SERVER_URL}/ipxe-boot.ipxe (no loop)"
  log_info "  4. Kernel + initramfs loaded via HTTP → Talos maintenance mode"
  echo ""
  log_info "Works across subnets — PXE server and nodes can be on different VLANs."
fi

echo ""
log_info "Nodes will PXE boot into Talos maintenance mode."
log_info "Then run cluster-initialSetup.sh to apply per-node configs."
