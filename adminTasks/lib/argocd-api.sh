#!/usr/bin/env zsh
# ArgoCD API utilities

# Source dependencies
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
#[[ -z "${LOGGING_LOADED:-}" ]] && source "$SCRIPT_LIB_DIR/logging.sh"
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }

# Constants used by this library
# ARGOCD_NAMESPACE should be defined in the env file loaded by main script
: ${ARGOCD_ADMIN_SECRET:=argocd-initial-admin-secret}
: ${ARGOCD_SERVER_LABELS:="app.kubernetes.io/component=server,app.kubernetes.io/instance=argocd"}
: ${ARGOCD_READY_MAX_RETRIES:=60}
: ${ARGOCD_READY_RETRY_INTERVAL:=5}

# Get the ArgoCD server pod name
# Returns: pod name on success, exits with error on failure
get_argocd_server_pod() {
    log_info "Finding ArgoCD server pod in namespace: $ARGOCD_NAMESPACE"
    
    if [[ -z "$ARGOCD_NAMESPACE" ]]; then
        log_error "ARGOCD_NAMESPACE environment variable is not set"
        exit 1
    fi
    
    local pod_name=$(kubectl get pod -n "$ARGOCD_NAMESPACE" \
        -l "$ARGOCD_SERVER_LABELS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$pod_name" ]]; then
        log_error "ArgoCD server pod not found in namespace $ARGOCD_NAMESPACE with labels: $ARGOCD_SERVER_LABELS"
        exit 1
    fi
    
    log_info "Found ArgoCD server pod: $pod_name"
    echo "$pod_name"
}

# Execute a command in the ArgoCD server pod
# Args: command to execute
# Returns: command output
exec_in_argocd_pod() {
    local command="$1"
    local pod_name
    
    pod_name=$(get_argocd_server_pod)
    
    kubectl exec -n "$ARGOCD_NAMESPACE" "$pod_name" -- sh -c "$command"
}

# Fetch ArgoCD admin password from secret
# Args: $1 - secret name (optional, defaults to ARGOCD_ADMIN_SECRET)
# Returns: password on success, exits with error on failure
fetch_argocd_admin_password() {
    local secret_name="${1:-$ARGOCD_ADMIN_SECRET}"
    
    log_info "Fetching ArgoCD admin password from secret: $ARGOCD_NAMESPACE/$secret_name"
    
    if [[ -z "$ARGOCD_NAMESPACE" ]]; then
        log_error "ARGOCD_NAMESPACE environment variable is not set"
        exit 1
    fi
    
    if ! kubectl get secret "$secret_name" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_error "Secret $secret_name not found in namespace $ARGOCD_NAMESPACE"
        exit 1
    fi
    
    local password=$(kubectl get secret "$secret_name" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    
    if [[ -z "$password" ]]; then
        log_error "Failed to extract password from secret $secret_name"
        exit 1
    fi
    
    log_success "Admin password retrieved"
    echo "$password"
}

# Login to ArgoCD inside the server pod
# Args: $1 - admin password
# Returns: 0 on success, exits with error on failure
argocd_login_in_pod() {
    local password="$1"
    
    if [[ -z "$password" ]]; then
        log_error "Password is required for ArgoCD login"
        exit 1
    fi
    
    log_info "Logging into ArgoCD at localhost:8080..."
    
    # Login using argocd CLI inside the pod
    # Using --insecure since we're connecting to localhost
    local login_output
    if ! login_output=$(exec_in_argocd_pod "argocd login localhost:8080 --insecure --username admin --password '$password' 2>&1"); then
        log_error "Failed to login to ArgoCD"
        log_error "Output: $login_output"
        exit 1
    fi
    
    log_success "Successfully logged into ArgoCD"
    return 0
}

# Logout from ArgoCD inside the server pod
# Returns: 0 on success
argocd_logout_in_pod() {
    log_info "Logging out from ArgoCD..."
    
    # Logout - don't fail if it errors
    exec_in_argocd_pod "argocd logout localhost:8080 2>&1" >/dev/null || true
    
    log_success "Logged out from ArgoCD"
    return 0
}

# List all ArgoCD applications
# Returns: newline-separated list of app names
list_argocd_apps() {
    log_info "Listing all ArgoCD applications..."
    
    local apps_output
    if ! apps_output=$(exec_in_argocd_pod "argocd app list -o name 2>&1"); then
        log_error "Failed to list ArgoCD applications"
        log_error "Output: $apps_output"
        exit 1
    fi
    
    # Filter out empty lines
    local apps=$(echo "$apps_output" | grep -v '^$')
    local app_count=$(echo "$apps" | wc -l | tr -d ' ')
    
    log_success "Found $app_count ArgoCD application(s)"
    echo "$apps"
}

# Refresh a single ArgoCD application
# Args: $1 - application name
# Returns: 0 on success, exits with error on failure
refresh_argocd_app() {
    local app_name="$1"
    
    if [[ -z "$app_name" ]]; then
        log_error "Application name is required for refresh"
        exit 1
    fi
    
    log_info "Refreshing ArgoCD application: $app_name"
    
    local refresh_output
    if ! refresh_output=$(exec_in_argocd_pod "argocd app get '$app_name' --refresh 2>&1"); then
        log_error "Failed to refresh application: $app_name"
        log_error "Output: $refresh_output"
        exit 1
    fi
    
    log_success "Successfully refreshed application: $app_name"
    return 0
}

# Refresh all ArgoCD applications
# Returns: 0 on success, exits with error on failure
refresh_all_argocd_apps() {
    local secret_name="${1:-$ARGOCD_ADMIN_SECRET}"
    
    log_info "Starting ArgoCD application refresh process..."
    
    # Fetch credentials
    local password
    password=$(fetch_argocd_admin_password "$secret_name")
    
    # Login
    argocd_login_in_pod "$password"
    
    # Get list of applications
    local apps
    apps=$(list_argocd_apps)
    
    if [[ -z "$apps" ]]; then
        log_warn "No ArgoCD applications found to refresh"
        argocd_logout_in_pod
        return 0
    fi
    
    # Refresh applications in parallel batches of 5
    local batch_size=5
    local success_count=0
    local total_count=0
    local batch=()
    local pids=()
    
    # Collect app names into an array
    local app_list=()
    while IFS= read -r app_name; do
        [[ -z "$app_name" ]] && continue
        app_list+=("$app_name")
    done <<< "$apps"
    
    total_count=${#app_list[@]}
    log_info "Refreshing $total_count application(s) in batches of $batch_size..."
    
    for ((i=0; i<total_count; i++)); do
        batch+=("${app_list[$i]}")
        
        # When batch is full or we've reached the last app, process the batch
        if (( ${#batch[@]} == batch_size || i == total_count - 1 )); then
            pids=()
            
            for app_name in "${batch[@]}"; do
                refresh_argocd_app "$app_name" &
                pids+=($!)
            done
            
            # Wait for all jobs in this batch and count successes
            for pid in "${pids[@]}"; do
                if wait "$pid"; then
                    success_count=$((success_count + 1))
                fi
            done
            
            batch=()
        fi
    done
    
    # Logout
    argocd_logout_in_pod
    
    log_success "Refreshed $success_count out of $total_count ArgoCD application(s)"
    return 0
}

readonly ARGOCD_API_LOADED=1
