#!/usr/bin/env bash
# =============================================================================
# adminTasks/apply-node-registry-config.sh
#
# Configures every Talos node with registry-specific TLS trust and pull
# credentials for the internal Gitea container registry, using standalone
# Talos v1.12+ documents:
#
#   RegistryTLSConfig  — tells containerd to trust the cluster CA when pulling
#                        from the Gitea registry hostname.
#   RegistryAuthConfig — configures containerd with registry pull credentials.
#                        NOTE: due to a containerd v2 limitation this config is
#                        ignored at runtime when config_path is also set (which
#                        RegistryTLSConfig causes). Use Kubernetes imagePullSecrets
#                        on the default ServiceAccount as the reliable auth path.
#
# Flow:
#   1. Wait up to CLUSTER_CA_TRUST_TIMEOUT seconds for cert-manager-trust to
#      distribute the "cluster-ca-bundle" ConfigMap (key: ca.crt) in the
#      cert-manager namespace.
#   2. Fetch registry pull credentials from the gitea-registry-pull-credentials
#      Kubernetes Secret (created by gitea-bootstrap.sh).
#   3. For every control-plane and worker node, check whether a RegistryTLSConfig
#      for the Gitea hostname is already present on that node.
#   4. If it is missing (or --force is given), apply both documents together
#      with `talosctl apply-config --mode=no-reboot`.
#
# No node reboot is required — Talos restarts containerd automatically when
# registry configuration changes.
#
# Usage:
#   apply-node-registry-config.sh [--force] <config-file>
#
#   --force   Re-apply even if RegistryTLSConfig is already present on a node.
#
# Inputs from <config-file>:
#   TALOS_CONTROL_NODES  — array of control-plane node FQDNs
#   TALOS_WORKER_NODES   — array of worker node FQDNs (may be empty)
#   GITEA_DOMAIN_NAME    — hostname of the Gitea registry (e.g. gitea.example.com)
#
# Optional tunables (may be set in <config-file> or the environment):
#   CLUSTER_CA_TRUST_TIMEOUT    — seconds to wait for the CA bundle ConfigMap (default: 900)
#   CLUSTER_CA_BUNDLE_NAME      — ConfigMap name to poll  (default: cluster-ca-bundle)
#   CLUSTER_CA_BUNDLE_NS        — namespace of the ConfigMap (default: cert-manager)
#   CLUSTER_CA_BUNDLE_KEY       — key within the ConfigMap  (default: ca.crt)
#   REGISTRY_PULL_SECRET        — K8s secret name for registry pull credentials (default: gitea-registry-pull-credentials)
#   REGISTRY_PULL_SECRET_NS     — namespace of the registry pull secret (default: gitea)
#
# =============================================================================

set -euo pipefail

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

FORCE=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
  echo "Usage: $0 [--force] <config-file>"
  exit 1
fi

CONFIG_FILE="${POSITIONAL[0]}"
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE"
  exit 2
fi

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }

# shellcheck source=/dev/null
source "$CONFIG_FILE"

OVERLAY_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
RENDERED_DIR="$OVERLAY_DIR/_rendered"
export TALOSCONFIG="${TALOSCONFIG:-$OVERLAY_DIR/talos/talosconfig}"

# Tunables with defaults
readonly CA_TRUST_TIMEOUT="${CLUSTER_CA_TRUST_TIMEOUT:-900}"
readonly CA_BUNDLE_NAME="${CLUSTER_CA_BUNDLE_NAME:-cluster-ca-bundle}"
readonly CA_BUNDLE_NS="${CLUSTER_CA_BUNDLE_NS:-cert-manager}"
readonly CA_BUNDLE_KEY="${CLUSTER_CA_BUNDLE_KEY:-ca.crt}"
readonly REG_PULL_SECRET_NAME="${REGISTRY_PULL_SECRET:-gitea-registry-pull-credentials}"
readonly REG_PULL_SECRET_NS="${REGISTRY_PULL_SECRET_NS:-gitea}"

if [[ -z "${GITEA_DOMAIN_NAME:-}" ]]; then
  log_error "GITEA_DOMAIN_NAME must be set in the config file (e.g. gitea.example.com)"
  exit 2
fi
readonly REGISTRY_HOST="$GITEA_DOMAIN_NAME"

# ============================================================================
# COLLECT ALL NODES
# ============================================================================

ALL_NODES=("${TALOS_CONTROL_NODES[@]}")
if [[ "${#TALOS_WORKER_NODES[@]}" -gt 0 ]]; then
  ALL_NODES+=("${TALOS_WORKER_NODES[@]}")
fi

log_info "Nodes targeted for cluster-CA trust: ${ALL_NODES[*]}"

# ============================================================================
# STEP 1: WAIT FOR cluster-ca-bundle ConfigMap
# ============================================================================

log_info "Waiting for ConfigMap ${CA_BUNDLE_NS}/${CA_BUNDLE_NAME} (key: ${CA_BUNDLE_KEY}) ..."
log_info "Timeout: ${CA_TRUST_TIMEOUT}s"

WAIT_START=$(date +%s)
CA_CERT=""

while true; do
  set +e
  CA_CERT=$(kubectl get configmap "$CA_BUNDLE_NAME" \
    --namespace "$CA_BUNDLE_NS" \
    -o json 2>/dev/null \
    | jq -r --arg key "$CA_BUNDLE_KEY" '.data[$key] // empty')
  GET_STATUS=$?
  set -e

  if [[ $GET_STATUS -eq 0 && -n "$CA_CERT" ]]; then
    log_success "ConfigMap ${CA_BUNDLE_NS}/${CA_BUNDLE_NAME} is available."
    break
  fi

  ELAPSED=$(( $(date +%s) - WAIT_START ))
  if [[ $ELAPSED -ge $CA_TRUST_TIMEOUT ]]; then
    log_error "Timed out after ${CA_TRUST_TIMEOUT}s waiting for ConfigMap ${CA_BUNDLE_NS}/${CA_BUNDLE_NAME}."
    log_error "cert-manager-trust may not have synced yet, or cert-manager is not healthy."
    exit 3
  fi

  log_info "  ConfigMap not ready yet (${ELAPSED}s elapsed), retrying in 10s..."
  sleep 10
done

# ============================================================================
# STEP 2: FETCH REGISTRY PULL CREDENTIALS
# ============================================================================

log_info "Fetching registry pull credentials from ${REG_PULL_SECRET_NS}/${REG_PULL_SECRET_NAME} ..."

set +e
REGISTRY_PULL_USERNAME=$(kubectl get secret "$REG_PULL_SECRET_NAME" \
  --namespace "$REG_PULL_SECRET_NS" \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
REGISTRY_PULL_PASSWORD=$(kubectl get secret "$REG_PULL_SECRET_NAME" \
  --namespace "$REG_PULL_SECRET_NS" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
set -e

if [[ -z "$REGISTRY_PULL_USERNAME" || -z "$REGISTRY_PULL_PASSWORD" ]]; then
  log_error "Could not read registry pull credentials from ${REG_PULL_SECRET_NS}/${REG_PULL_SECRET_NAME}."
  log_error "Run gitea-bootstrap.sh first — it creates the '${REG_PULL_SECRET_NAME}' secret."
  exit 3
fi
log_success "Registry pull credentials available for user: ${REGISTRY_PULL_USERNAME}"

# ============================================================================
# STEP 3: BUILD DOCUMENTS AND APPLY TO EACH NODE
# ============================================================================

# Build the RegistryTLSConfig document once (shared across all nodes).
# kind: RegistryTLSConfig is a standalone Talos v1.12+ document — no full
# MachineConfig base required. The `ca` field takes raw PEM (not base64).
# Talos restarts containerd automatically when this config changes.
# Indent cert body by 4 spaces for the YAML block literal under `ca`.
INDENTED_CERT=$(echo "$CA_CERT" | sed 's/^/    /')
REGISTRY_TLS_DOC="$(cat <<EOF
apiVersion: v1alpha1
kind: RegistryTLSConfig
name: ${REGISTRY_HOST}
ca: |-
${INDENTED_CERT}
EOF
)"

# Build the RegistryAuthConfig document — configures containerd authentication
# for the Gitea registry so all nodes can pull images without imagePullSecrets.
REGISTRY_AUTH_DOC="$(cat <<EOF
apiVersion: v1alpha1
kind: RegistryAuthConfig
name: ${REGISTRY_HOST}
username: ${REGISTRY_PULL_USERNAME}
password: ${REGISTRY_PULL_PASSWORD}
EOF
)"

NEEDS_APPLY=()
ALREADY_PRESENT=()

for NODE in "${ALL_NODES[@]}"; do
  if [[ "$FORCE" == "true" ]]; then
    NEEDS_APPLY+=("$NODE")
    continue
  fi

  set +e
  EXISTING=$(talosctl get registrytlsconfigs \
    --nodes "$NODE" \
    --talosconfig "$TALOSCONFIG" \
    -o yaml 2>/dev/null)
  set -e

  if echo "$EXISTING" | grep -q "name: ${REGISTRY_HOST}"; then
    log_success "  Node $NODE: RegistryTLSConfig '${REGISTRY_HOST}' already present — skipping."
    ALREADY_PRESENT+=("$NODE")
  else
    log_info "  Node $NODE: RegistryTLSConfig '${REGISTRY_HOST}' missing — will apply."
    NEEDS_APPLY+=("$NODE")
  fi
done

if [[ ${#NEEDS_APPLY[@]} -eq 0 ]]; then
  log_success "All ${#ALL_NODES[@]} node(s) already have RegistryTLSConfig for ${REGISTRY_HOST}. Nothing to do."
  exit 0
fi

log_info "Applying RegistryTLSConfig + RegistryAuthConfig to ${#NEEDS_APPLY[@]} node(s): ${NEEDS_APPLY[*]}"

APPLY_TMPFILE=$(mktemp --suffix=.yaml)
# shellcheck disable=SC2064
trap "rm -f '$APPLY_TMPFILE'" EXIT

FAILED_NODES=()
for NODE in "${NEEDS_APPLY[@]}"; do
  NODE_HOSTNAME="${NODE%%.*}"

  # talosctl apply-config requires a MachineConfig (kind: MachineConfig) to be
  # present in the submitted file. Use the rendered per-node config as the base
  # and append the standalone RegistryTLSConfig as a second document.
  if [[ -f "$RENDERED_DIR/talos/controlplane-${NODE_HOSTNAME}.yaml" ]]; then
    NODE_BASE_CONFIG="$RENDERED_DIR/talos/controlplane-${NODE_HOSTNAME}.yaml"
  elif [[ -f "$RENDERED_DIR/talos/worker-${NODE_HOSTNAME}.yaml" ]]; then
    NODE_BASE_CONFIG="$RENDERED_DIR/talos/worker-${NODE_HOSTNAME}.yaml"
  else
    log_error "  Node $NODE: rendered config not found at $RENDERED_DIR/talos/{controlplane,worker}-${NODE_HOSTNAME}.yaml"
    FAILED_NODES+=("$NODE")
    continue
  fi

  { cat "$NODE_BASE_CONFIG"; printf '\n---\n'; echo "$REGISTRY_TLS_DOC"; printf '\n---\n'; echo "$REGISTRY_AUTH_DOC"; } > "$APPLY_TMPFILE"

  log_info "  Applying RegistryTLSConfig + RegistryAuthConfig for ${REGISTRY_HOST} to $NODE (base: $(basename "$NODE_BASE_CONFIG")) ..."
  set +e
  talosctl apply-config \
    --nodes "$NODE" \
    --talosconfig "$TALOSCONFIG" \
    --file "$APPLY_TMPFILE" \
    --mode no-reboot 2>&1
  APPLY_RC=$?
  set -e

  if [[ $APPLY_RC -eq 0 ]]; then
    log_success "  Node $NODE: RegistryTLSConfig + RegistryAuthConfig applied."
  else
    log_error "  Node $NODE: apply failed (exit $APPLY_RC)."
    FAILED_NODES+=("$NODE")
  fi
done

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
  log_error "Failed to apply cluster CA trust to ${#FAILED_NODES[@]} node(s): ${FAILED_NODES[*]}"
  exit 4
fi

log_success "Cluster registry config (TLS + auth) applied to all ${#NEEDS_APPLY[@]} node(s)."
if [[ ${#ALREADY_PRESENT[@]} -gt 0 ]]; then
  log_info "(${#ALREADY_PRESENT[@]} node(s) were already up-to-date: ${ALREADY_PRESENT[*]})"
fi
