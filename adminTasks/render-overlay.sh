#!/usr/bin/env zsh
set -euo pipefail

################################################################################
# renderer.sh
#
# Usage: renderer.sh <ENV_FILE> [--dry-run]
#
# This script loads an environment file (e.g. overlays/yourCluster/yourCluster.env),
# collects YAML files from talos-bootstraper/base/* (depth=1) and the overlay's immediate
# subdirectories (recursive), renders them with envsubst, merges collisions
# (overlay wins) using yq, and outputs to the overlay's _rendered/ directory.
################################################################################

# Get script directory and load logging library
SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=./lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to load logging.sh"; exit 1; }

# Usage message
usage() {
    cat <<EOF
Usage: $(basename "$0") <ENV_FILE> [VAR=value ...] [--dry-run]

Arguments:
  ENV_FILE    Path to the environment file (e.g. talos/overlays/yourCluster/yourCluster.env)
  VAR=value   Environment variable overrides (can specify multiple)
  --dry-run   Show what would be done without writing files

Requirements:
  - yq (mikefarah/yq)
  - envsubst

Example:
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env GITEA_CLUSTER_SERVICES_REPO_URL=git://custom-url
  $(basename "$0") talos/overlays/yourCluster/yourCluster.env VAR1=value1 VAR2=value2 --dry-run
EOF
    exit 1
}

# Check required tools
check_dependencies() {
    local missing=()
    
    if ! command -v yq &>/dev/null; then
        missing+=("yq (https://github.com/mikefarah/yq)")
    fi
    
    if ! command -v envsubst &>/dev/null; then
        missing+=("envsubst (usually in gettext package)")
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
    
    # Note: Validation is skipped for performance. Ensure the env file is trusted.
    # The file should contain only export statements and variable assignments.
    
    # Source the file with allexport to export all variables
    set -o allexport
    # shellcheck disable=SC1090
    source "$env_file"
    set +o allexport
    
    # Verify OVERLAY_NAME was set
    if [[ -z "${OVERLAY_NAME:-}" ]]; then
        log_error "OVERLAY_NAME not set in environment file"
        exit 1
    fi
    
    log_success "Loaded environment for overlay: $OVERLAY_NAME"
}

prepare_vars() {

    #Build whitelist of all exported variables
    #This is needed to avoid envsubst replacing variables that are not defined in the environment, but are present in the manifests/charts
    # Build whitelist of variables from the env file and any overrides
    local env_vars=()
    # Extract variable names from the env file (ignore comments and blank lines)
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            # Use bash BASH_REMATCH or zsh match array depending on shell
            local captured="${BASH_REMATCH[1]:-${match[1]}}"
            env_vars+=("$captured")
        elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            # Use bash BASH_REMATCH or zsh match array depending on shell
            local captured="${BASH_REMATCH[1]:-${match[1]}}"
            env_vars+=("$captured")
        fi
    done < "$env_file"

    # Add override variable names (from env_overrides array, if present)
    if [[ ${#env_overrides[@]:-} -gt 0 ]]; then
        for override in "${env_overrides[@]}"; do
            local var_name="${override%%=*}"
            env_vars+=("$var_name")
        done
    fi

    # Remove duplicates
    env_vars=("${(@u)env_vars}")

    # Build ENVSUBST_VARS for envsubst (colon-separated, e.g. $FOO:$BAR)
    ENVSUBST_VARS=$(printf '$%s:' "${env_vars[@]}")
    ENVSUBST_VARS="${ENVSUBST_VARS%:}"

    export ENVSUBST_VARS
}

# Find YAML files in a directory with specified depth
find_yaml_files() {
    local dir="$1"
    local max_depth="$2"
    
    if [[ ! -d "$dir" ]]; then
        return
    fi
    
    if [[ "$max_depth" == "1" ]]; then
        find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    else
        find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
    fi
}

# Collect base YAML files (depth=1 in each component subdir)
collect_base_files() {
    local base_dir="$1"
    local -a files=()
    
    if [[ ! -d "$base_dir" ]]; then
        log_warn "Base directory not found: $base_dir"
        return
    fi
    
    # Iterate through immediate subdirectories of base
    for component_dir in "$base_dir"/*; do
        [[ ! -d "$component_dir" ]] && continue
        
        local component_name=$(basename "$component_dir")
        
        # Find YAML files at depth 1 in this component
        while IFS= read -r file; do
            [[ -n "$file" ]] && files+=("$file")
        done < <(find_yaml_files "$component_dir" 1)
    done
    
    printf '%s\n' "${files[@]}"
}

# Collect overlay YAML files (recursive in each immediate subdir)
collect_overlay_files() {
    local overlay_dir="$1"
    local -a files=()
    
    if [[ ! -d "$overlay_dir" ]]; then
        log_warn "Overlay directory not found: $overlay_dir"
        return
    fi
    
    # Iterate through immediate subdirectories of overlay
    # Exclude directories ending with "-rendered"
    for component_dir in "$overlay_dir"/*; do
        [[ ! -d "$component_dir" ]] && continue
        
        local component_name=$(basename "$component_dir")
        
        # Skip rendered output directory
        [[ "$component_name" == "_rendered" ]] && continue
        
        # Find YAML files recursively in this component
        while IFS= read -r file; do
            [[ -n "$file" ]] && files+=("$file")
        done < <(find_yaml_files "$component_dir" 999)
    done
    
    printf '%s\n' "${files[@]}"
}

# Get component and relative path for a file
get_file_info() {
    local file="$1"
    local base_dir="$2"
    
    # Remove base_dir prefix and get component (first dir after base)
    local rel_path="${file#$base_dir/}"
    local component="${rel_path%%/*}"
    local filename="${rel_path#*/}"
    
    echo "$component|$filename"
}

# Check if a component or file is excluded via EXCLUDED_BASE
# Exclusions are matched against the rendered output path, regardless of whether
# the source comes from base/, overlays/, or a merge of both.
is_excluded() {
    local component="$1"
    local filename="$2"

    if [[ ${#EXCLUDED_BASE[@]:-0} -eq 0 ]]; then
        return 1
    fi

    for entry in "${EXCLUDED_BASE[@]}"; do
        if [[ "$entry" == */* ]]; then
            # File-level exclusion: match component/filename
            [[ "$component/$filename" == "$entry" ]] && return 0
        else
            # Component-level exclusion: match component name
            [[ "$component" == "$entry" ]] && return 0
        fi
    done

    return 1
}

# Render a YAML file with envsubst
render_yaml() {
    local input_file="$1"
    local output_file="$2"
    local dry_run="$3"
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "  [DRY-RUN] Would render: $input_file -> $output_file"
        return
    fi
    
    # Create output directory
    mkdir -p "$(dirname "$output_file")"
    
    # Render with envsubst
    # Use || true to avoid failures from set -e if envsubst encounters issues
    if ! envsubst "$ENVSUBST_VARS" < "$input_file" > "$output_file" 2>/dev/null; then
        log_warn "envsubst failed for $input_file, copying as-is"
        cp "$input_file" "$output_file"
    fi
}

# Merge two YAML files using yq (overlay wins)
merge_yaml_files() {
    local base_file="$1"
    local overlay_file="$2"
    local output_file="$3"
    local dry_run="$4"
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "  [DRY-RUN] Would merge: $base_file + $overlay_file -> $output_file"
        return
    fi
    
    # Create output directory
    mkdir -p "$(dirname "$output_file")"
    
    # Render both files first
    local base_rendered=$(mktemp)
    local overlay_rendered=$(mktemp)
    
    if ! envsubst "$ENVSUBST_VARS" < "$base_file" > "$base_rendered" 2>/dev/null; then
        log_warn "envsubst failed for base file $base_file, using as-is"
        cp "$base_file" "$base_rendered"
    fi
    
    if ! envsubst "$ENVSUBST_VARS" < "$overlay_file" > "$overlay_rendered" 2>/dev/null; then
        log_warn "envsubst failed for overlay file $overlay_file, using as-is"
        cp "$overlay_file" "$overlay_rendered"
    fi
    
    # Count documents in the base file to decide merge strategy
    local base_doc_count
    base_doc_count=$(yq e 'di + 1' "$base_rendered" 2>/dev/null | tail -1)
    base_doc_count=${base_doc_count:-1}

    if [[ "$base_doc_count" -le 1 ]]; then
        # Single-document file: simple merge (original behaviour, works for Helm values etc.)
        if ! yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "$base_rendered" "$overlay_rendered" > "$output_file" 2>/dev/null; then
            log_error "yq merge failed for $base_file + $overlay_file"
            rm -f "$base_rendered" "$overlay_rendered"
            return 1
        fi
    else
        # Multi-document base: split into individual documents, match each by kind+metadata.name
        # against the overlay, merge matched pairs, pass unmatched base docs through unchanged,
        # then concatenate everything back together.
        : > "$output_file"
        local first_doc=true
        local base_doc overlay_match merged_doc kind name
        for (( i=0; i<base_doc_count; i++ )); do
            base_doc=$(mktemp)
            overlay_match=$(mktemp)
            merged_doc=$(mktemp)

            # Extract document i from base
            yq e "select(di == $i)" "$base_rendered" > "$base_doc" 2>/dev/null

            # Get kind and name for matching
            kind=$(yq e '.kind // ""' "$base_doc" 2>/dev/null)
            name=$(yq e '.metadata.name // ""' "$base_doc" 2>/dev/null)

            # Find matching document in overlay (match by kind + metadata.name)
            yq e "select(.kind == \"$kind\" and .metadata.name == \"$name\")" \
                "$overlay_rendered" > "$overlay_match" 2>/dev/null

            if [[ -s "$overlay_match" ]]; then
                # Matching overlay doc found: merge (overlay wins)
                yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
                    "$base_doc" "$overlay_match" > "$merged_doc" 2>/dev/null \
                    || cp "$base_doc" "$merged_doc"
            else
                # No match: keep base document unchanged
                cp "$base_doc" "$merged_doc"
            fi

            # Append to output with document separator between docs
            if [[ "$first_doc" == "true" ]]; then
                cat "$merged_doc" >> "$output_file"
                first_doc=false
            else
                printf '\n---\n' >> "$output_file"
                cat "$merged_doc" >> "$output_file"
            fi

            rm -f "$base_doc" "$overlay_match" "$merged_doc"
        done

        if [[ "$first_doc" == "true" ]]; then
            # Nothing was written (base_doc_count was 0 somehow); fall back to base only
            cp "$base_rendered" "$output_file"
        fi
    fi
    
    # Cleanup temp files
    rm -f "$base_rendered" "$overlay_rendered"
}

# Main processing function
process_files() {
    local repo_root="$1"
    local base_dir="$2"
    local overlay_dir="$3"
    local output_dir="$4"
    local dry_run="$5"
    
    # Collect all files
    log_info "Collecting YAML files..."
    
    local -a base_files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] && base_files+=("$file")
    done < <(collect_base_files "$base_dir")
    
    local -a overlay_files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] && overlay_files+=("$file")
    done < <(collect_overlay_files "$overlay_dir")
    
    log_info "Found ${#base_files[@]} base files and ${#overlay_files[@]} overlay files"
    
    # Build maps of files by component|filename
    typeset -A base_map
    typeset -A overlay_map
    
    for file in "${base_files[@]}"; do
        local info=$(get_file_info "$file" "$base_dir")
        base_map[$info]="$file"
    done
    
    for file in "${overlay_files[@]}"; do
        local info=$(get_file_info "$file" "$overlay_dir")
        overlay_map[$info]="$file"
    done
    
    # Ensure output directory exists
    # Files are overwritten in-place rather than rm -rf to preserve files
    # generated by other scripts (e.g., per-node Talos machine configs)
    if [[ "$dry_run" == "false" ]]; then
        mkdir -p "$output_dir"
    else
        log_info "[DRY-RUN] Would write to: $output_dir"
    fi
    
    # Process all unique component|filename combinations
    local -A processed
    local merged_count=0
    local base_only_count=0
    local overlay_only_count=0
    local excluded_count=0
    
    # Get all unique keys
    local -a all_keys=()
    
    # Temporarily disable pipefail for array operations
    set +e
    for key in "${(@k)base_map}"; do
        all_keys+=("$key")
    done
    for key in "${(@k)overlay_map}"; do
        if [[ -z "${processed[$key]:-}" ]]; then
            all_keys+=("$key")
        fi
        processed[$key]=1
    done
    set -e
    
    # Sort keys for deterministic processing
    all_keys=(${(o)all_keys})

    # Remove rendered output for entries that are now excluded (cleanup from previous renders)
    if [[ "$dry_run" == "false" ]]; then
        for key in "${all_keys[@]}"; do
            local component="${key%%|*}"
            local filename="${key#*|}"
            if is_excluded "$component" "$filename"; then
                local target="$output_dir/$component/$filename"
                [[ -f "$target" ]] && rm -f "$target"
            fi
        done
        find "$output_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi
    
    log_info "Processing files..."
    
    local file_number=0
    for key in "${all_keys[@]}"; do
        file_number=$((file_number + 1))
        local component="${key%%|*}"
        local filename="${key#*|}"
        local output_file="$output_dir/$component/$filename"
        
        local base_file="${base_map[$key]:-}"
        local overlay_file="${overlay_map[$key]:-}"
        
        if is_excluded "$component" "$filename"; then
            log_info "[$file_number/${#all_keys[@]}] Skipping: $component/$filename (excluded)"
            excluded_count=$((excluded_count + 1))
            continue
        fi
        
        if [[ -n "$base_file" && -n "$overlay_file" ]]; then
            log_info "[$file_number/${#all_keys[@]}] Merging: $component/$filename (base + overlay)"
            if merge_yaml_files "$base_file" "$overlay_file" "$output_file" "$dry_run"; then
                merged_count=$((merged_count + 1))
            else
                log_warn "Merge failed, skipping"
            fi
        elif [[ -n "$base_file" ]]; then
            log_info "[$file_number/${#all_keys[@]}] Rendering: $component/$filename (base)"
            if render_yaml "$base_file" "$output_file" "$dry_run"; then
                base_only_count=$((base_only_count + 1))
            else
                log_warn "Render failed, skipping"
            fi
        elif [[ -n "$overlay_file" ]]; then
            log_info "[$file_number/${#all_keys[@]}] Rendering: $component/$filename (overlay)"
            if render_yaml "$overlay_file" "$output_file" "$dry_run"; then
                overlay_only_count=$((overlay_only_count + 1))
            else
                log_warn "Render failed, skipping"
            fi
        fi
    done
    
    # Summary
    echo ""
    log_success "Processing complete!"
    log_info "  Base-only files:    $base_only_count"
    log_info "  Overlay-only files: $overlay_only_count"
    log_info "  Merged files:       $merged_count"
    log_info "  Excluded files:     $excluded_count"
    log_info "  Total files:        $((base_only_count + overlay_only_count + merged_count))"
    
    if [[ "$dry_run" == "false" ]]; then
        log_success "Output written to: $output_dir"
    else
        log_info "[DRY-RUN] No files were written"
    fi
}

################################################################################
# Main
################################################################################

main() {
    # Parse arguments
    if [[ $# -lt 1 ]]; then
        usage
    fi
    
    local env_file="$1"
    shift
    
    local dry_run="false"
    local -a env_overrides=()
    
    # Parse remaining arguments for overrides and --dry-run
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--dry-run" ]]; then
            dry_run="true"
        elif [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*=.* ]]; then
            # This is an environment variable override (VAR=value format)
            env_overrides+=("$1")
        else
            log_error "Invalid argument: $1"
            usage
        fi
        shift
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
    
    # Apply environment variable overrides
    if [[ ${#env_overrides[@]} -gt 0 ]]; then
        log_info "Applying environment variable overrides:"
        for override in "${env_overrides[@]}"; do
            local var_name="${override%%=*}"
            local var_value="${override#*=}"
            log_info "  $var_name=$var_value"
            export "$var_name=$var_value"
        done
    fi

    # Prepare vars to be used by envsubst
    prepare_vars
    
    # Determine directories
    local overlay_dir=$(dirname "$env_file")
    # Script lives in adminTasks/; parent directory is the repo root (contains base/).
    local talos_submodule_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    
    if [[ ! -d "$talos_submodule_root/base" ]]; then
        log_error "Could not find base directory at: $talos_submodule_root/base"
        exit 1
    fi
    
    local base_dir="$talos_submodule_root/base"
    # Output rendered files into _rendered/ inside the overlay directory.
    # This keeps rendered output co-located with the overlay config so that
    # overlay submodules are self-contained for ArgoCD.
    local output_dir="$overlay_dir/_rendered"
    
    log_info "Repository root:   $talos_submodule_root"
    log_info "Base directory:    $base_dir"
    log_info "Overlay directory: $overlay_dir"
    log_info "Output directory:  $output_dir"
    echo ""
    
    # Process files
    process_files "$talos_submodule_root" "$base_dir" "$overlay_dir" "$output_dir" "$dry_run"
}

main "$@"
