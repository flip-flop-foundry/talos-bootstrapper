# Shared Gateway API CRDs

The `gateway-api` Argo Application installs the upstream Gateway API
**standard-channel** CRDs (plus upstream's safe-upgrades admission policy)
directly from <https://github.com/kubernetes-sigs/gateway-api>, path
`config/crd`, at the version set by `GATEWAY_API_VERSION` in the env file
(a release tag such as `v1.6.3`, or a full commit SHA for an exact pin). That
Kustomization has the same content as the release's `standard-install.yaml`.
Nothing is vendored in this repository; ArgoCD's repo-server and the devenv
need to reach GitHub.

Argo adds `argocd.argoproj.io/sync-options: Prune=false,Delete=false` to every
resource through `spec.source.kustomize.commonAnnotations`, so CRDs (and with
them every Gateway/route) are never pruned or deleted automatically. Resources
are applied with server-side apply. Do **not** add `FailOnSharedResource=true`:
initial sync must be able to adopt CRDs previously installed by another app.

To upgrade, change `GATEWAY_API_VERSION` and run **Apply Overlay**. The
`beforeArgo` hook builds the same upstream bundle first and blocks if it is not
the standard channel, if its own version does not match the tag, or if live
CRDs are experimental, newer than the target, or use stored/served versions the
target no longer defines. Check your Cilium version's supported Gateway API
version before changing it (see the caveat below).

Traefik (chart 42.3.1, app v3.7.17) no longer ships Gateway API CRDs.

## How the legacy handover works

Chart 39.0.8 bundles these CRDs; chart 42.3.1 does not. Upgrading Traefik with
automated prune would therefore **delete** the CRDs (and every Gateway/route).
Before any publication, the `beforeArgo` hook
`deploymentHooks/beforeArgo/20-gateway-api-migration.sh` runs automatically from
**Render and Push to Gitea** and **Apply Overlay**:

1. **Relevance first.** If no Gateway CRD is tracked by the Traefik Application,
   it prints `SKIP` and changes nothing (also on fresh bootstraps). Argo only
   prunes live objects carrying its tracking metadata, and CRDs that Argo applied
   from a Helm chart's `crds/` directory carry none (verified on dkk8s1, Argo
   3.3.7). Such untracked CRDs are reported and left alone: dropping them from the
   chart cannot delete them, so no pause or approval is needed.
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
its `commonAnnotations` keep them protected permanently.

Why not a timer or a skip-reconcile annotation: neither proves that an
already-running reconcile will not start one more old-chart sync. The refresh
acknowledgment does, because ArgoCD never processes the same Application
concurrently and the refresh annotation is only removed by a refresh that read
the patched object.

## Cilium < 1.20 caveat

Cilium 1.18 and 1.19 (checked 1.18.4 and up to 1.19.11) treat the optional `TLSRoute` `v1alpha2`
version as present when it is merely *listed* in the CRD. The standard v1.6.x
`TLSRoute` CRD lists `v1alpha2` but does not serve it, so their operator may
fail to watch it. Do not install this bundle on a cluster running Cilium
<1.20 (including the template default 1.18.4) with `gatewayAPI.enabled: true` without verifying the operator stays
healthy; prefer installing it together with the Cilium 1.20 upgrade.

## Administrator sequence

* **dkk8s1:** Traefik is already on 42.3.1; its Gateway CRDs were untracked, so
  no handover was needed. `gatewayApi` stays in `EXCLUDED_BASE` (CRDs remain at
  v1.4.0, unmanaged) until the Cilium 1.20 upgrade. Then remove the exclusion,
  set `GATEWAY_API_VERSION` to the version Cilium requires, and run Apply Overlay.
* **Clusters whose Gateway CRDs are tracked by Traefik:** set
  `TRAEFIK_HELM_VERSION="42.3.1"`, keep `gatewayApi` and the hook included, run
  **Apply Overlay** and answer `y` at the prompt. Expect `PROTECTED` before
  publication. **Render and Push** alone protects the CRDs but leaves Traefik
  auto-sync disabled until Apply Overlay runs.

Verify afterwards:
```
kubectl -n traefik get application traefik -o jsonpath='{.spec.syncPolicy.automated.enabled}{"\n"}'
kubectl -n argocd get application gateway-api
kubectl get crd -o custom-columns='NAME:.metadata.name,OWNER:.metadata.annotations.argocd\.argoproj\.io/tracking-id,VERSION:.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version' | grep gateway.networking
```
Expect `true`, a Synced/Healthy `gateway-api`, and every Gateway CRD owned by
`gateway-api:` at `GATEWAY_API_VERSION`. Rerunning the hook then reports `SKIP`.

Recovery: every step is idempotent — fix the reported cause and rerun.
If the hook fails after disabling auto-sync, Traefik stays paused (safe);
rerunning continues the handover. To abandon it, re-enable auto-sync by
re-applying the **old** rendered Traefik Application only if `gateway-api` has
not synced yet; otherwise review ownership and versions first. Protected CRDs
are intentionally never pruned or deleted automatically.

Both Gateway and Traefik Applications declare a required-beforeArgo-hook
annotation: excluding the hook while publishing them blocks before any change.
A replacement hook is trusted code and must keep equivalent checks.

## References

* https://github.com/kubernetes-sigs/gateway-api/tree/main/config/crd
* https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/#installing-gateway-api
* https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/
* https://github.com/traefik/traefik-helm-chart/tree/v39.0.8/traefik/crds
* https://github.com/traefik/traefik-helm-chart/tree/v42.3.1/traefik/crds
* https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
* https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
* https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
