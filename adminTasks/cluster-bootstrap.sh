#!/bin/bash

##############################################################################
# cluster-bootstrap.sh
#
# Bootstraps a Talos cluster with ArgoCD and Gitea for GitOps-based management
# Handles both initial cluster setup and subsequent re-bootstrapping
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
# ENVIRONMENT SETUP AND VARIABLE EXPORTS
# ============================================================================

#Build whitelist of all exported variables
#This is needed to avoid envsubst replacing variables that are not defined in the environment, but are present in the manifests/charts
export ENVSUBST_VARS=$(env | cut -d= -f1 | sed 's/^/\$/' | paste -sd: -)


export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OVERLAY_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
export RENDERED_OVERLAY_DIR="$(cd "$OVERLAY_DIR/../../rendered/$OVERLAY_NAME" && pwd)"
export BASE_DIR="$(cd "$OVERLAY_DIR/../../base" && pwd)"
export TALOSCONFIG=$OVERLAY_DIR/talos/talosconfig
export GIT_ROOT="$(git -C "$OVERLAY_DIR" rev-parse --show-toplevel)"
export LIB_DIR="$SCRIPT_DIR/lib"

export NR_OF_CONTROL_NODES=${#TALOS_CONTROL_NODES[@]}


# ============================================================================
# LOAD LIBRARIES
# ============================================================================

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"
source "$LIB_DIR/argocd-api.sh"



log_info "Using Script Directory:  $SCRIPT_DIR"
log_info "Using Base Directory: $BASE_DIR"
log_info "Using Overlay Directory: $OVERLAY_DIR"
log_info "Using Rendered Overlay Directory: $RENDERED_OVERLAY_DIR"
log_info "Using Talos config file: $TALOSCONFIG"
log_info "Using Git root directory: $GIT_ROOT"
log_info "Using Library Directory: $LIB_DIR"

# ============================================================================
# GITEA BOOTSTRAP STATUS CHECK
# ============================================================================

if check_gitea_bootstrap_status; then
    GITEA_ALREADY_BOOTSTRAPPED=true
   log_info "Gitea already bootstrapped, proceeding with normal settings."
else
    GITEA_ALREADY_BOOTSTRAPPED=false
    log_info "Gitea not yet bootstrapped, will use temporary git-bootstrap-server for bootstrapping."
fi

# ============================================================================
# KUBERNETES ACCESS SETUP
# ============================================================================

cd "$OVERLAY_DIR" || exit 1

log_info "Setting up kubeconfig for kubectl and helm..."
talosctl kubeconfig --merge --force --nodes "${TALOS_CONTROL_NODES[0]}" ~/.kube/config
export KUBECONFIG="$(cd ~/.kube && pwd)/config"

# ============================================================================
# HELM REPOSITORY SETUP
# ============================================================================

# Check if the helm repo https://helm.cilium.io/ has been added, if not add it
if ! helm repo list | grep -q "cilium"; then
  log_info "Adding Cilium Helm repository..."
  helm repo add cilium https://helm.cilium.io/
  helm repo update
else
  log_info "Cilium Helm repository already exists, skipping addition."
fi

if ! helm repo list | grep -q "argo"; then
  log_info "Adding Argo Helm repository..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update
else
  log_info "Argo Helm repository already exists, skipping addition."
fi

# ============================================================================
# RENDER OVERLAY MANIFESTS
# ============================================================================

if [[ "$GITEA_ALREADY_BOOTSTRAPPED" == "false" ]]; then
    log_info "Gitea not yet bootstrapped, replacing GITEA_CLUSTER_SERVICES_REPO_URL with git-bootstrap-server URL for rendering."

    # Temporarily override GITEA_CLUSTER_SERVICES_REPO_URL to point to the git-bootstrap-server
    OVERRIDE_GITEA_CLUSTER_SERVICES_REPO_URL="git://git-bootstrap-server:8080/git/repo.git"
    OVERRIDE_GITEA_CLUSTER_SERVICES_BRANCH_NAME="argo-cd-bootstrap"

    log_info "Rendering overlay manifests..."
    "$SCRIPT_DIR/render-overlay.sh" "$CONFIG_FILE" "GITEA_CLUSTER_SERVICES_REPO_URL=$OVERRIDE_GITEA_CLUSTER_SERVICES_REPO_URL" "GITEA_CLUSTER_SERVICES_REPO_BRANCH=$OVERRIDE_GITEA_CLUSTER_SERVICES_BRANCH_NAME"

else
    log_info "Gitea already bootstrapped, proceeding with normal settings."
fi



# ============================================================================
# CILIUM INSTALLATION
# ============================================================================

#Cilium is applied as template and service side, so that ArgoCD can take over management later

if kubectl get daemonset cilium -n kube-system &>/dev/null; then
  log_info "Cilium installed, skipping installation."
  # After initial install, ArgoCD will manage Cilium
else

  log_info "Installing Cilium with Helm..."
  helm template \
    cilium \
    cilium/cilium \
    --version "$CILIUM_HELM_VERSION" \
    --namespace kube-system \
    --values "$RENDERED_OVERLAY_DIR/cilium/ciliumHelmValues.yaml" \
    --set hubble.tls.enabled="false" \
     | kubectl apply --server-side -f -
    

  cilium status --wait

  log_success "Finished installing Cilium"
fi

# ============================================================================
# ARGOCD INSTALLATION
# ============================================================================

if kubectl get deployment argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  log_info "ArgoCD installed, skipping installation."
  # After initial install, ArgoCD will manage Cilium
else

  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${ARGOCD_NAMESPACE}" reloader-enabled=true --overwrite

  log_info "Installing/Upgrading ArgoCD with simplified values for bootstrapping..."
  helm upgrade argocd argo/argo-cd \
    --install \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --version "$ARGOCD_HELM_VERSION" \
    --wait \
    --values "$RENDERED_OVERLAY_DIR/argocd/argocdHelmBootstrapValues.yaml"

  log_success "Finished installing ArgoCD for bootstrapping"

fi

# ============================================================================
# BOOTSTRAP GIT SERVER (IF GITEA NOT YET BOOTSTRAPPED)
# ============================================================================

if [[ "$GITEA_ALREADY_BOOTSTRAPPED" == "false" ]]; then
  # Sets up a temporary git server in the cluster to bootstrap ArgoCD with the initial manifests

  if kubectl get pod git-bootstrap-server -n argocd &>/dev/null; then
      log_info "Deleting existing git-bootstrap-server pod..."
      kubectl delete pod git-bootstrap-server -n argocd
  fi


  envsubst "$ENVSUBST_VARS" <  "$BASE_DIR/argocd/bootstrap/bootstrapGitServer.yaml" | kubectl apply -f - || {
        log_error "Failed to apply git-bootstrap-server manifest"
        exit 1
      }

  #kubectl apply -f "$BASE_DIR/argocd/bootstrap/bootstrapGitServer.yaml"
  kubectl wait --for=condition=Ready pod/git-bootstrap-server -n argocd

  # Copy git repo to git-bootstrap-server pod
  log_info "Copying git repo to git-bootstrap-server pod"
  kubectl cp "$GIT_ROOT/." "argocd/git-bootstrap-server:/tmp/gitsrc"
  kubectl cp "$BASE_DIR/argocd/bootstrap/commitAndPush.sh" "argocd/git-bootstrap-server:/tmp/commitAndPush.sh"
  kubectl exec -n argocd git-bootstrap-server -- chmod +x /tmp/commitAndPush.sh
  kubectl exec -n argocd git-bootstrap-server -- /tmp/commitAndPush.sh


  # ==========================================================================
  # DEPLOY INITIAL MANIFESTS
  # ==========================================================================

  log_info "Deploying manifests with initial-deploy-with-kubectl label..."

  # First, deploy all manifests with the initial-deploy-with-kubectl label
  for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
    # Skip if no files found (glob didn't match)
    [[ -e "$manifest" ]] || continue
    
    # Extract and apply only objects with the initial-deploy-with-kubectl label
    if ! filtered_output=$(yq eval 'select(.metadata.labels."initial-deploy-with-kubectl" == "true")' "$manifest" 2>&1); then
      log_warn "  yq failed to process $(basename "$manifest"), skipping..."
      continue
    fi
    
    if [[ -n "$filtered_output" ]]; then
      log_info "  Applying objects from: $(basename "$manifest")"
      echo "$filtered_output" | kubectl apply -f - || {
        log_error "Failed to apply objects from $(basename "$manifest")"
        exit 1
      }
    fi
  done


  # ==========================================================================
  # DEPLOY ARGOCD APPLICATIONS
  # ==========================================================================

  log_info "Deploying ArgoCD applications from rendered overlay..."

  # Then, deploy all ArgoCD Application manifests
  for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
    # Skip if no files found (glob didn't match)
    [[ -e "$manifest" ]] || continue
    
    # Extract and apply ArgoCD Application objects
    if ! filtered_output=$(yq eval 'select(.kind == "Application" and .apiVersion == "argoproj.io/v1alpha1")' "$manifest" 2>&1); then
      log_warn "  yq failed to process $(basename "$manifest"), skipping..."
      continue
    fi
    
    if [[ -n "$filtered_output" ]]; then
      log_info "  Applying ArgoCD app from: $(basename "$manifest")"
      echo "$filtered_output" | kubectl apply -f - || {
        log_error "Failed to apply ArgoCD app from $(basename "$manifest")"
        exit 1
      }
    fi
  done

  log_success "Finished deploying initial manifests and ArgoCD applications"


  log_info "Refreshing all ArgoCD applications to sync with git-bootstrap-server..."
  refresh_all_argocd_apps


  # ==========================================================================
  # GITEA BOOTSTRAP
  # ==========================================================================

  log_info "Starting bootstrap of Gitea"

  "$SCRIPT_DIR/gitea-bootstrap.sh" "$CONFIG_FILE"

  gitea_bootstrap_status=$?
  if [ $gitea_bootstrap_status -ne 0 ]; then
      log_error "Gitea bootstrap failed with status $gitea_bootstrap_status"
      exit $gitea_bootstrap_status
  fi


fi

# ============================================================================
# FINAL RENDERING AND ARGOCD UPDATE
# ============================================================================

log_info "Gitea has now been bootstrapped, rendering with normal settings."
log_info "Rendering overlay manifests..."
"$SCRIPT_DIR/render-overlay.sh" "$CONFIG_FILE"



log_info "Installing/Upgrading ArgoCD with Helm with final values..."
helm upgrade argocd argo/argo-cd \
  --install \
  --namespace "argocd" \
  --create-namespace \
  --version "$ARGOCD_HELM_VERSION" \
  --wait \
  --values "$RENDERED_OVERLAY_DIR/argocd/argocdHelmValues.yaml"

# ============================================================================
# PUSH TO GITEA AND FINAL DEPLOYMENT
# ============================================================================

giteaAdminCredentials=$(fetch_gitea_admin_credentials)


push_to_gitea_cluster_services "$giteaAdminCredentials" --push-working-state --destination-branch main

# ============================================================================
# DEPLOY FINAL MANIFESTS
# ============================================================================

log_info "Deploying manifests with initial-deploy-with-kubectl label..."

# First, deploy all manifests with the initial-deploy-with-kubectl label
for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
  # Skip if no files found (glob didn't match)
  [[ -e "$manifest" ]] || continue
  
  # Extract and apply only objects with the initial-deploy-with-kubectl label
  if ! filtered_output=$(yq eval 'select(.metadata.labels."initial-deploy-with-kubectl" == "true")' "$manifest" 2>&1); then
    log_warn "  yq failed to process $(basename "$manifest"), skipping..."
    continue
  fi
  
  if [[ -n "$filtered_output" ]]; then
    log_info "  Applying objects from: $(basename "$manifest")"
    echo "$filtered_output" | kubectl apply -f - || {
      log_error "Failed to apply objects from $(basename "$manifest")"
      exit 1
    }
  fi
done

# ============================================================================
# DEPLOY FINAL ARGOCD APPLICATIONS
# ============================================================================

log_info "Deploying ArgoCD applications from rendered overlay..."

# Then, deploy all ArgoCD Application manifests
for manifest in "$RENDERED_OVERLAY_DIR"/*/*.yaml; do
  # Skip if no files found (glob didn't match)
  [[ -e "$manifest" ]] || continue
  
  # Extract and apply ArgoCD Application objects
  if ! filtered_output=$(yq eval 'select(.kind == "Application" and .apiVersion == "argoproj.io/v1alpha1")' "$manifest" 2>&1); then
    log_warn "  yq failed to process $(basename "$manifest"), skipping..."
    continue
  fi
  
  if [[ -n "$filtered_output" ]]; then
    log_info "  Applying ArgoCD app from: $(basename "$manifest")"
    echo "$filtered_output" | kubectl apply -f - || {
      log_error "Failed to apply ArgoCD app from $(basename "$manifest")"
      exit 1
    }
  fi
done

# ============================================================================
# CLEANUP
# ============================================================================

if kubectl get pod git-bootstrap-server -n argocd &>/dev/null; then
  log_info "Deleting git-bootstrap-server pod..."
  kubectl delete pod git-bootstrap-server -n argocd
fi

log_success "Finished deploying initial manifests and ArgoCD applications"