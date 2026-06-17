#!/usr/bin/env zsh
# Gitea API utilities

# Source dependencies
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }

# Constants used by this library (should be defined in main script)
: ${GITEA_NAMESPACE:=gitea}
: ${GITEA_ADMIN_SECRET:=gitea-bootstrap-admin-secret}
: ${GITEA_READY_MAX_RETRIES:=60}
: ${GITEA_READY_RETRY_INTERVAL:=5}
: ${GITEA_POD_READY_TIMEOUT:=300s}
: ${ARGOCD_SERVICE_TOKEN_SCOPES:='["read:repository","read:organization","read:user","read:issue"]'}

# Get HTTP code from response (expects format: body\nhttp_code)
get_http_code() {
    local response="$1"
    echo "$response" | tail -n 1
}

# Get HTTP body from response (expects format: body\nhttp_code)
get_http_body() {
    local response="$1"
    echo "$response" | sed '$d'
}

# Get header value from curl response with -i flag
# Usage: get_header "$response" "X-Total-Count"
get_header() {
    local response="$1"
    local header_name="$2"
    # Extract header value (case-insensitive)
    echo "$response" | grep -i "^${header_name}:" | head -n1 | sed -E "s/^${header_name}:[[:space:]]*//i" | tr -d '\r'
}

# Wait for Gitea to be ready
wait_for_gitea_ready() {
    local domain="$1"
    local retry_count=0
    
    log_info "Waiting for Gitea to be ready..."
    
    # Wait for pod with retry logic (5 minute total timeout)
    log_info "Checking Gitea pod status..."
    local pod_wait_timeout=600  # 10 minutes total, CNPG is slow to start
    local pod_check_interval=5
    local pod_elapsed=0
    local pod_ready=false
    
    while [[ $pod_elapsed -lt $pod_wait_timeout ]]; do
        # Check if pod exists
        if kubectl get pod -l app.kubernetes.io/name=gitea -n "$GITEA_NAMESPACE" &>/dev/null; then
            # Pod exists, wait for it to be ready
            if kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=gitea -n "$GITEA_NAMESPACE" --timeout=10s &>/dev/null; then
                log_success "Gitea pod is ready"
                pod_ready=true
                break
            fi
        else
            log_info "Gitea pod not found yet, waiting..."
        fi
        
        sleep "$pod_check_interval"
        pod_elapsed=$((pod_elapsed + pod_check_interval))
        echo -n "."
    done
    
    echo ""
    if [[ "$pod_ready" != "true" ]]; then
        log_error "Gitea pod did not become ready after ${pod_wait_timeout} seconds"
        exit 1
    fi
    
    # Wait for API
    log_info "Waiting for Gitea API at https://$domain..."
    while [[ $retry_count -lt $GITEA_READY_MAX_RETRIES ]]; do
        if curl -k -s -S -f "https://$domain/api/v1/version" &>/dev/null; then
            log_success "Gitea is ready!"
            return 0
        fi
        retry_count=$((retry_count + 1))
        echo -n "."
        sleep "$GITEA_READY_RETRY_INTERVAL"
    done
    echo ""
    log_error "Gitea did not become ready after $((GITEA_READY_MAX_RETRIES * GITEA_READY_RETRY_INTERVAL)) seconds"
    return 1
}

# Fetch Gitea admin credentials from Kubernetes secret
fetch_gitea_admin_credentials() {
    log_info "Fetching admin credentials from secret: $GITEA_NAMESPACE/$GITEA_ADMIN_SECRET"
    
    if ! kubectl get secret "$GITEA_ADMIN_SECRET" -n "$GITEA_NAMESPACE" &>/dev/null; then
        log_error "Secret $GITEA_ADMIN_SECRET not found in namespace $GITEA_NAMESPACE"
        return 1
    fi
    
    local username=$(kubectl get secret "$GITEA_ADMIN_SECRET" -n "$GITEA_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    local password=$(kubectl get secret "$GITEA_ADMIN_SECRET" -n "$GITEA_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
    
    if [[ -z "$username" || -z "$password" ]]; then
        log_error "Failed to extract credentials from secret"
        return 1
    fi
    
    log_success "Credentials retrieved for user: $username"
    echo "$username:$password"
}

# Create Gitea token
# Args: credentials api_url token_name scopes [check_existing]
# If check_existing=true, returns "TOKEN_ALREADY_EXISTS" if token with same name exists
# Otherwise returns "token_id|token" for new tokens, or just "token" for existing tokens when check_existing=true
create_gitea_token() {
    local credentials="$1"
    local api_url="$2"
    local token_name="$3"
    local scopes="$4"
    local check_existing="${5:-false}"
    
    local username="${credentials%%:*}"
    
    log_info "Creating token '$token_name' for user: $username"
    
    # Check if token already exists (if requested)
    if [[ "$check_existing" == "true" ]]; then
        local response=$(curl -k -s -S -w "\n%{http_code}" -X GET \
            -u "$credentials" \
            "$api_url/users/$username/tokens")
        
        local http_code=$(get_http_code "$response")
        local body=$(get_http_body "$response")
        
        if [[ "$http_code" == "200" ]]; then
            local existing=$(echo "$body" | jq -r ".[] | select(.name == \"$token_name\") | .name" 2>/dev/null)
            if [[ -n "$existing" && "$existing" != "null" ]]; then
                log_success "Token '$token_name' already exists for user: $username"
                echo "TOKEN_ALREADY_EXISTS"
                return 0
            fi
        fi
    fi
    
    # Create new token
    log_info "Sending token creation request to Gitea API..."
    local response=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -u "$credentials" \
        -d "{\"name\":\"$token_name\",\"scopes\":$scopes}" \
        "$api_url/users/$username/tokens")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" != "201" ]]; then
        log_error "Failed to create token (HTTP $http_code)"
        log_error "Response: $body"
        return 1
    fi
    
    local token=$(echo "$body" | jq -r '.sha1')
    local token_id=$(echo "$body" | jq -r '.id')
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Failed to parse token from response"
        return 1
    fi
    
    log_success "Token created (ID: $token_id)"
    
    # Always return "token_id|token" format when a new token is created
    # (if check_existing=true and token exists, we already returned "TOKEN_ALREADY_EXISTS" earlier)
    echo "$token_id|$token"
}

# Delete Gitea token
delete_gitea_token() {
    local credentials="$1"
    local token_id="$2"
    local api_url="$3"
    local username="${credentials%%:*}"
    
    log_info "Deleting access token (ID: $token_id)..."
    
    local http_code=$(curl -k -s -S -o /dev/null -w "%{http_code}" -X DELETE \
        -u "$credentials" \
        "$api_url/users/$username/tokens/$token_id")
    
    if [[ "$http_code" == "204" ]]; then
        log_success "Access token deleted"
    else
        log_warn "Failed to delete access token (HTTP $http_code)"
    fi
}

# Check organization exists
check_gitea_organization() {
    local org_name="$1"
    local api_url="$2"
    local token="$3"
    
    local http_code=$(curl -k -s -S -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        "$api_url/orgs/$org_name")
    
    echo "$http_code"
}

# Create organization
create_gitea_organization() {
    local org_name="$1"
    local api_url="$2"
    local token="$3"
    local full_name="$4"
    
    log_info "Creating organization: $org_name"
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "{\"username\":\"$org_name\",\"full_name\":\"$full_name\",\"visibility\":\"private\"}" \
        "$api_url/orgs")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" != "201" ]]; then
        log_error "Failed to create organization (HTTP $http_code): $body"
        return 1
    fi
    
    log_success "Organization created: $org_name"
}

# Delete organization
delete_gitea_organization() {
    local org_name="$1"
    local api_url="$2"
    local token="$3"
    
    log_warn "Deleting organization: $org_name"
    
    local http_code=$(curl -k -s -S -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token $token" \
        "$api_url/orgs/$org_name")
    
    if [[ "$http_code" != "204" ]]; then
        log_error "Failed to delete organization (HTTP $http_code)"
        return 1
    fi
    
    log_success "Organization deleted: $org_name"
}

# Check repository exists
check_gitea_repository() {
    local org_name="$1"
    local repo_name="$2"
    local api_url="$3"
    local token="$4"
    
    local http_code=$(curl -k -s -S -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        "$api_url/repos/$org_name/$repo_name")
    
    echo "$http_code"
}

# Create repository
create_gitea_repository() {
    local org_name="$1"
    local repo_name="$2"
    local api_url="$3"
    local token="$4"
    
    log_info "Creating repository: $org_name/$repo_name"
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "{\"name\":\"$repo_name\",\"private\":false,\"auto_init\":false,\"default_branch\":\"main\"}" \
        "$api_url/orgs/$org_name/repos")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" != "201" ]]; then
        log_error "Failed to create repository (HTTP $http_code): $body"
        return 1
    fi
    
    log_success "Repository created: $org_name/$repo_name"
}

# Delete repository
delete_gitea_repository() {
    local org_name="$1"
    local repo_name="$2"
    local api_url="$3"
    local token="$4"
    
    log_warn "Deleting repository: $org_name/$repo_name"
    
    local http_code=$(curl -k -s -S -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token $token" \
        "$api_url/repos/$org_name/$repo_name")
    
    if [[ "$http_code" != "204" ]]; then
        log_error "Failed to delete repository (HTTP $http_code)"
        return 1
    fi
    
    log_success "Repository deleted: $org_name/$repo_name"
}

# Create Gitea user
create_gitea_user() {
    local username="$1"
    local email="$2"
    local api_url="$3"
    local token="$4"
    local password="$5"
    
    log_info "Creating Gitea user: $username"
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "{\"username\":\"$username\",\"email\":\"$email\",\"password\":\"$password\",\"must_change_password\":false,\"send_notify\":false}" \
        "$api_url/admin/users")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" == "201" ]]; then
        log_success "User created: $username"
        return 0
    elif [[ "$http_code" == "422" ]]; then
        log_success "User already exists: $username"
        return 0
    else
        log_error "Failed to create user (HTTP $http_code): $body"
        return 1
    fi
}

# Add repository collaborator
add_gitea_repo_collaborator() {
    local org_name="$1"
    local repo_name="$2"
    local username="$3"
    local permission="$4"
    local api_url="$5"
    local token="$6"
    
    log_info "Adding $username as $permission collaborator to $org_name/$repo_name"
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "{\"permission\":\"$permission\"}" \
        "$api_url/repos/$org_name/$repo_name/collaborators/$username")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" == "204" ]]; then
        log_success "Collaborator added: $username with $permission permission"
        return 0
    else
        log_error "Failed to add collaborator (HTTP $http_code): $body"
        return 1
    fi
}

# Check if webhook exists in repository
# Returns "EXISTS" if webhook with matching URL exists, "MISSING" otherwise
check_gitea_webhook() {
    local org_name="$1"
    local repo_name="$2"
    local webhook_url="$3"
    local api_url="$4"
    local token="$5"
    
    log_info "Checking if webhook exists for $org_name/$repo_name with URL: $webhook_url"
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X GET \
        -H "Authorization: token $token" \
        "$api_url/repos/$org_name/$repo_name/hooks")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" != "200" ]]; then
        log_error "Failed to list webhooks (HTTP $http_code): $body"
        return 1
    fi
    
    # Check if any webhook has matching URL
    local webhook_exists=$(echo "$body" | jq -r --arg url "$webhook_url" '.[] | select(.config.url == $url) | .id' | head -n1)
    
    if [[ -n "$webhook_exists" ]]; then
        log_success "Webhook already exists with URL: $webhook_url"
        echo "EXISTS"
        return 0
    else
        log_info "No webhook found with URL: $webhook_url"
        echo "MISSING"
        return 0
    fi
}

# Create webhook in repository
create_gitea_webhook() {
    local org_name="$1"
    local repo_name="$2"
    local webhook_url="$3"
    local api_url="$4"
    local token="$5"
    
    log_info "Creating webhook for $org_name/$repo_name"
    log_info "Webhook URL: $webhook_url"
    
    local payload=$(cat <<EOF
{
  "type": "gitea",
  "branch_filter": "main",
  "config": {
    "url": "$webhook_url",
    "content_type": "json"
  },
  "events": ["push"],
  "active": true
}
EOF
)
    
    local response=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$api_url/repos/$org_name/$repo_name/hooks")
    
    local http_code=$(get_http_code "$response")
    local body=$(get_http_body "$response")
    
    if [[ "$http_code" == "201" ]]; then
        log_success "Webhook created successfully"
        return 0
    else
        log_error "Failed to create webhook (HTTP $http_code): $body"
        return 1
    fi
}

# Configure git remote
configure_git_remote() {
    local remote_name="$1"
    local remote_url="$2"
    local git_root="$3"
    
    log_info "Configuring git remote in: $git_root"
    
    cd "$git_root"
    
    # Check if remote already exists
    if git remote get-url "$remote_name" &>/dev/null; then
        local existing_url=$(git remote get-url "$remote_name")
        if [[ "$existing_url" == "$remote_url" ]]; then
            log_success "Git remote '$remote_name' already configured correctly"
            return 0
        else
            log_warn "Git remote '$remote_name' exists with different URL: $existing_url"
            log_info "Updating remote URL to: $remote_url"
            git remote set-url "$remote_name" "$remote_url"
        fi
    else
        log_info "Adding git remote: $remote_name -> $remote_url"
        git remote add "$remote_name" "$remote_url"
    fi
    
    # Configure to ignore SSL certificate errors for this remote
    git config "http.https://${GITEA_DOMAIN_NAME}/.sslVerify" false
    
    log_success "Git remote configured: $remote_name"
    return 0
}

# Push repository to Gitea
# Parameters:
#   $1: credentials (username:password)
#   --push-working-state: Push all working files (creates temp clone)
#   --destination-branch <branch>: Target branch to push to (defaults to current branch)
push_to_gitea_cluster_services() {
    local credentials="$1"
    shift 1
    
    local push_working_state=false
    local destination_branch=""
    
    # Parse optional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --push-working-state)
                push_working_state=true
                shift
                ;;
            --destination-branch)
                destination_branch="$2"
                shift 2
                ;;
            *)
                log_error "Unknown parameter: $1"
                return 1
                ;;
        esac
    done
    
    # Resolve inputs from environment
    local remote_name="gitea-${CLUSTER_NAME}"
    local repo_url="https://${GITEA_DOMAIN_NAME}/${GITEA_CLUSTER_GITEA_ORG_NAME}/${GITEA_CLUSTER_SERVICES_REPO_NAME}.git"
    local username="${credentials%%:*}"
    local password="${credentials#*:}"
    local auth_repo_url="https://${username}:${password}@${GITEA_DOMAIN_NAME}/${GITEA_CLUSTER_GITEA_ORG_NAME}/${GITEA_CLUSTER_SERVICES_REPO_NAME}.git"
    
    # Configure git remote
    if ! configure_git_remote "$remote_name" "$repo_url" "$OVERLAY_DIR"; then
        log_error "Failed to configure git remote"
        return 1
    fi
    echo ""
    
    # Get current branch name
    cd "$OVERLAY_DIR"
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    
    # Determine target branch
    local target_branch="${destination_branch:-$current_branch}"
    
    if [[ "$push_working_state" == "true" ]]; then
        # Push working state - create temp clone with all files
        log_info "Pushing working state to Gitea..."
        
        # Create temporary directory
        local temp_repo_dir=""
        local temp_dir_prefix="${TEMP_DIR_PREFIX:-gitea-bootstrap}"

        # GNU mktemp requires a template with XXXXXX; BSD mktemp (macOS) supports -t <prefix>.
        # Try GNU-compatible form first, then BSD-compatible form.
        temp_repo_dir=$(mktemp -d "${TMPDIR:-/tmp}/${temp_dir_prefix}.XXXXXX" 2>/dev/null) || \
            temp_repo_dir=$(mktemp -d -t "$temp_dir_prefix" 2>/dev/null) || true

        if [[ -z "$temp_repo_dir" || ! -d "$temp_repo_dir" ]]; then
            log_error "Failed to create temporary directory for repository copy"
            return 1
        fi

        GIT_TEMP_DIR="$temp_repo_dir"
        
        log_info "Creating temporary repository copy in: $temp_repo_dir"
        
        # Copy repository
        rsync -a "$OVERLAY_DIR/" "$temp_repo_dir/" || {
            log_error "Failed to copy repository to temp directory"
            return 1
        }
        
        log_success "Repository copied to temporary directory"
        
        # Work in temp directory
        cd "$temp_repo_dir"
        
        # Ensure target branch exists
        if ! git rev-parse --verify "$target_branch" &>/dev/null; then
            log_info "Creating branch: $target_branch"
            git checkout -b "$target_branch" &>/dev/null || true
        else
            log_info "Switching to branch: $target_branch"
            git checkout "$target_branch" &>/dev/null || git checkout -B "$target_branch" &>/dev/null
        fi
        
        # Add all files
        git add -A -f -f -- .
        
        # Commit
        if git diff --cached --quiet; then
            log_info "No new changes to commit, pushing current state"
        else
            git commit -m "Bootstrap: Push working state from gitea-bootstrap.sh" &>/dev/null || true
            #git log -1 --name-status
            log_success "Changes committed to $target_branch branch"
        fi
        
        # Push
        log_info "Pushing to Gitea ($GITEA_CLUSTER_GITEA_ORG_NAME/$GITEA_CLUSTER_SERVICES_REPO_NAME:$target_branch)..."
        local push_output
        if push_output=$(GIT_TERMINAL_PROMPT=0 GIT_TRACE=0 git -c http.sslVerify=false push -f "$auth_repo_url" "$target_branch:$target_branch" 2>&1); then
            log_success "Successfully pushed working state to Gitea"
        else
            log_error "Failed to push to Gitea"
            log_error "Git output: $push_output"
            cd "$OVERLAY_DIR"
            return 1
        fi
        
        # Return to original directory and cleanup
        rm -rf  "$GIT_TEMP_DIR"
        # Note: cleanup_git_state should be called by the caller
        
    else
        # Push latest commit from current branch
        log_info "Pushing latest commit to Gitea ($GITEA_CLUSTER_GITEA_ORG_NAME/$GITEA_CLUSTER_SERVICES_REPO_NAME:$target_branch)..."
        
        local push_output
        if push_output=$(GIT_TERMINAL_PROMPT=0 GIT_TRACE=0 git -c http.sslVerify=false push "$auth_repo_url" "$current_branch:$target_branch" 2>&1); then
            log_success "Successfully pushed to Gitea"
        else
            log_error "Failed to push to Gitea"
            log_error "Git output: $push_output"
            return 1
        fi
    fi
    
    return 0
}

# Check if Gitea has been bootstrapped
# Returns 0 if fully bootstrapped, 1 otherwise
# Prints status information about what exists and what's missing
# Uses environment variables from loaded env file
check_gitea_bootstrap_status() {

    # Derive values from environment variables
    local org_name="${GITEA_CLUSTER_GITEA_ORG_NAME}"
    local repo_name="${GITEA_CLUSTER_SERVICES_REPO_NAME}"
    local argocd_service_account="argocd-cluster-services"
    local api_url="https://${GITEA_DOMAIN_NAME}/api/v1"
    local argocd_namespace="${ARGOCD_NAMESPACE}"
    local argocd_creds_secret="gitea-argocd-cluster-services-credentials"
    local argocd_repo_secret="gitea-argocd-cluster-services-repo-creds"
    
    # Fetch token from ArgoCD repo-creds secret
    local token=""
    if kubectl get secret "$argocd_repo_secret" -n "$argocd_namespace" &>/dev/null; then
        token=$(kubectl get secret "$argocd_repo_secret" -n "$argocd_namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    fi
    
    if [[ -z "$token" ]]; then
        log_error "Could not fetch token from secret: $argocd_namespace/$argocd_repo_secret"
        log_info "Presuming Gitea is not bootstrapped."
        return 1
    fi
    
    local all_ok=true
    
    log_info "Checking Gitea bootstrap status..."
    echo ""
    
    # Check organization
    # local org_status=$(check_gitea_organization "$org_name" "$api_url" "$token")
    # if [[ "$org_status" == "200" ]]; then
    #     log_success "✓ Organization exists: $org_name"
    # else
    #     log_error "✗ Organization missing: $org_name"
    #     all_ok=false
    # fi
    
    # Check repository
    local repo_status=$(check_gitea_repository "$org_name" "$repo_name" "$api_url" "$token")
    if [[ "$repo_status" == "200" ]]; then
        log_success "✓ Repository exists: $org_name/$repo_name"
        
        # Check if repository has been initialized with code
        # Use -i to include headers and check X-Total-Count
        local response=$(curl -k -s -S -i -w "\n%{http_code}" \
            -H "Authorization: token $token" \
            "$api_url/repos/$org_name/$repo_name/commits?limit=1")
        local http_code=$(echo "$response" | tail -n 1)
        
        if [[ "$http_code" == "200" ]]; then
            # Get commit count from X-Total-Count header
            local commit_count=$(get_header "$response" "X-Total-Count")
            if [[ -n "$commit_count" && "$commit_count" -gt 0 ]]; then
                log_success "✓ Repository has commits: $commit_count commit(s)"
            else
                log_error "✗ Repository is empty (no commits)"
                all_ok=false
            fi
        elif [[ "$http_code" == "409" ]]; then
            log_error "✗ Repository is empty (not initialized)"
            all_ok=false
        else
            log_warn "⚠ Could not check repository commits (HTTP $http_code)"
        fi
    else
        log_error "✗ Repository missing: $org_name/$repo_name"
        all_ok=false
    fi
    
    # Check ArgoCD service account user
    local user_status=$(curl -k -s -S -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        "$api_url/users/$argocd_service_account")
    if [[ "$user_status" == "200" ]]; then
        log_success "✓ ArgoCD service account exists: $argocd_service_account"
    else
        log_error "✗ ArgoCD service account missing: $argocd_service_account"
        all_ok=false
    fi
    
    # Check ArgoCD credentials secret
    if kubectl get secret "$argocd_creds_secret" -n "$argocd_namespace" &>/dev/null; then
        log_success "✓ ArgoCD credentials secret exists: $argocd_namespace/$argocd_creds_secret"
    else
        log_error "✗ ArgoCD credentials secret missing: $argocd_namespace/$argocd_creds_secret"
        all_ok=false
    fi
    
    # Check ArgoCD repo-creds secret
    if kubectl get secret "$argocd_repo_secret" -n "$argocd_namespace" &>/dev/null; then
        log_success "✓ ArgoCD repo-creds secret exists: $argocd_namespace/$argocd_repo_secret"
    else
        log_error "✗ ArgoCD repo-creds secret missing: $argocd_namespace/$argocd_repo_secret"
        all_ok=false
    fi
    
    echo ""
    if [[ "$all_ok" == "true" ]]; then
        log_success "Gitea is fully bootstrapped"
        return 0
    else
        log_warn "Gitea bootstrap is incomplete"
        return 1
    fi
}


# Add user to organization as a member
# Args: org_name username api_url token
add_user_to_org() {
    local org_name="$1"
    local username="$2"
    local api_url="$3"
    local token="$4"

    log_info "Adding $username to org $org_name as owner..."

    # Gitea has no PUT /orgs/{org}/members/{username} endpoint.
    # Members are added via the Teams API: find the Owners team, then add the user.
    local teams_response
    teams_response=$(curl -k -s -S -w "\n%{http_code}" \
        -H "Authorization: token $token" \
        "$api_url/orgs/$org_name/teams")

    local teams_code
    teams_code=$(get_http_code "$teams_response")
    local teams_body
    teams_body=$(get_http_body "$teams_response")

    if [[ "$teams_code" != "200" ]]; then
        log_error "Failed to list org teams (HTTP $teams_code): $teams_body"
        return 1
    fi

    local owners_team_id
    owners_team_id=$(echo "$teams_body" | jq -r '.[] | select(.name == "Owners") | .id')

    if [[ -z "$owners_team_id" ]]; then
        log_error "Could not find Owners team for org $org_name"
        return 1
    fi

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        "$api_url/teams/$owners_team_id/members/$username")

    local http_code
    http_code=$(get_http_code "$response")

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        log_success "User $username added to org $org_name (Owners team)"
        return 0
    else
        log_error "Failed to add user to org (HTTP $http_code): $(get_http_body "$response")"
        return 1
    fi
}

# Set or update an Actions repository variable (plain-text, no encryption needed).
# Gitea 1.22+ API (confirmed against 1.25.4 swagger):
#   POST /repos/{owner}/{repo}/actions/variables/{variablename}  -> create  body: {"value":"…"}
#   PUT  /repos/{owner}/{repo}/actions/variables/{variablename}  -> update  body: {"value":"…"}
# Both methods target the NAMED endpoint (not the collection).
# Args: org_or_user repo_name var_name var_value api_url token
set_gitea_repo_variable() {
    local org_or_user="$1"
    local repo_name="$2"
    local var_name="$3"
    local var_value="$4"
    local api_url="$5"
    local token="$6"

    log_info "Setting repo variable $var_name on $org_or_user/$repo_name"

    local var_url="$api_url/repos/$org_or_user/$repo_name/actions/variables/$var_name"
    local payload
    payload=$(jq -n --arg v "$var_value" '{value: $v}')

    # Check whether the variable already exists to decide create vs update
    local check_code
    check_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        "$var_url")

    local method
    [[ "$check_code" == "200" ]] && method="PUT" || method="POST"

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X "$method" \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$var_url")

    local http_code body
    http_code=$(get_http_code "$response")
    body=$(get_http_body "$response")

    if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
        log_success "Variable $var_name set"
        return 0
    else
        log_error "Failed to set variable $var_name (HTTP $http_code): $body"
        return 1
    fi
}

# Push a local directory to an arbitrary Gitea repo.
# Args: src_dir org_name repo_name credentials gitea_domain branch
push_dir_to_gitea_repo() {
    local src_dir="$1"
    local org_name="$2"
    local repo_name="$3"
    local credentials="$4"  # username:password
    local gitea_domain="$5"
    local branch="${6:-main}"

    local username="${credentials%%:*}"
    local password="${credentials#*:}"
    local remote_url="https://${username}:${password}@${gitea_domain}/${org_name}/${repo_name}.git"

    log_info "Pushing $src_dir → $gitea_domain/$org_name/$repo_name ($branch)..."

    local temp_dir
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/gitea-push.XXXXXX")

    # Copy source directory into temp
    rsync -a --exclude='.git' "$src_dir/" "$temp_dir/"

    pushd "$temp_dir" > /dev/null

    git init -b "$branch"
    git config user.email "bootstrap@cluster.local"
    git config user.name  "cluster-bootstrap"
    git add -A
    git commit -m "chore: initial commit from bootstrap-customer"

    git -c "http.sslVerify=false" push -u "$remote_url" "HEAD:$branch" --force

    popd > /dev/null
    rm -rf "$temp_dir"

    log_success "Pushed to $org_name/$repo_name"
}


# Create or update a file in a Gitea repository using the Contents API.
# Handles both first-time creation and subsequent updates (fetches existing SHA).
# Args: owner repo filepath content_string commit_message api_url token
#   content_string: raw text content (will be base64-encoded internally)
create_or_update_gitea_file() {
    local owner="$1"
    local repo="$2"
    local filepath="$3"
    local content="$4"
    local commit_message="$5"
    local api_url="$6"
    local token="$7"

    local encoded_content
    encoded_content=$(printf '%s' "$content" | base64 | tr -d '\n')

    # Check if file already exists to get its SHA (required for updates)
    local existing_response
    existing_response=$(curl -k -s -S -w "\n%{http_code}" \
        -H "Authorization: token $token" \
        "$api_url/repos/$owner/$repo/contents/$filepath")

    local existing_code
    existing_code=$(echo "$existing_response" | tail -n1)
    local existing_body
    existing_body=$(echo "$existing_response" | sed '$d')

    # Gitea Contents API: POST to create a new file, PUT to update an existing one.
    # PUT without a SHA returns 422 "[SHA]: Required".
    local method payload
    if [[ "$existing_code" == "200" ]]; then
        local sha
        sha=$(echo "$existing_body" | jq -r '.sha')
        log_info "Updating existing file: $owner/$repo/$filepath (SHA: $sha)"
        method="PUT"
        payload=$(jq -n \
            --arg msg "$commit_message" \
            --arg content "$encoded_content" \
            --arg sha "$sha" \
            '{message: $msg, content: $content, sha: $sha}')
    else
        log_info "Creating new file: $owner/$repo/$filepath"
        method="POST"
        payload=$(jq -n \
            --arg msg "$commit_message" \
            --arg content "$encoded_content" \
            '{message: $msg, content: $content}')
    fi

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X "$method" \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$api_url/repos/$owner/$repo/contents/$filepath")

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        log_success "File committed: $owner/$repo/$filepath"
        return 0
    else
        log_error "Failed to write file $filepath (HTTP $http_code): $body"
        return 1
    fi
}

# Create a Gitea user if they don't exist, or reset their password if they do.
# Uses admin credentials.  The user is created as restricted (no global perms)
# with must_change_password=false so CI tokens can be minted immediately.
# Args: username email password api_url admin_token
create_or_ensure_gitea_user() {
    local username="$1"
    local email="$2"
    local password="$3"
    local api_url="$4"
    local admin_token="$5"

    # Check whether the user already exists
    local check_code
    check_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $admin_token" \
        "$api_url/users/$username")

    if [[ "$check_code" == "200" ]]; then
        log_info "CI user '$username' already exists — resetting password"
        local patch_resp
        patch_resp=$(curl -k -s -S -w "\n%{http_code}" -X PATCH \
            -H "Content-Type: application/json" \
            -H "Authorization: token $admin_token" \
            -d "$(jq -n --arg u "$username" --arg p "$password" '{source_id:0,login_name:$u,password:$p,must_change_password:false}')" \
            "$api_url/admin/users/$username")
        local patch_code
        patch_code=$(get_http_code "$patch_resp")
        if [[ "$patch_code" != "200" ]]; then
            log_error "Failed to reset password for '$username' (HTTP $patch_code): $(get_http_body "$patch_resp")"
            return 1
        fi
        log_success "Password reset for CI user '$username'"
    else
        log_info "Creating CI user '$username'"
        local create_resp
        create_resp=$(curl -k -s -S -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: token $admin_token" \
            -d "$(jq -n \
                --arg u "$username" \
                --arg e "$email" \
                --arg p "$password" \
                '{username:$u,email:$e,password:$p,must_change_password:false,restricted:true,send_notify:false}')" \
            "$api_url/admin/users")
        local create_code
        create_code=$(get_http_code "$create_resp")
        if [[ "$create_code" != "201" ]]; then
            log_error "Failed to create CI user '$username' (HTTP $create_code): $(get_http_body "$create_resp")"
            return 1
        fi
        log_success "CI user '$username' created"
    fi
}

# Create or update an org-level Actions variable.
# POST (create) / PUT (update) both target the NAMED endpoint.
# Args: org var_name var_value api_url token
set_gitea_org_variable() {
    local org="$1"
    local var_name="$2"
    local var_value="$3"
    local api_url="$4"
    local token="$5"

    log_info "Setting org variable $var_name on $org"

    local var_url="$api_url/orgs/$org/actions/variables/$var_name"
    local payload
    payload=$(jq -n --arg v "$var_value" '{value: $v}')

    local check_code
    check_code=$(curl -k -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        "$var_url")

    local method
    [[ "$check_code" == "200" ]] && method="PUT" || method="POST"

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X "$method" \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$var_url")

    local http_code body
    http_code=$(get_http_code "$response")
    body=$(get_http_body "$response")

    if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
        log_success "Org variable $var_name set on $org"
        return 0
    else
        log_error "Failed to set org variable $var_name (HTTP $http_code): $body"
        return 1
    fi
}

# Create or update an org-level Actions secret.
# Gitea org secrets API: PUT /orgs/{org}/actions/secrets/{secretname} body: {"data":"…"}
# (single method for both create and update, unlike variables)
# Args: org secret_name secret_value api_url token
set_gitea_org_secret() {
    local org="$1"
    local secret_name="$2"
    local secret_value="$3"
    local api_url="$4"
    local token="$5"

    log_info "Setting org secret $secret_name on $org"

    local payload
    payload=$(jq -n --arg v "$secret_value" '{data: $v}')

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$api_url/orgs/$org/actions/secrets/$secret_name")

    local http_code body
    http_code=$(get_http_code "$response")
    body=$(get_http_body "$response")

    if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
        log_success "Org secret $secret_name set on $org"
        return 0
    else
        log_error "Failed to set org secret $secret_name (HTTP $http_code): $body"
        return 1
    fi
}

# Create or update a repository-level Actions secret.
# Gitea secrets API uses plain text (no libsodium unlike GitHub):
#   PUT /repos/{owner}/{repo}/actions/secrets/{secretname}  body: {"data":"…"}
# Args: owner repo secret_name secret_value api_url token
set_gitea_repo_secret() {
    local owner="$1"
    local repo="$2"
    local secret_name="$3"
    local secret_value="$4"
    local api_url="$5"
    local token="$6"

    log_info "Setting repo secret $secret_name on $owner/$repo"

    local payload
    payload=$(jq -n --arg v "$secret_value" '{data: $v}')

    local response
    response=$(curl -k -s -S -w "\n%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -H "Authorization: token $token" \
        -d "$payload" \
        "$api_url/repos/$owner/$repo/actions/secrets/$secret_name")

    local http_code body
    http_code=$(get_http_code "$response")
    body=$(get_http_body "$response")

    if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
        log_success "Secret $secret_name set on $owner/$repo"
        return 0
    else
        log_error "Failed to set secret $secret_name (HTTP $http_code): $body"
        return 1
    fi
}

readonly GITEA_API_LOADED=1
