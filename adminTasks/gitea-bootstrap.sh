#!/usr/bin/env zsh
set -euo pipefail

################################################################################
# gitea-bootstrap.sh
#
# Usage: gitea-bootstrap.sh <ENV_FILE> [--force-recreate-gitea-org] [--force-recreate-argocd-svc-user]
#
# This script bootstraps a freshly deployed Gitea instance by:
# 1. Waiting for Gitea to be ready
# 2. Fetching gitea admin credentials from Kubernetes secret
# 3. Creating a temporary admin access token
# 4. Creating an organization and repository (or force recreating if flag set)
# 5. Configuring git remote and pushing current repository to Gitea
#       A copy of the current repository is made in a temporary directory, all files are committed and pushed to Gitea
# 6. Creating ArgoCD service account user in Gitea (or force recreating if flag set)
# 7. Creating Kubernetes secret with ArgoCD service account credentials
# 8. Adding service account as read-only collaborator to repository
# 9. Creating access token for ArgoCD service account
# 10. Creating ArgoCD repo-creds secret for automatic repository access
#
# Requirements:
#   - kubectl
#   - curl
#   - jq
#   - git
#   - rsync
################################################################################

# Source library files
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"
source "$LIB_DIR/kubernetes.sh"





# Constants
readonly GITEA_ADMIN_SECRET="gitea-bootstrap-admin-secret" #Name of the secret in Gitea namespace holding admin credentials to be used by this script

#Argocd credentials for Gitea
## User account, password and secrets
readonly ARGOCD_SERVICE_ACCOUNT_USERNAME="argocd-cluster-services" #Username for the ArgoCD service account in Gitea
readonly ARGOCD_SERVICE_ACCOUNT_SECRET="gitea-argocd-cluster-services-credentials" #Name of the secret to hold ArgoCD service account credentials
readonly ARGOCD_SERVICE_ACCOUNT_SECRET_DESCRIPTION="Username and password for ArgoCD service account to access Gitea GUI. Not normally used, tokens should be setup for repo access"
## Token for access to cluster-services repo
readonly ARGOCD_REPO_CREDS_SECRET="gitea-argocd-cluster-services-repo-creds" #Name of the secret in ArgoCD namespace to hold repo credentials, used by ArgoApps
readonly ARGOCD_SERVICE_ACCOUNT_TOKEN_NAME="repo-read-token" #Name of the token to create for ArgoCD service account
readonly ARGOCD_SERVICE_ACCOUNT_REPO_SECRET_DESCRIPTION="Read-only token/ArgoRepo for ArgoCD service account to access cluster-services repositories"
readonly ARGOCD_SERVICE_TOKEN_SCOPES='["read:repository","read:organization","read:user","read:issue"]' #Scopes given to ArgoCD service account token
readonly CUSTOMERS_ARGOCD_SCM_SECRET="${CUSTOMERS_ARGOCD_SCM_SECRET:-gitea-argocd-customers-scm-token}" #k8s secret used by the customer-apps ApplicationSet SCM provider

# Registry pull service account — used by Talos RegistryAuthConfig so all cluster
# nodes can pull images from the Gitea container registry without imagePullSecrets.
# Must be added as an org member in every customer org (done by bootstrap-customer.sh).
readonly REGISTRY_PULL_USERNAME="registry-pull"
readonly REGISTRY_PULL_SECRET="gitea-registry-pull-credentials"  # K8s secret in GITEA_NAMESPACE
readonly REGISTRY_PULL_SECRET_DESCRIPTION="Read-only Gitea credentials for Talos RegistryAuthConfig — allows containerd on all nodes to pull images from the Gitea container registry"
readonly REGISTRY_PULL_PASSWORD_LENGTH=32

readonly ADMIN_TOKEN_SCOPES='["write:repository","write:organization","write:admin"]' #Scopes for the temporary admin token
readonly ARGOCD_SERVICE_PASSWORD_LENGTH=32
readonly GITEA_READY_MAX_RETRIES=60
readonly GITEA_READY_RETRY_INTERVAL=5
readonly GITEA_POD_READY_TIMEOUT="300s"

readonly TEMP_DIR_PREFIX="gitea-bootstrap" # Prefix for temporary git directory

# Usage message
usage() {
    cat <<EOF
Usage: $(basename "$0") <ENV_FILE> [--force-recreate-gitea-org] [--force-recreate-argocd-svc-user]

Arguments:
  ENV_FILE                         Path to the environment file (e.g. talos/overlays/yourCluster/yourCluster.env)
  --force-recreate-gitea-org       Delete and recreate organization and repository if they exist
  --force-recreate-argocd-svc-user Delete and recreate ArgoCD service account user and secrets

Requirements:
  - kubectl
  - curl
  - jq
  - git

Example:
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env --force-recreate-gitea-org
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env --force-recreate-argocd-svc-user
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env --force-recreate-gitea-org --force-recreate-argocd-svc-user
EOF
    exit 1
}

# Check required tools
check_dependencies() {
    local missing=()
    
    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl")
    fi
    
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi
    
    if ! command -v git &>/dev/null; then
        missing+=("git")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            log_error "  - $dep"
        done
        exit 1
    fi
}

# Load and export environment variables
load_env_file() {
    local env_file="$1"
    
    log_info "Loading environment from: $env_file"
    
    # Source the file with allexport to export all variables
    set -o allexport
    # shellcheck disable=SC1090
    source "$env_file"
    set +o allexport
    
    # Verify required variables were set
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        log_error "CLUSTER_NAME not set in environment file"
        exit 1
    fi
    
    if [[ -z "${GITEA_DOMAIN_NAME:-}" ]]; then
        log_error "GITEA_DOMAIN_NAME not set in environment file"
        exit 1
    fi
    
    log_success "Loaded environment for cluster: $CLUSTER_NAME"
}

# Global variables for cleanup
GITEA_TOKEN_ID=""
GITEA_CREDENTIALS=""
GITEA_API_URL=""
GIT_TEMP_DIR=""

# Cleanup function to delete token
cleanup_token() {
    if [[ -n "$GITEA_TOKEN_ID" && -n "$GITEA_CREDENTIALS" && -n "$GITEA_API_URL" ]]; then
        delete_gitea_token "$GITEA_CREDENTIALS" "$GITEA_TOKEN_ID" "$GITEA_API_URL"
    fi
}

# Cleanup function to restore git state
cleanup_git_state() {
    return ""
    #For now, we just delete the temp dir directly after use
    if [[ -n "$GIT_TEMP_DIR" ]] && [[ -d "$GIT_TEMP_DIR" ]]; then
        # Safety check: only delete if directory name starts with temp prefix
        local dir_basename=$(basename "$GIT_TEMP_DIR")
        if [[ "$dir_basename" == ${TEMP_DIR_PREFIX}* ]]; then
            log_info "Cleaning up temporary directory..."
            rm -rf "$GIT_TEMP_DIR"
            GIT_TEMP_DIR=""
            log_success "Temporary directory removed"
        else
            log_error "Error, was about to delete unexpected temp directory: $GIT_TEMP_DIR"
        fi
    fi
}



# Cleanup function to delete token and restore git state
cleanup_all() {
    cleanup_token
    cleanup_git_state
}

# Register cleanup trap
trap cleanup_all EXIT

################################################################################
# Main
################################################################################

main() {
    # Parse arguments
    if [[ $# -lt 1 ]]; then
        usage
    fi
    
    local env_file="$1"
    local force_recreate_gitea_org="false"
    local force_recreate_argocd_svc_user="false"
    
    # Parse optional flags
    shift  # Remove first argument (env_file)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force-recreate-gitea-org)
                force_recreate_gitea_org="true"
                log_warn "Force recreate gitea org mode enabled - will delete existing organization and repository"
                shift
                ;;
            --force-recreate-argocd-svc-user)
                force_recreate_argocd_svc_user="true"
                log_warn "Force recreate ArgoCD service user mode enabled - will delete existing user and secrets"
                shift
                ;;
            *)
                log_error "Invalid argument: $1"
                usage
                ;;
        esac
    done
    
    # Validate env file exists
    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        exit 1
    fi
    
    # Make env_file absolute if relative
    if [[ "$env_file" != /* ]]; then
        env_file="$PWD/$env_file"
    fi
    
    # Check dependencies
    check_dependencies
    
    # Load environment
    load_env_file "$env_file"
    
    # Determine directories
    export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    export OVERLAY_DIR="$(cd "$(dirname "$env_file")" && pwd)"
    
    # Setup kubectl config
    local talosconfig="$OVERLAY_DIR/talos/talosconfig"
    if [[ -f "$talosconfig" ]]; then
        export TALOSCONFIG="$talosconfig"
        log_info "Using Talos config: $TALOSCONFIG"
    fi
    
    # Ensure kubeconfig is set
    if [[ -z "${KUBECONFIG:-}" ]]; then
        export KUBECONFIG="$HOME/.kube/config"
    fi
    
    log_info "Script directory: $SCRIPT_DIR"
    log_info "Overlay directory: $OVERLAY_DIR"
    log_info "Kubeconfig: $KUBECONFIG"
    echo ""
    
    local gitea_api_url="https://${GITEA_DOMAIN_NAME}/api/v1"
    local repo_url="https://${GITEA_DOMAIN_NAME}/${GITEA_CLUSTER_GITEA_ORG_NAME}/${GITEA_CLUSTER_SERVICES_REPO_NAME}.git"
    local remote_name="gitea-${CLUSTER_NAME}"
    
    log_info "Organization name: $GITEA_CLUSTER_GITEA_ORG_NAME"
    log_info "Repository name: $GITEA_CLUSTER_SERVICES_REPO_NAME"
    log_info "Gitea API URL: $gitea_api_url"
    echo ""
    
    # Wait for Gitea
    if ! wait_for_gitea_ready "$GITEA_DOMAIN_NAME"; then
        exit 1
    fi
    echo ""



    
    # Fetch admin credentials
    local credentials
    if ! credentials=$(fetch_gitea_admin_credentials); then
        exit 1
    fi
    GITEA_CREDENTIALS="$credentials"
    echo ""
    
    # Create admin access token
    log_info "Creating temporary admin access token..."
    local token_name="bootstrap-token-$(date +%s)"
    local token_result
    if ! token_result=$(create_gitea_token "$credentials" "$gitea_api_url" "$token_name" "$ADMIN_TOKEN_SCOPES"); then
        exit 1
    fi

    
    # Parse token ID and token
    GITEA_TOKEN_ID="${token_result%%|*}"
    local token="${token_result#*|}"
    GITEA_API_URL="$gitea_api_url"
    echo ""

    ################################################################################
    #
    #       Create organization and repository
    #
    ################################################################################


    # Check and create organization
    log_info "Checking if organization exists: $GITEA_CLUSTER_GITEA_ORG_NAME"
    local org_status=$(check_gitea_organization "$GITEA_CLUSTER_GITEA_ORG_NAME" "$gitea_api_url" "$token")
    
    if [[ "$org_status" == "200" ]]; then
        if [[ "$force_recreate_gitea_org" == "true" ]]; then
            local repo_status=$(check_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token")
            if [[ "$repo_status" == "200" ]]; then
                if ! delete_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token"; then
                    log_error "Failed to delete repository, cannot proceed"
                    exit 1
                fi
            fi
            
            if ! delete_gitea_organization "$GITEA_CLUSTER_GITEA_ORG_NAME" "$gitea_api_url" "$token"; then
                exit 1
            fi
            
            if ! create_gitea_organization "$GITEA_CLUSTER_GITEA_ORG_NAME" "$gitea_api_url" "$token" "${CLUSTER_NAME} Cluster"; then
                exit 1
            fi
        else
            log_success "Organization already exists: $GITEA_CLUSTER_GITEA_ORG_NAME"
        fi
    elif [[ "$org_status" == "404" ]]; then
        if ! create_gitea_organization "$GITEA_CLUSTER_GITEA_ORG_NAME" "$gitea_api_url" "$token" "${CLUSTER_NAME} Cluster"; then
            exit 1
        fi
    else
        log_error "Unexpected HTTP status when checking organization: $org_status"
        exit 1
    fi
    echo ""
    
    # Check and create repository
    log_info "Checking if repository exists: $GITEA_CLUSTER_GITEA_ORG_NAME/$GITEA_CLUSTER_SERVICES_REPO_NAME"
    local repo_status=$(check_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token")
    
    if [[ "$repo_status" == "200" ]]; then
        if [[ "$force_recreate_gitea_org" == "true" ]]; then
            if ! delete_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token"; then
                exit 1
            fi
            
            if ! create_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token"; then
                exit 1
            fi
        else
            log_success "Repository already exists: $GITEA_CLUSTER_GITEA_ORG_NAME/$GITEA_CLUSTER_SERVICES_REPO_NAME"
        fi
    elif [[ "$repo_status" == "404" ]]; then
        if ! create_gitea_repository "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$gitea_api_url" "$token"; then
            exit 1
        fi
    else
        log_error "Unexpected HTTP status when checking repository: $repo_status"
        exit 1
    fi
    echo ""
    


    ################################################################################
    #
    #       Create temporary copy of CWD and push all current files to Gitea
    #
    ################################################################################

    # Push repository to Gitea with working state
    if ! push_to_gitea_cluster_services "$credentials" --push-working-state --destination-branch main; then
        exit 1
    fi
    echo ""


    ################################################################################
    #
    #       Create ArgoCD service account and configure credentials
    #
    ################################################################################
    
    # Force delete ArgoCD service account resources if requested
    if [[ "$force_recreate_argocd_svc_user" == "true" ]]; then
        log_warn "Force recreate enabled - deleting ArgoCD service account resources..."
        
        # Delete Gitea user (ignore errors)
        log_info "Deleting Gitea user: $ARGOCD_SERVICE_ACCOUNT_USERNAME"
        curl -k -s -S -o /dev/null -X DELETE \
            -H "Authorization: token $token" \
            "$gitea_api_url/admin/users/$ARGOCD_SERVICE_ACCOUNT_USERNAME" 2>/dev/null || true
        
        # Delete ArgoCD service account credentials secret (ignore errors)
        log_info "Deleting secret: $ARGOCD_NAMESPACE/$ARGOCD_SERVICE_ACCOUNT_SECRET"
        kubectl delete secret "$ARGOCD_SERVICE_ACCOUNT_SECRET" -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
        
        # Delete ArgoCD repo-creds secret (ignore errors)
        log_info "Deleting secret: $ARGOCD_NAMESPACE/$ARGOCD_REPO_CREDS_SECRET"
        kubectl delete secret "$ARGOCD_REPO_CREDS_SECRET" -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
        
        log_success "ArgoCD service account resources deleted"
        echo ""
    fi
    
    # Create ArgoCD service account and configure credentials
    log_info "Setting up ArgoCD service account..."
    local argocd_service_account_email="${ARGOCD_SERVICE_ACCOUNT_USERNAME}@${GITEA_DOMAIN_NAME}"
    
    # Generate password for service account
    local argocd_password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c "$ARGOCD_SERVICE_PASSWORD_LENGTH")
    
    # Create user in Gitea
    if ! create_gitea_user "$ARGOCD_SERVICE_ACCOUNT_USERNAME" "$argocd_service_account_email" "$gitea_api_url" "$token" "$argocd_password"; then
        log_error "Failed to create ArgoCD service account user"
        exit 1
    fi
    
    # Ensure credentials secret exists and get credentials
    local argocd_service_account_credentials
    if ! argocd_service_account_credentials=$(ensure_credentials_secret "$ARGOCD_SERVICE_ACCOUNT_USERNAME" "$argocd_password" "$ARGOCD_SERVICE_ACCOUNT_SECRET" "$ARGOCD_NAMESPACE" "$ARGOCD_SERVICE_ACCOUNT_SECRET_DESCRIPTION"); then
        log_error "Failed to ensure ArgoCD service account credentials secret"
        exit 1
    fi
    echo ""
    
    # Add service account as collaborator
    if ! add_gitea_repo_collaborator "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$ARGOCD_SERVICE_ACCOUNT_USERNAME" "read" "$gitea_api_url" "$token"; then
        log_error "Failed to add ArgoCD service account as collaborator"
        exit 1
    fi
    echo ""
    
    # Setup ArgoCD webhook
    log_info "Setting up ArgoCD webhook..."
    local argocd_webhook_url="https://argocd.${CLUSTER_EXTERNAL_DOMAIN}/api/webhook"
    local webhook_status
    
    if ! webhook_status=$(check_gitea_webhook "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$argocd_webhook_url" "$gitea_api_url" "$token"); then
        log_error "Failed to check webhook status"
        exit 1
    fi
    
    if [[ "$webhook_status" == "MISSING" ]]; then
        if ! create_gitea_webhook "$GITEA_CLUSTER_GITEA_ORG_NAME" "$GITEA_CLUSTER_SERVICES_REPO_NAME" "$argocd_webhook_url" "$gitea_api_url" "$token"; then
            log_error "Failed to create webhook"
            exit 1
        fi
    fi
    echo ""
    
    # Create or get token for service account
    local argocd_token_result
    argocd_token_result=$(create_gitea_token "$argocd_service_account_credentials" "$gitea_api_url" "$ARGOCD_SERVICE_ACCOUNT_TOKEN_NAME" "$ARGOCD_SERVICE_TOKEN_SCOPES" "true")
    
    if [[ "$argocd_token_result" == "TOKEN_ALREADY_EXISTS" ]]; then
        log_warn "Token already exists - cannot retrieve existing token value"
        log_info "Skipping repo-creds secret creation"
        log_info "To recreate: delete the existing token in Gitea, then re-run this script"
    fi
    echo ""
    
    # Create ArgoCD repo-creds secret
    if [[ "$argocd_token_result" != "TOKEN_ALREADY_EXISTS" ]]; then
        # Extract just the token value (ignore token_id)
        local argocd_service_account_token="${argocd_token_result#*|}"
        
        if ! create_argocd_repo_creds_secret "https://${GITEA_DOMAIN_NAME}" "$ARGOCD_SERVICE_ACCOUNT_USERNAME" "$argocd_service_account_token" "$ARGOCD_SERVICE_ACCOUNT_TOKEN_NAME" "$ARGOCD_SERVICE_ACCOUNT_REPO_SECRET_DESCRIPTION"; then
            log_error "Failed to create ArgoCD repo-creds secret"
            exit 1
        fi

        # Also store the same token in a separate secret used by the customer-apps
        # ApplicationSet SCM provider (tokenRef expects key "token", not username/password).
        local scm_secret="${CUSTOMERS_ARGOCD_SCM_SECRET:-gitea-argocd-customers-scm-token}"
        if kubectl get secret "$scm_secret" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
            log_success "ApplicationSet SCM token secret already exists: $ARGOCD_NAMESPACE/$scm_secret"
        else
            log_info "Creating ApplicationSet SCM token secret: $ARGOCD_NAMESPACE/$scm_secret"
            kubectl create secret generic "$scm_secret" \
                --namespace "$ARGOCD_NAMESPACE" \
                --from-literal=token="$argocd_service_account_token"
            log_success "ApplicationSet SCM token secret created: $ARGOCD_NAMESPACE/$scm_secret"
        fi
    fi
    echo ""
        ################################################################################
    #
    #       Create registry-pull service account for Talos RegistryAuthConfig
    #
    ################################################################################

    log_info "Setting up Gitea registry-pull service account..."
    local registry_pull_email="${REGISTRY_PULL_USERNAME}@${GITEA_DOMAIN_NAME}"
    local registry_pull_password
    registry_pull_password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c "$REGISTRY_PULL_PASSWORD_LENGTH")

    if ! create_gitea_user "$REGISTRY_PULL_USERNAME" "$registry_pull_email" "$gitea_api_url" "$token" "$registry_pull_password"; then
        log_error "Failed to create registry-pull user"
        exit 1
    fi

    # Store credentials in the gitea namespace so apply-node-registry-config.sh can
    # read them when applying RegistryAuthConfig to all Talos nodes.
    if ! ensure_credentials_secret "$REGISTRY_PULL_USERNAME" "$registry_pull_password" "$REGISTRY_PULL_SECRET" "$GITEA_NAMESPACE" "$REGISTRY_PULL_SECRET_DESCRIPTION"; then
        log_error "Failed to ensure registry-pull credentials secret"
        exit 1
    fi
    log_success "Registry-pull service account ready: $GITEA_NAMESPACE/$REGISTRY_PULL_SECRET"
    echo ""
    # Summary
    log_success \"Gitea bootstrap complete!\"
    log_info \"Organization: $GITEA_CLUSTER_GITEA_ORG_NAME\"
    log_info \"Repository: $GITEA_CLUSTER_GITEA_ORG_NAME/$GITEA_CLUSTER_SERVICES_REPO_NAME\"
    log_info \"Repository URL: $repo_url\"
    log_info \"Git remote: $remote_name\"
    log_info \"ArgoCD service account: $ARGOCD_SERVICE_ACCOUNT_USERNAME\"
    log_info \"ArgoCD repo-creds secret: $ARGOCD_REPO_CREDS_SECRET \(${ARGOCD_NAMESPACE} namespace\)\"
    log_info \"Repository has been pushed to Gitea\"
    log_info \"Local repository state has been restored\"
    log_info \"ArgoCD is now configured to access Gitea repositories\"
}

main "$@"
