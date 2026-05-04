#!/bin/bash

##############################################################################
# push-to-gitea.sh
#
# Pushes the current working state of the repository to Gitea.
# Intended to be run after render-overlay.sh so rendered manifests are
# included in the push.
##############################################################################

set -euo pipefail

# ============================================================================
# ARGUMENT PARSING AND CONFIGURATION LOADING
# ============================================================================

if [ $# -ne 1 ]; then
  echo "Usage: $0 <config-file>"
  exit 1
fi

CONFIG_FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file $CONFIG_FILE not found!"
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OVERLAY_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
export LIB_DIR="$SCRIPT_DIR/lib"

# ============================================================================
# LOAD LIBRARIES
# ============================================================================

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"

# ============================================================================
# PUSH TO GITEA
# ============================================================================

log_info "Fetching Gitea admin credentials..."
giteaAdminCredentials=$(fetch_gitea_admin_credentials)

log_info "Pushing working state to Gitea (branch: main)..."
push_to_gitea_cluster_services "$giteaAdminCredentials" --push-working-state --destination-branch main

log_success "Working state pushed to Gitea successfully."
