#!/usr/bin/env bash
# Generate Talos Image Factory URLs for the configured overlay.
# Outputs direct download URLs and user-friendly Image Factory UI links for
# the main schematic (bare metal / Proxmox) and the Raspberry Pi 4 schematic.
#
# Usage: .vscode/tasks/generate-image-urls.sh <env-file> <workspace-dir>

set -euo pipefail

ENV_FILE="${1:?env file path is required}"
WORKSPACE_DIR="${2:-$(pwd)}"

[[ "$ENV_FILE" = /* ]] || ENV_FILE="$WORKSPACE_DIR/$ENV_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_TASKS_DIR="$(cd "$SCRIPT_DIR/../../adminTasks" && pwd)"

# shellcheck source=../../adminTasks/lib/logging.sh
source "$ADMIN_TASKS_DIR/lib/logging.sh"
# shellcheck source=../../adminTasks/lib/image-factory.sh
source "$ADMIN_TASKS_DIR/lib/image-factory.sh"

# ============================================================================
# VALIDATE REQUIRED VARIABLES
# ============================================================================

if [[ -z "${TALOS_INSTALL_VERSION:-}" ]]; then
  log_error "TALOS_INSTALL_VERSION must be set in the env file."
  exit 1
fi

if [[ -z "${TALOS_INSTALLER_TYPE:-}" ]]; then
  log_error "TALOS_INSTALLER_TYPE must be set in the env file."
  exit 1
fi

# ============================================================================
# CREATE SCHEMATICS (reuses existing image-factory.sh functions)
# ============================================================================

log_info "Creating main schematic for ${TALOS_INSTALLER_TYPE}..."
SCHEMATIC_ID=$(create_schematic)
if [[ -z "$SCHEMATIC_ID" ]]; then
  log_error "Failed to create main schematic."
  exit 1
fi

log_info "Creating Raspberry Pi 4 schematic..."
RPI_SCHEMATIC_ID=$(create_rpi_schematic || true)

# ============================================================================
# DERIVE PLATFORM AND VERSION
# ============================================================================

# Strip leading 'v' — the Image Factory UI uses bare version numbers (e.g. 1.12.4)
VERSION_BARE="${TALOS_INSTALL_VERSION#v}"

# Derive the Talos runtime platform from installer type.
# This is the platform Talos reports at runtime (used in machine config).
if [[ "${TALOS_INSTALLER_TYPE}" == nocloud* ]]; then
  PLATFORM="nocloud"
else
  PLATFORM="metal"
fi

# The Image Factory UI platform matches the Talos runtime platform.
# For nocloud (Proxmox/VMs) the UI target category is "cloud"; for bare metal it is "metal".
UI_PLATFORM="${PLATFORM}"
if [[ "${PLATFORM}" == "nocloud" ]]; then
  UI_TARGET="cloud"
else
  UI_TARGET="metal"
fi

# Append secureboot=true to the UI URL when the installer type includes secure boot.
UI_SECUREBOOT=""
if [[ "${TALOS_INSTALLER_TYPE}" == *secureboot* ]]; then
  UI_SECUREBOOT="&secureboot=true"
fi

# ============================================================================
# OUTPUT
# ============================================================================

HR="══════════════════════════════════════════════════════════════════════════"

echo ""
echo "$HR"
echo ""
echo "  Talos Image Factory URLs"
echo "  Overlay:           ${OVERLAY_NAME:-<unknown>}"
echo "  Version:           ${TALOS_INSTALL_VERSION}"
echo "  Installer type:    ${TALOS_INSTALLER_TYPE}  (runtime platform: ${PLATFORM})"
echo "  Extensions:        ${TALOS_SCHEMATIC_EXTENSIONS[*]:-<none>}"
echo "  Extra kernel args: ${TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS[*]:-<none>}"
echo ""
echo "$HR"
echo ""
echo "  ── Main Schematic ───────────────────────────────────────────────────────"
echo ""
echo "  Schematic ID:"
echo "    ${SCHEMATIC_ID}"
echo ""
echo "  Image Factory UI (open in browser to see all available images):"
echo "    ${FACTORY_BASE_URL}/?arch=amd64&platform=${UI_PLATFORM}&schematic-id=${SCHEMATIC_ID}&target=${UI_TARGET}&version=${VERSION_BARE}${UI_SECUREBOOT}"
echo ""
echo "  Install image  (embed in machine config / use for talosctl upgrade):"
echo "    factory.talos.dev/${TALOS_INSTALLER_TYPE}/${SCHEMATIC_ID}:${TALOS_INSTALL_VERSION}"
echo ""
echo "  ISO — bare metal / Proxmox:"
echo "    ${FACTORY_BASE_URL}/image/${SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-amd64.iso"
echo ""
echo "  ISO — bare metal Secure Boot:"
echo "    ${FACTORY_BASE_URL}/image/${SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-amd64-secureboot.iso"
echo ""

if [[ -n "${RPI_SCHEMATIC_ID:-}" ]]; then
  echo "$HR"
  echo ""
  echo "  ── Raspberry Pi 4 Schematic ─────────────────────────────────────────"
  echo ""
  echo "  Schematic ID:"
  echo "    ${RPI_SCHEMATIC_ID}"
  echo ""
  echo "  Image Factory UI:"
  echo "    ${FACTORY_BASE_URL}/?arch=arm64&platform=metal&schematic-id=${RPI_SCHEMATIC_ID}&target=sbc&version=${VERSION_BARE}"
  echo ""
  echo "  SD card image (.raw.xz):"
  echo "    ${FACTORY_BASE_URL}/image/${RPI_SCHEMATIC_ID}/${TALOS_INSTALL_VERSION}/metal-arm64.raw.xz"
  echo ""
  echo "  Flash command:"
  echo "    # macOS"
  echo "    xz -d -c metal-arm64.raw.xz | sudo dd conv=fsync bs=16m of=/dev/rdiskN"
  echo "    # Linux"
  echo "    xz -d -c metal-arm64.raw.xz | sudo dd conv=fsync bs=4M of=/dev/sdX"
  echo ""
fi

echo "$HR"
echo ""
