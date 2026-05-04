#!/usr/bin/env bash
# Prepares one or more Kubernetes nodes for planned downtime (~1h maintenance):
#   - Cordons the node
#   - Live-migrates KubeVirt VMs (or gracefully stops non-migratable ones)
#   - Handles CNPG single-instance primary switchover
#   - Checks for Longhorn manually-attached volumes
#   - Drains the node (Longhorn PDB safety-checked, --timeout=0)
#   - Reports when safe to shut down, and how to uncordon on return
#
# Usage: prepare-node-for-downtime.sh <env-file> <workspace-folder>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../adminTasks/lib" && pwd)"

# shellcheck source=/dev/null
source "$LIB_DIR/logging.sh"

ENV_FILE="${1:?env file path is required}"
WORKSPACE="${2:?workspace folder path is required}"
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"

if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Env file not found: $ENV_FILE"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ── KUBECONFIG resolution ─────────────────────────────────────────────────────
if [[ -f "$WORKSPACE/.vscode/current/${OVERLAY_NAME}.kubeconfig" ]]; then
  export KUBECONFIG="$WORKSPACE/.vscode/current/${OVERLAY_NAME}.kubeconfig"
elif [[ -f "$WORKSPACE/.vscode/current/kubeconfig" ]]; then
  export KUBECONFIG="$WORKSPACE/.vscode/current/kubeconfig"
elif [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]]; then
  : # already set and valid
elif [[ -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
else
  log_error "No kubeconfig found. Run 'Set Active Talos/Kube Context' first, or set KUBECONFIG."
  exit 1
fi

# ── Tool checks ───────────────────────────────────────────────────────────────
for tool in kubectl jq; do
  if ! command -v "$tool" &>/dev/null; then
    log_error "$tool is required but not found in PATH."
    exit 1
  fi
done

VIRTCTL_AVAILABLE=false
if command -v virtctl &>/dev/null; then
  VIRTCTL_AVAILABLE=true
else
  log_warn "virtctl not found in PATH."
  log_warn "KubeVirt VMs with evictionStrategy=LiveMigrate will BLOCK the drain indefinitely"
  log_warn "(allowWorkloadDisruption=false is set in the KubeVirt CR). Install virtctl to"
  log_warn "enable automatic live migration, or trigger migrations manually via the UI."
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Prepare Node for Downtime"
echo "  Overlay : $OVERLAY_NAME"
echo "  Kubeconfig: $KUBECONFIG"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Node selection ────────────────────────────────────────────────────────────
log_info "Fetching cluster nodes..."
mapfile -t ALL_NODES < <(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name')

if [[ ${#ALL_NODES[@]} -eq 0 ]]; then
  log_error "No nodes found. Is the kubeconfig pointing to the right cluster?"
  exit 1
fi

echo "Available nodes:"
for i in "${!ALL_NODES[@]}"; do
  STATUS=$(kubectl get node "${ALL_NODES[$i]}" --no-headers | awk '{print $2}')
  ROLES=$(kubectl get node "${ALL_NODES[$i]}" -o json | \
    jq -r '[.metadata.labels | to_entries[] |
            select(.key | startswith("node-role.kubernetes.io/")) |
            .key | ltrimstr("node-role.kubernetes.io/")] | join(",")' 2>/dev/null || echo "")
  printf "  [%d] %-42s %-14s %s\n" "$((i + 1))" "${ALL_NODES[$i]}" "$STATUS" "$ROLES"
done
echo ""
echo "Enter node numbers to prepare (space-separated, e.g. '1 3'), or 'all':"
read -r SELECTION

SELECTED_NODES=()
if [[ "$SELECTION" == "all" ]]; then
  SELECTED_NODES=("${ALL_NODES[@]}")
else
  for NUM in $SELECTION; do
    if [[ "$NUM" =~ ^[0-9]+$ ]] && (( NUM >= 1 && NUM <= ${#ALL_NODES[@]} )); then
      SELECTED_NODES+=("${ALL_NODES[$((NUM - 1))]}")
    else
      log_warn "'$NUM' is not a valid selection, skipping."
    fi
  done
fi

if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
  log_error "No valid nodes selected. Aborting."
  exit 1
fi

# ── Pre-flight report ─────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────"
echo "  Pre-flight report"
echo "────────────────────────────────────────────────────────────"

PREFLIGHT_WARNINGS=()

for NODE in "${SELECTED_NODES[@]}"; do
  echo ""
  echo "  Node: $NODE"
  echo "  ──────────────────────────────────────────────────────"

  # KubeVirt VMIs on this node (field-selector on CRDs is unreliable; use jq)
  mapfile -t NODE_VMIS < <(kubectl get vmi -A -o json 2>/dev/null | \
    jq -r --arg node "$NODE" \
    '.items[] | select(.status.nodeName == $node) |
     "    \(.metadata.namespace)/\(.metadata.name)  strategy=\(.spec.evictionStrategy // "None")"' || true)
  if [[ ${#NODE_VMIS[@]} -gt 0 ]]; then
    echo "  KubeVirt VMs:"
    for vmi_line in "${NODE_VMIS[@]}"; do
      echo "$vmi_line"
      if echo "$vmi_line" | grep -q "strategy=None"; then
        VM_ID=$(echo "$vmi_line" | awk '{print $1}')
        PREFLIGHT_WARNINGS+=("$NODE: $VM_ID has no LiveMigrate strategy — will require graceful stop")
      fi
    done
  else
    echo "  KubeVirt VMs:  none"
  fi

  # CNPG pods on this node
  mapfile -t NODE_CNPG < <(kubectl get pods -A -l 'cnpg.io/cluster' -o json 2>/dev/null | \
    jq -r --arg node "$NODE" \
    '.items[] | select(.spec.nodeName == $node) |
     "\(.metadata.namespace) \(.metadata.labels["cnpg.io/cluster"]) \(.metadata.name)"' || true)
  if [[ ${#NODE_CNPG[@]} -gt 0 ]]; then
    echo "  CNPG pods:"
    for cnpg_line in "${NODE_CNPG[@]}"; do
      [[ -z "$cnpg_line" ]] && continue
      C_NS=$(echo "$cnpg_line"      | awk '{print $1}')
      C_CLUSTER=$(echo "$cnpg_line" | awk '{print $2}')
      C_POD=$(echo "$cnpg_line"     | awk '{print $3}')
      C_PRIMARY=$(kubectl get cluster "$C_CLUSTER" -n "$C_NS" \
        -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "unknown")
      C_INSTANCES=$(kubectl get cluster "$C_CLUSTER" -n "$C_NS" \
        -o jsonpath='{.spec.instances}' 2>/dev/null || echo "?")
      PRIMARY_LABEL=""
      [[ "$C_POD" == "$C_PRIMARY" ]] && PRIMARY_LABEL="  ⚠ PRIMARY"
      printf "    %s/%s  pod=%-35s instances=%s%s\n" \
        "$C_NS" "$C_CLUSTER" "$C_POD" "$C_INSTANCES" "$PRIMARY_LABEL"
      if [[ "$C_POD" == "$C_PRIMARY" && "$C_INSTANCES" == "1" ]]; then
        PREFLIGHT_WARNINGS+=("$NODE: CNPG '$C_NS/$C_CLUSTER' is a single-instance primary — will auto-scale to 2 for switchover")
      fi
    done
  else
    echo "  CNPG pods:     none"
  fi

  # Longhorn replicas on this node
  LH_REPLICAS=$(kubectl -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null | \
    jq --arg node "$NODE" '[.items[] | select(.spec.nodeID == $node)] | length' || echo "0")
  echo "  Longhorn replicas on node: $LH_REPLICAS"

  # Longhorn degraded volumes (cluster-wide)
  LH_DEGRADED=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null | \
    jq '[.items[] | select(.status.robustness != "healthy" and .status.robustness != "")] | length' \
    || echo "0")
  if [[ "$LH_DEGRADED" -gt 0 ]]; then
    echo "  Longhorn degraded volumes: $LH_DEGRADED  ⚠"
    PREFLIGHT_WARNINGS+=("Cluster-wide: $LH_DEGRADED Longhorn volume(s) already degraded — investigate before draining")
  else
    echo "  Longhorn degraded volumes: 0"
  fi

  # Evictable pods (excluding DaemonSet-owned)
  EVICTABLE=$(kubectl get pods -A -o json 2>/dev/null | \
    jq --arg node "$NODE" \
    '[.items[] | select(.spec.nodeName == $node) |
      select((.metadata.ownerReferences // []) | map(.kind) | contains(["DaemonSet"]) | not)] | length' \
    || echo "?")
  echo "  Evictable pods:            $EVICTABLE"
done

echo ""
if [[ ${#PREFLIGHT_WARNINGS[@]} -gt 0 ]]; then
  for W in "${PREFLIGHT_WARNINGS[@]}"; do
    log_warn "$W"
  done
  echo ""
fi

echo "Nodes that will be drained:"
for NODE in "${SELECTED_NODES[@]}"; do
  echo "  - $NODE"
done
echo ""
echo "Type 'yes' to proceed with the drain sequence:"
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  log_error "Aborted."
  exit 1
fi

# ── Per-node drain sequence ───────────────────────────────────────────────────
for NODE in "${SELECTED_NODES[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════════"
  log_info "Processing node: $NODE"
  echo "════════════════════════════════════════════════════════════"

  # ── a. Cordon ──────────────────────────────────────────────────────────────
  log_info "Cordoning $NODE..."
  kubectl cordon "$NODE"
  log_success "Node cordoned — no new pods will be scheduled here"

  # ── b. KubeVirt VMs ────────────────────────────────────────────────────────
  mapfile -t VMI_LIST < <(kubectl get vmi -A -o json 2>/dev/null | \
    jq -r --arg node "$NODE" \
    '.items[] | select(.status.nodeName == $node) |
     "\(.metadata.namespace) \(.metadata.name) \(.spec.evictionStrategy // "None")"' || true)

  for VMI_ENTRY in "${VMI_LIST[@]}"; do
    [[ -z "$VMI_ENTRY" ]] && continue
    VMI_NS=$(echo "$VMI_ENTRY"       | awk '{print $1}')
    VMI_NAME=$(echo "$VMI_ENTRY"     | awk '{print $2}')
    VMI_STRATEGY=$(echo "$VMI_ENTRY" | awk '{print $3}')

    if [[ "$VMI_STRATEGY" == "LiveMigrate" ]]; then
      # ── Live-migrate ────────────────────────────────────────────────────────
      if [[ "$VIRTCTL_AVAILABLE" == "true" ]]; then
        log_info "Triggering live migration: $VMI_NS/$VMI_NAME"
        virtctl migrate "$VMI_NAME" -n "$VMI_NS"

        DEADLINE=$(( $(date +%s) + 600 ))
        while true; do
          MIGRATION_STATE=$(kubectl get vmi "$VMI_NAME" -n "$VMI_NS" -o json 2>/dev/null | \
            jq '.status.migrationState // {}' || echo '{}')
          PHASE=$(echo "$MIGRATION_STATE"     | jq -r '.phase     // "Pending"' 2>/dev/null || echo "Pending")
          COMPLETED=$(echo "$MIGRATION_STATE" | jq -r '.completed // false'    2>/dev/null || echo "false")
          FAILED=$(echo "$MIGRATION_STATE"    | jq -r '.failed    // false'    2>/dev/null || echo "false")
          printf "\r    [migration] %s/%s  phase: %-20s" "$VMI_NS" "$VMI_NAME" "$PHASE"
          if [[ "$COMPLETED" == "true" ]]; then
            echo ""
            log_success "Live migration of $VMI_NS/$VMI_NAME completed"
            break
          fi
          if [[ "$FAILED" == "true" ]]; then
            echo ""
            log_error "Live migration of $VMI_NS/$VMI_NAME FAILED"
            exit 1
          fi
          if (( $(date +%s) > DEADLINE )); then
            echo ""
            log_error "Timeout (10m) waiting for live migration of $VMI_NS/$VMI_NAME"
            exit 1
          fi
          sleep 5
        done
      else
        log_warn "virtctl unavailable — cannot trigger live migration of $VMI_NS/$VMI_NAME"
        log_warn "This VM WILL BLOCK the drain indefinitely. Trigger migration manually, then press Enter."
        read -r
      fi
    else
      # ── Non-migratable VM — graceful stop ───────────────────────────────────
      echo ""
      log_warn "VM $VMI_NS/$VMI_NAME  evictionStrategy=$VMI_STRATEGY  (cannot live-migrate)"
      echo "  Stop it now? KubeVirt will restart it on another node (node is already cordoned). [y/skip]"
      read -r VM_ACTION
      if [[ "$VM_ACTION" =~ ^[Yy]$ ]]; then
        if [[ "$VIRTCTL_AVAILABLE" == "true" ]]; then
          log_info "Stopping VM $VMI_NS/$VMI_NAME..."
          virtctl stop "$VMI_NAME" -n "$VMI_NS"

          DEADLINE=$(( $(date +%s) + 300 ))
          while true; do
            NEW_NODE=$(kubectl get vmi "$VMI_NAME" -n "$VMI_NS" \
              -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")
            NEW_PHASE=$(kubectl get vmi "$VMI_NAME" -n "$VMI_NS" \
              -o jsonpath='{.status.phase}' 2>/dev/null || echo "Stopped")
            printf "\r    [restart] %s/%s  phase: %-10s  node: %-32s" \
              "$VMI_NS" "$VMI_NAME" "$NEW_PHASE" "${NEW_NODE:-pending}"
            if [[ "$NEW_PHASE" == "Running" && -n "$NEW_NODE" && "$NEW_NODE" != "$NODE" ]]; then
              echo ""
              log_success "VM $VMI_NS/$VMI_NAME is Running on $NEW_NODE"
              break
            fi
            if (( $(date +%s) > DEADLINE )); then
              echo ""
              log_error "Timeout (5m) waiting for $VMI_NS/$VMI_NAME to start on another node"
              exit 1
            fi
            sleep 5
          done
        else
          log_warn "virtctl unavailable — VM will be force-evicted by kubectl drain (brief outage)."
        fi
      else
        log_info "Skipping — VM $VMI_NS/$VMI_NAME will be handled by kubectl drain."
      fi
    fi
  done

  # ── c. CNPG single-instance primaries ─────────────────────────────────────
  mapfile -t CNPG_LIST < <(kubectl get pods -A -l 'cnpg.io/cluster' -o json 2>/dev/null | \
    jq -r --arg node "$NODE" \
    '.items[] | select(.spec.nodeName == $node) |
     "\(.metadata.namespace) \(.metadata.labels["cnpg.io/cluster"]) \(.metadata.name)"' || true)

  for CNPG_ENTRY in "${CNPG_LIST[@]}"; do
    [[ -z "$CNPG_ENTRY" ]] && continue
    C_NS=$(echo "$CNPG_ENTRY"      | awk '{print $1}')
    C_CLUSTER=$(echo "$CNPG_ENTRY" | awk '{print $2}')
    C_POD=$(echo "$CNPG_ENTRY"     | awk '{print $3}')
    C_PRIMARY=$(kubectl get cluster "$C_CLUSTER" -n "$C_NS" \
      -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")
    C_INSTANCES=$(kubectl get cluster "$C_CLUSTER" -n "$C_NS" \
      -o jsonpath='{.spec.instances}' 2>/dev/null || echo "0")

    # Only act on single-instance primaries; multi-instance CNPG auto-switchovers during drain
    if [[ "$C_POD" != "$C_PRIMARY" ]]; then
      log_info "CNPG $C_NS/$C_CLUSTER: pod $C_POD is a replica — drain will evict it normally"
      continue
    fi
    if (( ${C_INSTANCES:-0} > 1 )) 2>/dev/null; then
      log_info "CNPG $C_NS/$C_CLUSTER: $C_INSTANCES instances — auto-switchover will occur during drain"
      continue
    fi

    log_info "CNPG $C_NS/$C_CLUSTER: single-instance primary on this node — scaling to 2 for switchover..."
    kubectl patch cluster "$C_CLUSTER" -n "$C_NS" --type merge -p '{"spec":{"instances":2}}'

    DEADLINE=$(( $(date +%s) + 300 ))
    while true; do
      NEW_PRIMARY=$(kubectl get cluster "$C_CLUSTER" -n "$C_NS" \
        -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")
      NEW_NODE=""
      if [[ -n "$NEW_PRIMARY" ]]; then
        NEW_NODE=$(kubectl get pod "$NEW_PRIMARY" -n "$C_NS" \
          -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
      fi
      printf "\r    [cnpg] %s  primary: %-35s  node: %-30s" \
        "$C_CLUSTER" "${NEW_PRIMARY:-waiting}" "${NEW_NODE:-pending}"
      if [[ -n "$NEW_NODE" && "$NEW_NODE" != "$NODE" ]]; then
        echo ""
        log_success "CNPG $C_NS/$C_CLUSTER primary is now $NEW_PRIMARY on $NEW_NODE"
        break
      fi
      if (( $(date +%s) > DEADLINE )); then
        echo ""
        log_error "Timeout (5m) waiting for CNPG $C_NS/$C_CLUSTER switchover"
        exit 1
      fi
      sleep 5
    done

    log_info "Scaling CNPG $C_NS/$C_CLUSTER back to 1 instance..."
    kubectl patch cluster "$C_CLUSTER" -n "$C_NS" --type merge -p '{"spec":{"instances":1}}'
    log_success "CNPG $C_NS/$C_CLUSTER scaled back to 1 instance"
  done

  # ── d. Longhorn manually-attached volumes ──────────────────────────────────
  # Longhorn VolumeAttachment tickets with type != csi-attacher are manually/UI attached
  _lh_manual_vols() {
    kubectl -n longhorn-system get volumeattachments.longhorn.io -o json 2>/dev/null | \
      jq -r --arg node "$1" \
      '.items[] | select(.spec.nodeID == $node) |
       .metadata.name as $va |
       (.spec.attachmentTickets // {}) | to_entries[] |
       select(.value.type != "csi-attacher") |
       $va' 2>/dev/null || true
  }

  LH_MANUAL=$(_lh_manual_vols "$NODE")
  if [[ -n "$LH_MANUAL" ]]; then
    echo ""
    log_warn "Longhorn volume(s) on $NODE with non-CSI attachments (likely manual/UI):"
    echo "$LH_MANUAL" | while IFS= read -r vol; do echo "  - $vol"; done
    echo ""
    log_warn "These will block the drain. Detach them in the Longhorn UI, then press Enter."
    log_warn "Ctrl+C to abort."
    read -r
    LH_MANUAL=$(_lh_manual_vols "$NODE")
    if [[ -n "$LH_MANUAL" ]]; then
      log_error "Volumes still attached. Aborting to avoid a hung drain."
      exit 1
    fi
    log_success "All manually-attached volumes cleared"
  fi

  # ── e. Drain ───────────────────────────────────────────────────────────────
  DRAIN_LOG="/tmp/drain-${NODE//./_}.log"
  log_info "Draining $NODE..."
  log_info "  --ignore-daemonsets   (required: Longhorn manager/CSI/engine DaemonSets)"
  log_info "  --timeout=0           (wait forever: Longhorn PDB blocks until volumes are safe)"
  log_info "  Log: $DRAIN_LOG"
  echo ""

  kubectl drain "$NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=0 \
    >"$DRAIN_LOG" 2>&1 &
  DRAIN_PID=$!

  # ── f. Progress monitor ────────────────────────────────────────────────────
  while kill -0 "$DRAIN_PID" 2>/dev/null; do
    REMAINING=$(kubectl get pods -A -o json 2>/dev/null | \
      jq --arg node "$NODE" \
      '[.items[] | select(.spec.nodeName == $node) |
        select((.metadata.ownerReferences // []) | map(.kind) | contains(["DaemonSet"]) | not)] | length' \
      2>/dev/null || echo "?")
    LH_TOTAL=$(kubectl -n longhorn-system get volumes.longhorn.io \
      --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "?")
    LH_HEALTHY=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null | \
      jq '[.items[] | select(.status.robustness == "healthy")] | length' 2>/dev/null || echo "?")
    printf "\r  Draining — evictable pods remaining: %-4s | Longhorn volumes: %s/%s healthy   " \
      "$REMAINING" "$LH_HEALTHY" "$LH_TOTAL"
    sleep 5
  done
  echo ""

  # ── g. Drain result ────────────────────────────────────────────────────────
  DRAIN_RC=0
  wait "$DRAIN_PID" || DRAIN_RC=$?

  if [[ "$DRAIN_RC" -ne 0 ]]; then
    log_error "kubectl drain exited with code $DRAIN_RC — log: $DRAIN_LOG"
    echo "--- Last 20 lines ---"
    tail -20 "$DRAIN_LOG" || true
    echo "---------------------"
    LH_BAD=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null | \
      jq -r '.items[] | select(.status.robustness != "healthy") |
             "  \(.metadata.name): \(.status.robustness)"' || true)
    if [[ -n "$LH_BAD" ]]; then
      log_warn "Degraded Longhorn volumes (may be blocking the drain):"
      echo "$LH_BAD"
    fi
    log_error "Resolve the issue above, then retry or drain manually with:"
    log_error "  kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=0"
    exit 1
  fi

  # ── h. Final Longhorn health check ────────────────────────────────────────
  LH_DEGRADED_FINAL=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null | \
    jq '[.items[] | select(.status.robustness != "healthy" and .status.robustness != "")] | length' \
    2>/dev/null || echo "0")
  if [[ "${LH_DEGRADED_FINAL:-0}" -gt 0 ]]; then
    log_warn "$LH_DEGRADED_FINAL Longhorn volume(s) are degraded after drain."
    log_warn "Replicas on the drained node are now stopped — they recover automatically on uncordon/reboot."
    log_warn "Check: kubectl -n longhorn-system get volumes.longhorn.io"
  fi

  # ── i. Safe to shut down ───────────────────────────────────────────────────
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  ✓  NODE $NODE IS SAFE TO SHUTDOWN"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "  When maintenance is complete, restore the node with:"
  echo "    kubectl uncordon $NODE"
  echo ""
done
