#!/usr/bin/env zsh
# Kubernetes utilities

# Source dependencies
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }
# Constants used by this library (should be defined in main script)
: ${ARGOCD_NAMESPACE:=argocd}
: ${ARGOCD_REPO_CREDS_SECRET:=gitea-repo-creds}

# Get or create secret with credentials
ensure_credentials_secret() {
    local username="$1"
    local password="$2"
    local secret_name="$3"
    local namespace="$4"
    local description="$5"
    
    # Check if exists
    if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        log_success "Secret $namespace/$secret_name already exists"
        log_info "Retrieving credentials from existing secret..."
        
        local existing_user=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
        local existing_pass=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
        
        if [[ -n "$existing_user" && -n "$existing_pass" ]]; then
            log_success "Retrieved credentials from secret for user: $existing_user"
            echo "$existing_user:$existing_pass"
            return 0
        else
            log_error "Failed to retrieve credentials from existing secret"
            return 1
        fi
    fi
    
    # Create new
    log_info "Creating Kubernetes secret for user credentials..."
    kubectl create secret generic "$secret_name" \
        -n "$namespace" \
        --type=kubernetes.io/basic-auth \
        --from-literal=username="$username" \
        --from-literal=password="$password" &>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create secret"
        return 1
    fi
    
    # Add description annotation if provided
    if [[ -n "$description" ]]; then
        kubectl annotate secret "$secret_name" \
            -n "$namespace" \
            description="$description" \
            --overwrite &>/dev/null
    fi
    
    log_success "Kubernetes secret created: $namespace/$secret_name"
    echo "$username:$password"
}

# Retrieve credentials from secret
get_credentials_from_secret() {
    local secret_name="$1"
    local namespace="$2"
    
    log_info "Retrieving credentials from secret: $namespace/$secret_name"
    
    local username=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
    local password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    
    if [[ -n "$username" && -n "$password" ]]; then
        log_success "Retrieved credentials for user: $username"
        echo "$username:$password"
        return 0
    else
        log_error "Failed to retrieve credentials from secret"
        return 1
    fi
}

# Create ArgoCD repo-creds secret
create_argocd_repo_creds_secret() {
    local gitea_url="$1"
    local service_account_username="$2"
    local service_account_token="$3"
    local service_account_token_name="$4"
    local service_account_token_description="$5"
    
    
    log_info "Creating ArgoCD repo-creds secret: $ARGOCD_NAMESPACE/$ARGOCD_REPO_CREDS_SECRET"
    log_info "Repository URL pattern: $gitea_url"
    log_info "Service account: $service_account_username"
    
    # Delete if exists
    if kubectl get secret "$ARGOCD_REPO_CREDS_SECRET" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_warn "Secret already exists, deleting..."
        kubectl delete secret "$ARGOCD_REPO_CREDS_SECRET" -n "$ARGOCD_NAMESPACE" &>/dev/null
    fi
    
    # Create
    kubectl create secret generic "$ARGOCD_REPO_CREDS_SECRET" \
        -n "$ARGOCD_NAMESPACE" \
        --from-literal=type=git \
        --from-literal=url="$gitea_url" \
        --from-literal=username="$service_account_username" \
        --from-literal=password="$service_account_token" \
        --from-literal=gitea-token-name="$service_account_token_name" &>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create repo-creds secret"
        return 1
    fi
    
    # Label
    kubectl label secret "$ARGOCD_REPO_CREDS_SECRET" \
        -n "$ARGOCD_NAMESPACE" \
        argocd.argoproj.io/secret-type=repo-creds \
        --overwrite &>/dev/null

    # Annotate
    kubectl annotate secret "$ARGOCD_REPO_CREDS_SECRET" \
        -n "$ARGOCD_NAMESPACE" \
        description="$service_account_token_description" \
        --overwrite &>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to label repo-creds secret"
        return 1
    fi
    
    log_success "ArgoCD repo-creds secret created and labeled"
}

# Approve pending Kubernetes CSRs from system nodes
# Usage: approve_node_csrs [max_timeout] [inter_node_timeout] [expected_nodes...]
# Example: approve_node_csrs 300 120 node1.domain.com node2.domain.com
# Note: Accepts FQDNs or hostnames; will match against hostname portion only
approve_node_csrs() {
    local max_timeout="${1:-300}"
    local inter_node_timeout="${2:-120}"
    shift 2 2>/dev/null || shift $# # Remove first 2 args, remaining are expected nodes
    local expected_nodes=("$@")
    
    # Normalize expected nodes to just hostname (strip domain if present)
    local expected_hostnames=()
    for node in ${expected_nodes[@]+"${expected_nodes[@]}"}; do
        # Extract hostname (everything before first dot)
        local hostname="${node%%.*}"
        expected_hostnames+=("$hostname")
    done
    
    local start_time=$(date +%s)
    local last_approval_time=0
    local inter_node_timer_enabled=false
    local approved_csrs=()
    local nodes_with_approved_csrs=()
    
    # Log configuration
    log_info "Starting CSR approval (max_timeout: ${max_timeout}s, inter_node_timeout: ${inter_node_timeout}s)"
    if [[ ${#expected_nodes[@]} -gt 0 ]]; then
        log_info "Expecting CSRs from ${#expected_nodes[@]} nodes: ${expected_nodes[*]}"
    fi

    # Remove expected nodes that are already ready or have approved CSRs
    if [[ ${#expected_hostnames[@]} -gt 0 ]]; then
        local still_expected=()
        
        for expected_hostname in "${expected_hostnames[@]}"; do
            # Check if node is already in cluster and Ready
            if kubectl get node "$expected_hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                log_info "Skipping node $expected_hostname (already Ready)"
                continue
            fi
            
            # Check if node has an approved CSR (but not yet joined)
            if kubectl get csr -o json 2>/dev/null | \
                jq -e --arg hn "$expected_hostname" \
                '.items[] | select(.spec.username | startswith("system:node:" + $hn)) | 
                 select(.status.conditions != null and 
                        ([.status.conditions[] | select(.type=="Approved")] | length) > 0)' &>/dev/null; then
                log_info "Skipping node $expected_hostname (CSR already approved)"
                continue
            fi
            
            still_expected+=("$expected_hostname")
        done
        
        # Update expected list to only include nodes still needing CSR approval
        if [[ ${#still_expected[@]} -eq 0 ]]; then
            expected_hostnames=()
        else
            expected_hostnames=("${still_expected[@]}")
        fi
    fi
    
    # If all expected nodes are ready or have approved CSRs, exit successfully
    if [[ ${#expected_nodes[@]} -gt 0 && ${#expected_hostnames[@]} -eq 0 ]]; then
        log_success "All expected nodes are ready or have approved CSRs!"
        return 0
    fi
    
    # Main approval loop
    while true; do
        local current_time=$(date +%s)
        local max_elapsed=$((current_time - start_time))
        
        # Check max_timeout
        if [[ $max_elapsed -ge $max_timeout ]]; then
            log_error "Max timeout reached (${max_elapsed}s). Missing nodes: ${expected_hostnames[*]}"
            return 1
        fi
        
        # Check inter_node_timeout (only after first approval)
        if $inter_node_timer_enabled; then
            local inter_node_elapsed=$((current_time - last_approval_time))
            if [[ $inter_node_elapsed -ge $inter_node_timeout ]]; then
                log_error "Inter-node timeout reached (${inter_node_elapsed}s since last approval). Missing nodes: ${expected_hostnames[*]}"
                return 1
            fi
        fi
        
        # Check for new unapproved CSRs from system nodes
        local pending_csrs=$(kubectl get csr -o json 2>/dev/null | \
            jq -r '.items[] | 
                   select(.spec.username | startswith("system:node:")) | 
                   select(.status.conditions == null or 
                          (.status.conditions[] | select(.type=="Approved") | length) == 0) | 
                   "\(.metadata.name)|\(.spec.username)"' 2>/dev/null)
        
        if [[ -n "$pending_csrs" ]]; then
            while IFS='|' read -r csr_name csr_username; do
                if [[ -n "$csr_name" ]]; then
                    # Extract node name from username (system:node:nodename)
                    local node_name="${csr_username#system:node:}"
                    
                    # Check if already approved in this session
                    if [[ ! " ${approved_csrs[@]:-} " =~ " ${csr_name} " ]]; then
                        if kubectl certificate approve "$csr_name" &>/dev/null; then
                            approved_csrs+=("$csr_name")
                            log_success "Approved CSR for node: $node_name"
                            
                            # Reset timers on successful approval
                            last_approval_time=$(date +%s)
                            inter_node_timer_enabled=true
                            
                            # Track node and remove from expected list
                            if [[ ! " ${nodes_with_approved_csrs[@]:-} " =~ " ${node_name} " ]]; then
                                nodes_with_approved_csrs+=("$node_name")
                                
                                # Remove from expected_hostnames
                                local new_expected=()
                                for expected_hostname in "${expected_hostnames[@]}"; do
                                    if [[ "$expected_hostname" != "$node_name" ]]; then
                                        new_expected+=("$expected_hostname")
                                    fi
                                done
                                
                                if [[ ${#new_expected[@]} -eq 0 ]]; then
                                    expected_hostnames=()
                                else
                                    expected_hostnames=("${new_expected[@]}")
                                fi
                            fi
                        fi
                    fi
                fi
            done <<< "$pending_csrs"
        fi
        
        # Re-check if expected nodes became Ready while loop is running
        if [[ ${#expected_hostnames[@]} -gt 0 ]]; then
            local still_expected=()

            for expected_hostname in "${expected_hostnames[@]}"; do
                if kubectl get node "$expected_hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                    log_info "Skipping node $expected_hostname (already Ready)"
                    continue
                fi

                still_expected+=("$expected_hostname")
            done

            if [[ ${#still_expected[@]} -eq 0 ]]; then
                expected_hostnames=()
            else
                expected_hostnames=("${still_expected[@]}")
            fi
        fi
        
        # Check if all expected nodes have been approved
        if [[ ${#expected_hostnames[@]} -eq 0 ]]; then
            log_success "All expected nodes are ready or have approved CSRs! Total approved: ${#approved_csrs[@]}"
            return 0
        fi
        
        sleep 5
    done
}

readonly KUBERNETES_LOADED=1
