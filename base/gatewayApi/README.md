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

## Why a maintenance gate is necessary

Chart 39.0.8's `traefik/crds/gateway-standard-install.yaml` lacks Argo sync-option
annotations. The old Application has SSA, automated prune and self-heal.
SSA retains fields owned exclusively by another field manager, but this is not
proof that Argo's comparison or client-side-apply migration will ignore the added
field: manager ownership, desired/live comparison and in-flight syncs matter.
An annotation plus a delay is not an informer/operation barrier.

The migration therefore requires **all Argo application-controller workloads in
the configured Argo namespace at zero replicas, and no controller pods left**.
It verifies no Traefik sync is active/pending, and refuses a parent-managed
Traefik Application or custom/unverifiable tracking/controller versions.
It then sets Traefik `skip-reconcile=true` (supported since Argo 2.7), preserves
all existing CRD annotation options, adds `Prune=false,Delete=false`, and reads
every live CRD back before publication. CAS/write/query/postcondition failure
blocks publication. Controllers are **not** automatically scaled or resumed.

Both `traefik` and namespace-qualified `traefik_traefik` tracking identities are
recognized, with self-referencing CRD tracking IDs preferred over labels.
Live Traefik Application status must agree with legacy ownership. Fresh bootstrap
is a **reachable** API with an absent Applications CRD; an unreachable/Forbidden/
TLS-failing API always blocks. No legacy ownership means an explicit migration
skip, but an included new Gateway app still gets compatibility checks.

## Exact administrator sequence (dkk8s1)

Implementation/testing does not run these live commands. Use a maintenance
window; don't allow competing manual syncs, parent reconcilers, Git publishes,
or Helm upgrades during handover.

1. Review/merge both source commits (tooling and shared base). Preserve existing
   local environment/Talos edits. In
   `/workspaces/talos-bootstrapper-data/environments/dkk8s1/dkk8s1.env`, deliberately
   set `TRAEFIK_HELM_VERSION="42.3.1"`. Do not disable the hook. Ensure
   `gatewayApi`, its Application/bundle resources, and the migration script are
   not in `EXCLUDED_BASE`. No experimental bundle is selected automatically.
2. Select the dkk8s1 Kubernetes context using the existing environment context
   task. Confirm the kubeconfig cluster matches `TALOS_CLUSTER_NAME` and server
   matches `https://${TALOS_CLUSTER_ENDPOINT}:6443`. A deliberately different
   endpoint requires `DEPLOYMENT_HOOK_KUBE_SERVER` in the trusted env.
3. Render (no live mutations):
   ```
   /workspaces/Talos/.vscode/tasks/render-overlay.sh /workspaces/talos-bootstrapper-data/environments/dkk8s1/dkk8s1.env
   ```
   Inspect `_rendered/gatewayApi/gatewayApiArgoApp.yaml`, its templates, and
   `_rendered/traefik/traefikArgoApp.yaml`. Inspect/snapshot the live CRD metadata,
   Check any environment Traefik values overlay too: chart 42 moves
   `service.type` to `service.spec.type`; do not carry the removed key forward.
   stored versions, Traefik Application and controller replica counts in your
   change record. Finish or terminate any active Traefik sync **before pausing**.
4. Record original counts; stop all standard application controllers:
   ```
   kubectl -n argocd get deployment,statefulset -l app.kubernetes.io/name=argocd-application-controller
   kubectl -n argocd scale deployment,statefulset -l app.kubernetes.io/name=argocd-application-controller --replicas=0
   kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller
   ```
   Wait until the last command lists **no pods**, including terminating ones.
   If a nonstandard/sharded controller or parent manager exists, stop and review
   it; the built-in migration does not claim to handle unknown installations.
5. Run **Render and Push to Gitea**, or:
   ```
   /workspaces/Talos/.vscode/tasks/push-to-gitea.sh dkk8s1
   ```
   The wired preflight must report `PROTECTED`; errors abort the push.
   Do not use full Apply Overlay for this handover if its Helm upgrade would
   resume application controllers before final publication.
6. While controllers are still stopped, install/update the two Applications:
   ```
   kubectl apply -f /workspaces/talos-bootstrapper-data/environments/dkk8s1/_rendered/gatewayApi/gatewayApiArgoApp.yaml
   kubectl apply -f /workspaces/talos-bootstrapper-data/environments/dkk8s1/_rendered/traefik/traefikArgoApp.yaml
   kubectl -n traefik get application traefik -o yaml
   ```
   Verify the live Traefik chart is 42.3.1 and `skip-reconcile: "true"` remains.
   Direct kubectl apply preserves the out-of-band pause annotation; if a parent
   manager has appeared, stop and review rather than relying on preservation.
7. Restore each recorded controller replica count (not a guessed default).
   Keep Traefik paused. Let `gateway-api` sync, or sync it explicitly in Argo.
   Wait for successful sync/healthy resources and verify **all ten Gateway CRDs**
   have self-referencing tracking IDs:
   `gateway-api:apiextensions.k8s.io/CustomResourceDefinition:/<crd-name>`,
   plus `Prune=false,Delete=false`. Check the upstream safe-upgrades admission
   policy/binding are present. Never manually change tracking to simulate adoption.
8. Only after adoption, resume Traefik:
   ```
   kubectl -n traefik annotate application traefik argocd.argoproj.io/skip-reconcile-
   ```
   Sync/verify Traefik 42.3.1 / v3.7.17 and the Gateway API app. Old Traefik must
   no longer track Gateway CRDs. Protected CRDs intentionally are not pruned when
   an app/resource is excluded or deleted; this is safety, not automatic cleanup.

   Both Gateway and Traefik Applications declare a required-beforeArgo-hook
   annotation. Removing/excluding the migration hook while publishing these apps
   blocks before any cluster mutation/publication. A deliberately replaced hook is
   trusted operator code and must preserve this migration's protection, compatibility,
   quiescence and ownership checks. Unsupported/custom tracking or status-listed
   CRDs with ambiguous ownership block **before** any “no legacy” skip.

If a write or publication fails, leave controllers stopped and Traefik paused,
fix the cause, and rerun. A partial annotation update is idempotent. If abandoning
the upgrade, **do not** resume the old chart after the new admission policy or
Gateway app has synced; review ownership/version compatibility first. There is
no automatic rollback of CRD schemas, deletion, pause or annotations.

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
* https://argo-cd.readthedocs.io/en/stable/user-guide/skip_reconcile/
* https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
