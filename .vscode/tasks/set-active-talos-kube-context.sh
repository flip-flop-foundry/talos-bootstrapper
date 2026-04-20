#!/usr/bin/env bash
set -euo pipefail

env_file="${1:?env file path is required}"
workspace_dir="${2:-$(pwd)}"

# Resolve env_file to an absolute path so it works regardless of how it was passed
[[ "$env_file" = /* ]] || env_file="$workspace_dir/$env_file"

overlay_dir=$(dirname "$env_file")
active_dir="$workspace_dir/.vscode/current"

log_info() {
  echo "[set-active-context] $*"
}

log_warn() {
  echo "WARN: $*"
}

# Load optional overlay vars used for ArgoCD CLI setup.
# shellcheck disable=SC1090
source "$env_file"

mkdir -p "$active_dir"
ln -sfn "$overlay_dir/talos/talosconfig" "$active_dir/talosconfig"

first_node=$(yq -r '.contexts[].nodes[0]' "$active_dir/talosconfig" | head -n1)
if [ -z "$first_node" ] || [ "$first_node" = "null" ]; then
  echo "ERROR: Could not determine first Talos node from $active_dir/talosconfig" >&2
  exit 1
fi

talosctl --talosconfig "$active_dir/talosconfig" kubeconfig "$active_dir/kubeconfig" --nodes "$first_node" --merge

argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
argocd_domain="${ARGOCD_DOMAIN:-}"
cluster_name="${CLUSTER_NAME:-cluster}"
ca_bundle_namespace="cert-manager"
ca_bundle_name="cluster-ca-bundle"
ca_bundle_key='ca\.crt'
ca_cert_target="/usr/local/share/ca-certificates/${cluster_name}-cluster-ca.crt"

# Best-effort ArgoCD CLI setup. Failures here should not block context setup.
if ! command -v argocd >/dev/null 2>&1; then
  log_warn "argocd binary not found; skipping ArgoCD CLI setup."
elif [ -z "$argocd_domain" ]; then
  log_warn "ARGOCD_DOMAIN is not set in $env_file; skipping ArgoCD CLI setup."
elif ! kubectl --kubeconfig "$active_dir/kubeconfig" get namespace "$argocd_namespace" >/dev/null 2>&1; then
  log_warn "ArgoCD namespace '$argocd_namespace' not found; skipping ArgoCD CLI setup."o
elif ! kubectl --kubeconfig "$active_dir/kubeconfig" -n "$argocd_namespace" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  log_warn "Secret '$argocd_namespace/argocd-initial-admin-secret' not found; skipping ArgoCD CLI setup."
else
  log_info "Preparing local trust store CA file: $ca_cert_target"
  cluster_ca=$(kubectl --kubeconfig "$active_dir/kubeconfig" -n "$ca_bundle_namespace" get configmap "$ca_bundle_name" -o jsonpath="{.data.${ca_bundle_key}}" 2>/dev/null || true)
  if [ -z "$cluster_ca" ]; then
    log_warn "Could not read ${ca_bundle_namespace}/${ca_bundle_name} key ca.crt; ArgoCD TLS trust may fail."
  elif ! command -v sudo >/dev/null 2>&1; then
    log_warn "sudo is not available; cannot install cluster CA into system trust store."
  else
    printf '%s\n' "$cluster_ca" | sudo tee "$ca_cert_target" >/dev/null
    if sudo update-ca-certificates >/dev/null 2>&1; then
      log_info "Installed cluster CA into system trust store: $ca_cert_target"
    else
      log_warn "Failed to refresh system trust store with $ca_cert_target"
    fi
  fi

  log_info "Fetching ArgoCD admin password from secret $argocd_namespace/argocd-initial-admin-secret"
  argocd_password=$(kubectl --kubeconfig "$active_dir/kubeconfig" -n "$argocd_namespace" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$argocd_password" ]; then
    log_warn "Could not extract ArgoCD admin password; skipping ArgoCD CLI setup."
  else
    # Remove any previous auth entry for this server so login stays non-interactive.
    argocd logout "$argocd_domain" >/dev/null 2>&1 || true
    if timeout 25s argocd login "$argocd_domain" --username admin --password "$argocd_password" --prompts-enabled=false >/dev/null 2>&1; then
      log_info "ArgoCD CLI configured for: $argocd_domain"
    else
      log_warn "ArgoCD CLI setup failed for '$argocd_domain'. Talos/Kube context is still configured."
    fi
  fi
fi

echo "Active TALOSCONFIG: $active_dir/talosconfig"
echo "Active KUBECONFIG: $active_dir/kubeconfig"
echo "Selected node: $first_node"
echo "Open a new terminal to pick up updated env vars."
