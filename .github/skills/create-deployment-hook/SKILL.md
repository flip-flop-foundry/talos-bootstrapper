---
name: create-deployment-hook
description: 'Create or update deployment hooks in deploymentHooks/beforeArgo/*.sh for Talos bootstrapper base and overlays. Use when adding pre-publication migrations, Argo safety gates, hook overrides, EXCLUDED_BASE exclusions, bootstrap preflight checks, or offline hook failure tests. beforeTalos is reserved and not wired.'
---

# Create a deployment hook

1. Read `CLAUDE.md`, mirrored `.github/copilot-instructions.md`, and
   `base/deploymentHooks/README.md`. Inspect an existing hook before adding code.
   If changing project instructions, change **both identical mirrors**.
2. Use `base/deploymentHooks/beforeArgo/NN-purpose.sh`, Bash-compatible,
   `set -euo pipefail`. The environment overlay may replace the **exact same
   relative path**; no script merge. Sort prefixes determine execution order.
   `beforeTalos` is **reserved, not wired**: do not change Talos entrypoints.
3. Check relevance **very early**, using live resource ownership and status
   where relevant. Explicitly report a no-op before expensive inspection or
   mutations. Never infer relevance from stale rendered artifacts.
4. Read desired manifests only from the runner's fresh `HOOK_RENDERED_DIR`.
   Use exported context `HOOK_KUBE_CONTEXT` for every kubectl operation.
   Validate intended scope/ownership before writes. Do not silently catch a
   failed query, use `|| true`, or equate Forbidden/TLS/network failure with
   absence. A fresh bootstrap is a **reachable** Kubernetes API with a
   successfully queried absent resource/API; unreachable existing API blocks.
5. Make changes idempotent, preserve existing annotations/options, use
   resource-version preconditions for read-modify-write, and verify live
   postconditions before allowing publication. Avoid deletes. Investigate
   controller reconciliation races; an added live annotation or short sleep
   is not proof of quiescence. Prefer an Application-scoped barrier over a
   controller-wide pause: disable that app's auto-sync together with an
   `argocd.argoproj.io/refresh` request, wait until Argo removes the refresh
   annotation (a refresh observed the change), then until no operation runs.
   Ask the administrator before pausing anything; block if no terminal and
   no explicit approval variable. Fail clearly if safety cannot be established.
   If an Application must never publish without this gate, declare its exact
   hook path in `bootstrapper.talos.dev/required-before-argo-hook`. The runner
   blocks if the required hook is missing/excluded while that app is included.
   Trusted overlay replacements must preserve equivalent postconditions; no
   framework can prove arbitrary shell code equivalent to the original.
6. Respect `EXCLUDED_BASE`: a whole component (`deploymentHooks`) or **exact**
   path (`deploymentHooks/beforeArgo/NN-purpose.sh`), applying to **base and
   overlays**. Prefix/directory exclusions are not recursive. Use the existing
   inventory helper, not a second discovery implementation.
7. Rendering must remain free of execution/cluster side effects. Shell scripts
   are copied verbatim, never envsubst. The runner executes current sources,
   never rendered hook artifacts. Hooks must not enter either Argo-watched Git
   publication transport. Dry-run entrypoints skip execution.
8. Test offline with mocked APIs: no relevance, fresh bootstrap API absence,
   unreachable/Forbidden API, wrong context, base/overlay replacement,
   exact and whole exclusions (including overlays), deterministic order,
   idempotency, conflicting options, write failure, verification failure,
   stale output, no render-time effects, and failure-before-publication.
   Run shell syntax checks and the targeted unittest suite; no live mutation
   to validate. Review the staged diff and stage **only your own files**.
9. Document any maintenance gate, partial-failure recovery, and exact operator
   next steps. Commit the skill and hook with the implementation, including
   the requested Co-authored-by trailer.
