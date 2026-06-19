#!/usr/bin/env zsh
set -euo pipefail

################################################################################
# bootstrap-customer.sh
#
# Usage:
#   bootstrap-customer.sh <ENV_FILE> <CUSTOMER_NAME> [OPTIONS]
#
# Bootstraps a new customer on the cluster:
#   1. Creates a Gitea organisation for the customer
#   2. Adds the ArgoCD service account as an org member (needed for SCM scanning)
#   3. Creates a Gitea repository from the example-gitops-customer/ template
#   4. Pushes the example application code to Gitea
#   5. Commits _rendered/customers/<name>/<name>.yaml descriptor to the cluster-services
#      repo so the customer-apps ApplicationSet discovers the customer's org
#   6. Creates an ArgoCD AppProject scoped to <orgName>-* namespaces and
#      <orgName>/* source repos
#   7. Sets Gitea Actions repository variables
#   8. Grants the gitea-runner-service-account RBAC in the default namespace
#      (<orgName>-<repoName>) so it can trigger rollout restarts
#
# Options:
#   --org-name <name>        Gitea org name (default: CUSTOMER_NAME)
#   --repo-name <name>       Gitea repo / app name (default: example-repo)
#   --ingress-host <host>    Ingress hostname (default: CUSTOMER_NAME.CLUSTER_EXTERNAL_DOMAIN)
#   --template-branch <br>   Branch of the template repo to clone (default: master)
#   --force-recreate         Delete and re-create the Gitea org/repo if they exist
#
# Namespace is always derived as <orgName>-<repoName> — matching the formula
# used by the ApplicationSet template — so it never needs to be specified.
#
# Requirements: kubectl curl jq git rsync
################################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/gitea-api.sh"
source "$LIB_DIR/kubernetes.sh"

# Remote template repository cloned during bootstrap
readonly CUSTOMER_TEMPLATE_REPO="https://github.com/flip-flop-foundry/talos-bootstraper-customer-template"
readonly CUSTOMER_TEMPLATE_BRANCH_DEFAULT="master"

# Gitea admin secret (same as used by gitea-bootstrap.sh)
readonly GITEA_ADMIN_SECRET="gitea-bootstrap-admin-secret"

# Admin token scopes used during bootstrap
readonly ADMIN_TOKEN_SCOPES='["write:repository","write:organization","write:admin","write:user"]'

# ArgoCD service account that must be a member of every customer org
readonly ARGOCD_SVC_USER="argocd-cluster-services"
readonly ARGOCD_SVC_SECRET="gitea-argocd-cluster-services-credentials"

# Registry-pull service account — needs read access to every customer org so
# Talos containerd can pull customer images cluster-wide (via RegistryAuthConfig).
readonly REGISTRY_PULL_USER="registry-pull"

# Gitea runner SA
readonly RUNNER_SA_NAME="gitea-runner-service-account"

# Global for cleanup trap
GITEA_TOKEN_ID=""
GITEA_CREDENTIALS=""
GITEA_API_URL=""

cleanup_token() {
    if [[ -n "$GITEA_TOKEN_ID" && -n "$GITEA_CREDENTIALS" && -n "$GITEA_API_URL" ]]; then
        delete_gitea_token "$GITEA_CREDENTIALS" "$GITEA_TOKEN_ID" "$GITEA_API_URL"
    fi
}
trap cleanup_token EXIT

################################################################################
# Helpers
################################################################################

usage() {
    cat <<EOF
Usage: $(basename "$0") <ENV_FILE> <CUSTOMER_NAME> [OPTIONS]

Arguments:
  ENV_FILE          Path to the cluster environment file
  CUSTOMER_NAME     Short identifier for the customer (used as default org name)

Options:
  --org-name <name>         Gitea org name        (default: CUSTOMER_NAME)
  --repo-name <name>        Initial repo / app    (default: app)
  --ingress-host <host>     Ingress hostname      (default: CUSTOMER_NAME.CLUSTER_EXTERNAL_DOMAIN)
  --template-branch <br>    Template repo branch  (default: master)
  --force-recreate          Delete and re-create existing Gitea org/repo

Note: namespace is always derived as <orgName>-<repoName>.
Template repo: ${CUSTOMER_TEMPLATE_REPO}

Examples:
  $(basename "$0") overlays/mycluster/mycluster.env acme
  $(basename "$0") overlays/mycluster/mycluster.env acme --repo-name hello-world --force-recreate
  $(basename "$0") overlays/mycluster/mycluster.env acme --template-branch my-feature
EOF
    exit 1
}

check_dependencies() {
    local missing=()
    for dep in kubectl curl jq git rsync; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

load_env_file() {
    local env_file="$1"
    log_info "Loading environment from: $env_file"
    set -o allexport
    source "$env_file"
    set +o allexport

    [[ -z "${CLUSTER_NAME:-}"          ]] && { log_error "CLUSTER_NAME not set";          exit 1; }
    [[ -z "${GITEA_DOMAIN_NAME:-}"     ]] && { log_error "GITEA_DOMAIN_NAME not set";     exit 1; }
    [[ -z "${GITEA_NAMESPACE:-}"       ]] && { log_error "GITEA_NAMESPACE not set";       exit 1; }
    [[ -z "${ARGOCD_NAMESPACE:-}"      ]] && { log_error "ARGOCD_NAMESPACE not set";      exit 1; }
    [[ -z "${CLUSTER_EXTERNAL_DOMAIN:-}" ]] && { log_error "CLUSTER_EXTERNAL_DOMAIN not set"; exit 1; }

    log_success "Loaded environment for cluster: $CLUSTER_NAME"
}

################################################################################
# Kubernetes helpers
################################################################################

apply_customer_namespace() {
    local ns="$1"
    log_info "Ensuring namespace: $ns"
    kubectl get namespace "$ns" &>/dev/null && {
        log_success "Namespace already exists: $ns"
        return 0
    }
    kubectl create namespace "$ns"
    log_success "Namespace created: $ns"
}

apply_runner_rbac() {
    local namespace="$1"
    local runner_ns="${GITEA_NAMESPACE}-runners"

    log_info "Applying RBAC for runner SA in namespace: $namespace"

    kubectl apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-restarter
  namespace: ${namespace}
  labels:
    managed-by: bootstrap-customer
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitea-runner-deployment-restarter
  namespace: ${namespace}
  labels:
    managed-by: bootstrap-customer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployment-restarter
subjects:
  - kind: ServiceAccount
    name: ${RUNNER_SA_NAME}
    namespace: ${runner_ns}
EOF

    log_success "RBAC applied for $runner_ns/$RUNNER_SA_NAME in $namespace"
}

# Create a docker-registry imagePullSecret for the Gitea registry in the given
# namespace and patch the default ServiceAccount to reference it.
# This ensures all pods in the namespace can pull from the Gitea registry without
# needing explicit imagePullSecrets in each Deployment spec.
#
# NOTE: Talos RegistryAuthConfig (applied by apply-node-registry-config.sh) does NOT
# work alongside RegistryTLSConfig in containerd v2 — when config_path is set the
# registry.configs.auth section is ignored (upstream containerd limitation). This
# Kubernetes-native approach is the reliable workaround.
apply_registry_pull_secret() {
    local namespace="$1"
    local secret_name="gitea-registry-pull"
    local gitea_ns="${GITEA_NAMESPACE:-gitea}"

    log_info "Setting up Gitea registry imagePullSecret in namespace: $namespace"

    # Read registry-pull credentials from the K8s secret created by gitea-bootstrap.sh
    local reg_user reg_pass
    reg_user=$(kubectl get secret gitea-registry-pull-credentials -n "$gitea_ns" \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
    reg_pass=$(kubectl get secret gitea-registry-pull-credentials -n "$gitea_ns" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    if [[ -z "$reg_user" || -z "$reg_pass" ]]; then
        log_warn "Could not read gitea-registry-pull-credentials from $gitea_ns namespace — skipping imagePullSecret setup"
        log_warn "Run gitea-bootstrap.sh first to create the registry-pull service account"
        return 0
    fi

    # Create or update the docker-registry secret in the customer namespace
    if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        log_success "imagePullSecret '$secret_name' already exists in $namespace"
    else
        kubectl create secret docker-registry "$secret_name" \
            --namespace "$namespace" \
            --docker-server="$GITEA_DOMAIN_NAME" \
            --docker-username="$reg_user" \
            --docker-password="$reg_pass"
        log_success "imagePullSecret '$secret_name' created in $namespace"
    fi

    # Patch the default ServiceAccount to include the pull secret so all pods
    # in this namespace automatically get it without per-Deployment changes
    kubectl patch serviceaccount default \
        --namespace "$namespace" \
        --type=json \
        -p='[{"op":"add","path":"/imagePullSecrets","value":[{"name":"'"$secret_name"'"}]}]' \
        2>/dev/null || \
    kubectl patch serviceaccount default \
        --namespace "$namespace" \
        --type=merge \
        -p='{"imagePullSecrets":[{"name":"'"$secret_name"'"}]}' 2>/dev/null || true

    log_success "default ServiceAccount in $namespace patched with imagePullSecret '$secret_name'"
}

################################################################################
# Substitute PLACEHOLDER_* values in the example template
################################################################################

substitute_placeholders() {
    local src_dir="$1"
    local dest_dir="$2"
    local gitea_domain="$3"
    local org_name="$4"
    local app_name="$5"
    local namespace="$6"
    local cluster_domain="$7"
    local customer_name="${8:-$org_name}"  # defaults to org_name if not provided
    local ingress_host="${9:-${app_name}.${cluster_domain}}"
    local cluster_issuer="${TALOS_CLUSTER_NAME}-ca-issuer"

    log_info "Substituting placeholders into template..."

    rsync -a --exclude='.git' "$src_dir/" "$dest_dir/"

    # Replace all PLACEHOLDER_* strings in all files (template repo contains only text files)
    find "$dest_dir" -type f | while read -r file; do
        sed -i \
            -e "s|PLACEHOLDER_GITEA_DOMAIN|${gitea_domain}|g" \
            -e "s|PLACEHOLDER_ORG|${org_name}|g" \
            -e "s|PLACEHOLDER_APP|${app_name}|g" \
            -e "s|PLACEHOLDER_NAMESPACE|${namespace}|g" \
            -e "s|PLACEHOLDER_CLUSTER_DOMAIN|${cluster_domain}|g" \
            -e "s|PLACEHOLDER_CUSTOMER_NAME|${customer_name}|g" \
            -e "s|PLACEHOLDER_INGRESS_HOST|${ingress_host}|g" \
            -e "s|PLACEHOLDER_CLUSTER_ISSUER|${cluster_issuer}|g" \
            "$file"
    done

    log_success "Placeholders substituted"
}

################################################################################
# Main
################################################################################

main() {
    [[ $# -lt 2 ]] && usage

    local env_file="$1"
    local customer_name="$2"
    shift 2

    # Defaults
    local org_name="$customer_name"
    local repo_name="example-repo"
    local ingress_host=""
    local template_branch="$CUSTOMER_TEMPLATE_BRANCH_DEFAULT"
    local force_recreate="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org-name)        org_name="$2";        shift 2 ;;
            --repo-name)       repo_name="$2";       shift 2 ;;
            --ingress-host)    ingress_host="$2";    shift 2 ;;
            --template-branch) template_branch="$2"; shift 2 ;;
            --force-recreate)  force_recreate="true"; shift ;;
            *) log_error "Unknown argument: $1"; usage ;;
        esac
    done

    # Namespace is always <orgName>-<repoName> — matches the ApplicationSet template
    local namespace="${org_name}-${repo_name}"

    # Confirm destructive operation before doing anything else
    if [[ "$force_recreate" == "true" ]]; then
        log_warn "--force-recreate will DELETE and re-create the Gitea org '${org_name}' and repo '${org_name}/${repo_name}'."
        log_warn "All existing repository content and settings will be lost."
        printf "Type the org name to confirm deletion [%s]: " "$org_name"
        local confirm_input
        read -r confirm_input
        if [[ "$confirm_input" != "$org_name" ]]; then
            log_error "Confirmation failed — aborting."
            exit 1
        fi
        log_info "Confirmed. Proceeding with --force-recreate."
    fi

    [[ ! -f "$env_file" ]] && { log_error "Env file not found: $env_file"; exit 1; }
    [[ "$env_file" != /* ]] && env_file="$PWD/$env_file"

    check_dependencies
    load_env_file "$env_file"

    local overlay_dir
    overlay_dir="$(cd "$(dirname "$env_file")" && pwd)"

    [[ -z "$ingress_host" ]] && ingress_host="${namespace}.${CLUSTER_EXTERNAL_DOMAIN}"

    export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    export OVERLAY_DIR="$overlay_dir"

    local talosconfig="$OVERLAY_DIR/talos/talosconfig"
    [[ -f "$talosconfig" ]] && export TALOSCONFIG="$talosconfig"

    local gitea_api_url="https://${GITEA_DOMAIN_NAME}/api/v1"

    log_info "============================================================"
    log_info "Customer bootstrap"
    log_info "  Customer name     : $customer_name"
    log_info "  Gitea org         : $org_name"
    log_info "  Gitea repo        : $repo_name"
    log_info "  Namespace         : $namespace  (derived: <orgName>-<repoName>)"
    log_info "  Ingress host      : $ingress_host"
    log_info "  Template repo     : $CUSTOMER_TEMPLATE_REPO"
    log_info "  Template branch   : $template_branch"
    log_info "  Gitea API         : $gitea_api_url"
    log_info "============================================================"
    echo ""

    # ------------------------------------------------------------------
    # 1. Gitea admin credentials + temporary token
    # ------------------------------------------------------------------
    log_info "=== Step 1/7: Gitea credentials ==="
    local credentials
    credentials=$(fetch_gitea_admin_credentials) || exit 1
    GITEA_CREDENTIALS="$credentials"
    GITEA_API_URL="$gitea_api_url"

    local token_result
    local token_name="customer-bootstrap-$(date +%s)"
    token_result=$(create_gitea_token "$credentials" "$gitea_api_url" "$token_name" "$ADMIN_TOKEN_SCOPES") || exit 1
    GITEA_TOKEN_ID="${token_result%%|*}"
    local token="${token_result#*|}"
    echo ""

    # ------------------------------------------------------------------
    # 2. Gitea org
    # ------------------------------------------------------------------
    log_info "=== Step 2/7: Gitea organisation ==="
    local org_status
    org_status=$(check_gitea_organization "$org_name" "$gitea_api_url" "$token")

    if [[ "$org_status" == "200" ]]; then
        if [[ "$force_recreate" == "true" ]]; then
            local repo_check
            repo_check=$(check_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token")
            [[ "$repo_check" == "200" ]] && \
                delete_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token"
            delete_gitea_organization "$org_name" "$gitea_api_url" "$token"
            create_gitea_organization "$org_name" "$gitea_api_url" "$token" "$customer_name" || exit 1
        else
            log_success "Org already exists: $org_name"
        fi
    elif [[ "$org_status" == "404" ]]; then
        create_gitea_organization "$org_name" "$gitea_api_url" "$token" "$customer_name" || exit 1
    else
        log_error "Unexpected status checking org: $org_status"; exit 1
    fi

    # Add ArgoCD service account as an org member so it can access customer repos
    add_user_to_org "$org_name" "$ARGOCD_SVC_USER" "$gitea_api_url" "$token" || true

    # Add registry-pull service account so Talos containerd (RegistryAuthConfig)
    # can pull images from this org's container registry cluster-wide.
    add_user_to_org "$org_name" "$REGISTRY_PULL_USER" "$gitea_api_url" "$token" || true
    echo ""

    # ------------------------------------------------------------------
    # 3. Gitea repo
    # ------------------------------------------------------------------
    log_info "=== Step 3/7: Gitea repository ==="
    local repo_status
    repo_status=$(check_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token")

    if [[ "$repo_status" == "200" ]]; then
        if [[ "$force_recreate" == "true" ]]; then
            delete_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token"
            create_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token" || exit 1
        else
            log_success "Repo already exists: $org_name/$repo_name"
        fi
    elif [[ "$repo_status" == "404" ]]; then
        create_gitea_repository "$org_name" "$repo_name" "$gitea_api_url" "$token" || exit 1
    else
        log_error "Unexpected status checking repo: $repo_status"; exit 1
    fi
    echo ""

    # ------------------------------------------------------------------
    # 4. Push example code to Gitea
    # ------------------------------------------------------------------
    log_info "=== Step 4/7: Push example application to Gitea ==="

    # Shallow-clone the template repository into a temp dir
    local template_dir
    template_dir=$(mktemp -d "${TMPDIR:-/tmp}/customer-template.XXXXXX")

    log_info "Cloning template: $CUSTOMER_TEMPLATE_REPO (branch: $template_branch)"
    if ! git clone --depth=1 --branch "$template_branch" "$CUSTOMER_TEMPLATE_REPO" "$template_dir" 2>&1; then
        log_error "Failed to clone template repository"
        rm -rf "$template_dir"
        exit 1
    fi
    log_success "Template cloned"

    # Substitute placeholders and push to the customer's Gitea repo
    local push_dir
    push_dir=$(mktemp -d "${TMPDIR:-/tmp}/customer-bootstrap.XXXXXX")

    substitute_placeholders \
        "$template_dir" \
        "$push_dir" \
        "$GITEA_DOMAIN_NAME" \
        "$org_name" \
        "$repo_name" \
        "$namespace" \
        "$CLUSTER_EXTERNAL_DOMAIN" \
        "$customer_name" \
        "$ingress_host"

    push_dir_to_gitea_repo \
        "$push_dir" \
        "$org_name" \
        "$repo_name" \
        "$credentials" \
        "$GITEA_DOMAIN_NAME" \
        "main"

    rm -rf "$template_dir" "$push_dir"
    echo ""

    # ------------------------------------------------------------------
    # 5. Customer descriptor + ArgoCD AppProject
    # ------------------------------------------------------------------
    log_info "=== Step 5/7: Customer descriptor + ArgoCD AppProject ==="

    # Commit _rendered/customers/<name>/<name>.yaml to the cluster-services repo.
    # The customer-apps ApplicationSet reads from _rendered/customers/ — the same
    # rendered path that render-overlay.sh produces and push-to-gitea.sh pushes.
    local cluster_services_owner="${GITEA_CLUSTER_GITEA_ORG_NAME}"
    local cluster_services_repo="${GITEA_CLUSTER_SERVICES_REPO_NAME}"
    local descriptor_path="_rendered/customers/${customer_name}/${customer_name}.yaml"
    local descriptor_content
    descriptor_content=$(cat <<YAML
customerName: ${customer_name}
gitea:
  orgName: ${org_name}
YAML
)

    # Write the descriptor to the local overlay under _rendered/customers/ so it
    # is included in the next push-to-gitea push and matches the ArgoCD-watched path.
    local local_descriptor_dir="${overlay_dir}/_rendered/customers/${customer_name}"
    local local_descriptor_file="${local_descriptor_dir}/${customer_name}.yaml"
    mkdir -p "$local_descriptor_dir"
    printf '%s' "$descriptor_content" > "$local_descriptor_file"
    log_success "Customer descriptor written locally: $local_descriptor_file"

    # Also commit it directly to the Gitea cluster-services repo via the API
    # so ArgoCD picks it up immediately without waiting for the next push.
    create_or_update_gitea_file \
        "$cluster_services_owner" \
        "$cluster_services_repo" \
        "$descriptor_path" \
        "$descriptor_content" \
        "feat(customers): add descriptor for customer ${customer_name}" \
        "$gitea_api_url" \
        "$token" || exit 1

    # Create (or update) the ArgoCD AppProject for this customer.
    # - destinations: org-name-* namespace glob (covers all current + future repos)
    # - sourceRepos: only this customer's Gitea org
    # - no cluster-scoped resources allowed
    log_info "Applying ArgoCD AppProject: customer-${customer_name}"
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: customer-${customer_name}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    managed-by: bootstrap-customer
spec:
  description: "ArgoCD project for customer ${customer_name} (org: ${org_name})"
  sourceRepos:
    - "https://${GITEA_DOMAIN_NAME}/${org_name}/*"
  destinations:
    - namespace: "${org_name}-*"
      server: "*"
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
EOF
    log_success "AppProject customer-${customer_name} applied"
    echo ""

    # ------------------------------------------------------------------
    # 6. Kubernetes namespace + RBAC + image pull secret
    # ------------------------------------------------------------------
    log_info "=== Step 6/7: Kubernetes namespace + RBAC ==="
    apply_customer_namespace "$namespace"
    apply_runner_rbac "$namespace"

    # Create an imagePullSecret for the Gitea registry in the customer namespace
    # and patch the default ServiceAccount to reference it.
    # NOTE: Talos RegistryAuthConfig is set cluster-wide (apply-node-registry-config.sh)
    # but containerd v2 ignores registry.configs.auth when config_path is also set
    # (see containerd docs). This Kubernetes-native approach is the reliable fallback.
    apply_registry_pull_secret "$namespace"
    echo ""

    # ------------------------------------------------------------------
    # 7. CI service user + Actions variables + secrets
    # ------------------------------------------------------------------
    log_info "=== Step 7/7: CI service user + Actions variables + secrets ==="

    # Variables (plain text, non-sensitive)
    set_gitea_repo_variable "$org_name" "$repo_name" "REGISTRY_DOMAIN" "$GITEA_DOMAIN_NAME" "$gitea_api_url" "$token"
    set_gitea_repo_variable "$org_name" "$repo_name" "CUSTOMER_ORG"    "$org_name"          "$gitea_api_url" "$token"
    set_gitea_repo_variable "$org_name" "$repo_name" "APP_NAME"        "$repo_name"         "$gitea_api_url" "$token"
    set_gitea_repo_variable "$org_name" "$repo_name" "NAMESPACE"       "$namespace"         "$gitea_api_url" "$token"

    # Create a dedicated CI service user for this customer org.
    # The user gets write access via the org's Owners team and holds a
    # write:package token used for container registry pushes in CI.
    # Using a per-customer user (instead of the cluster admin) limits blast
    # radius: a leaked token only has access to one org's packages.
    local ci_username="ci-${org_name}"
    local ci_email="ci-${org_name}@cluster.local"
    local ci_password
    ci_password=$(openssl rand -base64 32 | tr -d '+/=' | head -c 40)

    create_or_ensure_gitea_user \
        "$ci_username" "$ci_email" "$ci_password" \
        "$gitea_api_url" "$token" || exit 1

    # Give the CI user write access by adding them to the org's Owners team
    add_user_to_org "$org_name" "$ci_username" "$gitea_api_url" "$token" || exit 1

    # Create a write:package token as the CI user (authenticating as that user)
    # Delete any pre-existing token with the same name first (idempotent re-run)
    local pkg_token_name="ci-package-${org_name}"
    curl -k -s -o /dev/null -X DELETE \
        -u "${ci_username}:${ci_password}" \
        "$gitea_api_url/users/$ci_username/tokens/$pkg_token_name" || true

    local pkg_token_resp
    pkg_token_resp=$(curl -k -s -S -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -u "${ci_username}:${ci_password}" \
        -d "{\"name\":\"$pkg_token_name\",\"scopes\":[\"write:package\"]}" \
        "$gitea_api_url/users/$ci_username/tokens")

    local pkg_token_code pkg_token_body pkg_token_value
    pkg_token_code=$(get_http_code "$pkg_token_resp")
    pkg_token_body=$(get_http_body "$pkg_token_resp")

    if [[ "$pkg_token_code" != "201" ]]; then
        log_error "Failed to create package token for $ci_username (HTTP $pkg_token_code): $pkg_token_body"
        exit 1
    fi
    pkg_token_value=$(echo "$pkg_token_body" | jq -r '.sha1')
    log_success "Package token created for CI user '$ci_username'"

    # Store credentials as org-level secrets so every repo in this org inherits
    # them automatically — no per-repo wiring needed for future repos.
    # Gitea 1.22+ injects org secrets into workflow contexts; org variables are
    # NOT inherited by repo workflows, so both are stored as secrets.
    #   CI_REGISTRY_TOKEN  — write:package token for docker login
    #   CI_REGISTRY_USER   — username (stored as secret for org-level inheritance)
    set_gitea_org_secret   "$org_name" "CI_REGISTRY_TOKEN" "$pkg_token_value" "$gitea_api_url" "$token" || exit 1
    set_gitea_org_secret   "$org_name" "CI_REGISTRY_USER"  "$ci_username"     "$gitea_api_url" "$token" || exit 1
    echo ""

    # ------------------------------------------------------------------
    # Done
    # ------------------------------------------------------------------
    log_success "============================================================"
    log_success "Customer '$customer_name' bootstrapped successfully!"
    log_success ""
    log_success "  Customer     : ${customer_name}"
    log_success "  Gitea org    : ${org_name}"
    log_success "  Gitea repo   : https://${GITEA_DOMAIN_NAME}/${org_name}/${repo_name}"
    log_success "  Namespace    : ${namespace}  (ArgoCD will create it on first sync)"
    log_success "  Ingress      : https://${ingress_host}"
    log_success "  AppProject   : customer-${customer_name}  (scoped to ${org_name}-* namespaces)"
    log_success "  Descriptor   : _rendered/customers/${customer_name}/${customer_name}.yaml  (in cluster-services)"
    log_success ""
    log_success "Next steps:"
    log_success "  1. The 'customer-apps' ApplicationSet will scan org '${org_name}' within"
    log_success "     ~3 minutes and create an Application for each repo with a deploy/ dir."
    log_success "     Add more repos to the org and they are picked up automatically."
    log_success "  2. Push a commit to the Gitea repo to trigger the CI workflow"
    log_success "     (build image → push → rollout restart)."
    log_success ""
    log_success "  If the ApplicationSet is not yet deployed, render + apply the overlay:"
    log_success "    ./talos-bootstraper/adminTasks/render-overlay.sh <ENV_FILE>"
    log_success "    kubectl apply -f overlays/<cluster>/_rendered/customerApps/"
    log_success "============================================================"
}

main "$@"
