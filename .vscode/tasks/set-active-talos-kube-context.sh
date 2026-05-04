#!/usr/bin/env bash
set -euo pipefail

env_file="${1:?env file path is required}"
workspace_dir="${2:-$(pwd)}"

# Resolve env_file to an absolute path so it works regardless of how it was passed
[[ "$env_file" = /* ]] || env_file="$workspace_dir/$env_file"

overlay_dir=$(dirname "$env_file")
active_dir="$workspace_dir/.vscode/current"

mkdir -p "$active_dir"
ln -sfn "$overlay_dir/talos/talosconfig" "$active_dir/talosconfig"

first_node=$(yq -r '.contexts[].nodes[0]' "$active_dir/talosconfig" | head -n1)
if [ -z "$first_node" ] || [ "$first_node" = "null" ]; then
  echo "ERROR: Could not determine first Talos node from $active_dir/talosconfig" >&2
  exit 1
fi

talosctl --talosconfig "$active_dir/talosconfig" kubeconfig "$overlay_dir/talos/kubeconfig" --nodes "$first_node" --merge
ln -sfn "$overlay_dir/talos/kubeconfig" "$active_dir/kubeconfig"

echo "Active TALOSCONFIG: $active_dir/talosconfig"
echo "Active KUBECONFIG:  $active_dir/kubeconfig (→ $overlay_dir/talos/kubeconfig)"
echo "Selected node: $first_node"
echo "Open a new terminal to pick up updated env vars."
