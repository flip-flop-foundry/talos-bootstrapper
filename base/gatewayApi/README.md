# Shared Gateway API — standard v1.6.3

The `gateway-api` Argo Application independently manages upstream Gateway API
CRDs, using server-side apply. Kustomize adds resource-level
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
Do **not** add `FailOnSharedResource=true`: initial sync must adopt resources
previously tracked by Traefik. Argo writes its own tracking annotation during
sync; the migration does not forge ownership or delete any CRD.

Default Traefik is chart **42.3.1**, application **v3.7.17**, requiring Kubernetes
>=1.30. The public chart no longer includes Gateway API CRDs. Existing environment
files are deliberately not changed by this source update. Standard is the
intended bundle for dkk8s1; experimental, unknown-channel, newer-bundle, or
incompatible stored/served-version installations **block**, not downgrade.

## How the legacy handover works

Chart 39.0.8 bundles these CRDs; chart 42.3.1 does not. Upgrading Traefik with
automated prune would therefore **delete** the CRDs (and every Gateway/route).
Before any publication, the `beforeArgo` hook
`deploymentHooks/beforeArgo/20-gateway-api-migration.sh` runs automatically from
**Render and Push to Gitea** and **Apply Overlay**:

1. **Relevance first.** If no Gateway CRD is tracked by the Traefik Application,
   it prints `SKIP` and changes nothing (also on fresh bootstraps).
2. **Compatibility.** Experimental, unknown, newer or storage-incompatible
   installations block — never auto-downgraded.
3. **Approval.** After all checks pass and before the first cluster write, the
   administrator is asked to confirm in the terminal. Approval is recorded on the
   Traefik Application (`bootstrapper.talos.dev/gateway-api-migration-approved`)
   so reruns of the same handover don't ask again. Non-interactive runs block
   unless `GATEWAY_API_MIGRATION_APPROVED=true`.
4. **Traefik-only pause.** Sets `spec.syncPolicy.automated.enabled=false` on the
   Traefik Application **only** (ArgoCD 3.x) together with a refresh request.
   Other Applications keep syncing. The hook waits until ArgoCD removes the
   refresh annotation — proof that a controller refresh observed the disabled
   auto-sync, and that any earlier in-flight Traefik refresh has finished —
   then waits for any running Traefik sync to complete
   (`GATEWAY_API_MIGRATION_TIMEOUT_SECONDS`, default 900).
5. **Protection.** Adds `Prune=false,Delete=false` to each legacy CRD's
   `argocd.argoproj.io/sync-options` (existing options preserved), and reads
   every CRD back before publication is allowed. Nothing is deleted and
   ownership is never rewritten.

**Apply Overlay** then applies the rendered Traefik Application. It explicitly
declares `automated.enabled: true`, so the chart upgrade and auto-sync
re-enablement land atomically. The new chart no longer declares the CRDs, and
resource-level `Prune=false` stops it pruning them. The `gateway-api`
Application adopts them on its next sync (Argo rewrites the tracking ID), and
its own Kustomization keeps them protected permanently.

Why not a timer or a skip-reconcile annotation: neither proves that an
already-running reconcile will not start one more old-chart sync. The refresh
acknowledgment does, because ArgoCD never processes the same Application
concurrently and the refresh annotation is only removed by a refresh that read
the patched object.

## Administrator sequence (dkk8s1)

Use a quiet window: avoid manual Traefik syncs or other Git publishes meanwhile.

1. Merge both source commits. In `dkk8s1.env` set `TRAEFIK_HELM_VERSION="42.3.1"`.
   Keep `gatewayApi` and the migration hook out of `EXCLUDED_BASE`. Check any
   environment Traefik values overlay: chart 42 moves `service.type` to
   `service.spec.type`.
2. Select the dkk8s1 Kubernetes context (the runner validates cluster name and
   `https://${TALOS_CLUSTER_ENDPOINT}:6443`; use `DEPLOYMENT_HOOK_KUBE_SERVER`
   for a deliberately different endpoint).
3. Optional preview: **Render Overlay**, then inspect
   `_rendered/gatewayApi/` and `_rendered/traefik/traefikArgoApp.yaml`.
4. Run **Apply Overlay** and answer `y` to the migration prompt. Expect
   `PROTECTED` before publication. Running only **Render and Push** protects
   the CRDs but leaves Traefik auto-sync disabled until Apply Overlay runs.
5. Verify:
   ```
   kubectl -n traefik get application traefik -o jsonpath='{.spec.syncPolicy.automated.enabled}{"\n"}'
   kubectl -n argocd get application gateway-api
   kubectl get crd -o custom-columns='NAME:.metadata.name,OWNER:.metadata.annotations.argocd\.argoproj\.io/tracking-id,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version' | grep gateway.networking
   ```
   Expect `true`, a Synced/Healthy `gateway-api`, and all ten CRDs owned by
   `gateway-api:` at `v1.6.3`. Check the safe-upgrades admission policy and
   binding exist. Rerunning the hook afterwards reports `SKIP`.

Recovery: every step is idempotent — fix the reported cause and rerun.
If the hook fails after disabling auto-sync, Traefik stays paused (safe);
rerunning continues the handover. To abandon it, re-enable auto-sync by
re-applying the **old** rendered Traefik Application only if `gateway-api` has
not synced yet; otherwise review ownership and versions first. Protected CRDs
are intentionally never pruned or deleted automatically.

Both Gateway and Traefik Applications declare a required-beforeArgo-hook
annotation: excluding the hook while publishing them blocks before any change.
A replacement hook is trusted code and must keep equivalent checks.

## Pinned public provenance

Unmodified public Apache-2.0 upstream files from
`kubernetes-sigs/gateway-api`, tag `v1.6.3`, commit
`c0836133e24073fcdcdbb1713aba3cc73a89d0b5`, directory `config/crd/standard/`.
Each source URL is:
`https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/c0836133e24073fcdcdbb1713aba3cc73a89d0b5/config/crd/standard/<filename>`.
The safe-upgrades admission policy/binding is part of that standard distribution.
The local `kustomization.yaml` is the only addition to the upstream files.
The upstream Apache-2.0 license is included in `UPSTREAM-LICENSE`.

| File suffix (prefix `gateway.networking.k8s.io_`) | SHA-256 |
|---|---|
| backendtlspolicies.yaml | d9824b82db284bdea67d2eb0297952be51e0e7a394f02daef0d6f3fefa5d01c0 |
| gatewayclasses.yaml | d32070cb6930273a07c5ca183135712b1918cc140c6d9b6cef441cdf0e562345 |
| gateways.yaml | 905c89d8fefaab9088bf9d0a8d47ebd7ec4e653a914d4bfaa575a7716f07a828 |
| grpcroutes.yaml | a96b307008290c194ad346f9bb9346dd560c12e4d4e7dfbdbe7d2fb5e812d62e |
| httproutes.yaml | a89d17ff5ed060fa0eac015524f9252bb291f616412c13ac8cb952ed9c25c5ad |
| listenersets.yaml | b81f1771dcd96dfb3bb500e07dafef79a2aa58c4a9b4b366d54ca29e8ecccb5e |
| referencegrants.yaml | ff8db85aaacc91fb4096975afb5782540572bf2f04842a258094cd7f50c7f38a |
| tcproutes.yaml | 5d2891484c870865e9ae61402b412a8b81eea381fbb71fdc56406e533c9643f1 |
| tlsroutes.yaml | b9277b755ee0f33dd245d3497ba842922ff2e2efe5070b0911e58d072d55ed9c |
| udproutes.yaml | a552a9aa3726367c392000a45d13e6ba07985117a5e6826364640bedfeb5e922 |
| vap_safeupgrades.yaml | 66b1d7b2c392c0e4dd4b2950e2af62811f8288a65e50708e2b3d26d4433af84c |

Chart audit sources:
* https://github.com/traefik/traefik-helm-chart/tree/v39.0.8/traefik/crds
* https://github.com/traefik/traefik-helm-chart/tree/v42.3.1/traefik/crds
* https://github.com/traefik/traefik-helm-chart/blob/v42.3.1/traefik/Chart.yaml
* https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
* https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
* https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
