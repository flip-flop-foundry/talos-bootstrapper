# Coder

## What it does

Deploys the [Coder](https://coder.com) control plane — a self-hosted platform
that provisions cloud development environments (workspaces) on demand. In this
cluster, Coder gives users a ready-to-use environment for hacking on
talos-bootstrapper itself, backed by the same `k8s-dev-image` used by this
devcontainer.

The control plane runs as an ArgoCD `Application` using Coder's official OCI
Helm chart. Workspaces are Kubernetes Pods (one per user session) scheduled into
a dedicated `${CODER_WORKSPACES_NAMESPACE}` namespace with a persistent home
volume.

## Why it was added

To give operators and contributors of Talos-bootstrapper clusters a place to
code and improve talos-bootstrapper without setting up a local toolchain.

## Dependencies

- **cnpg** — provides the PostgreSQL database (`coder-sql`) that stores Coder
  state. mTLS is enforced (`scram-sha-256` + `clientcert=verify-full`).
- **cert-manager** — issues the server/client certificates for the database and
  the ingress TLS certificate.
- **reloader** — restarts the Coder deployment when the Gitea OIDC / external-auth
  or database secrets change.
- **gitea** — the identity provider (OIDC login + workspace git external-auth) and
  the git host for the cluster-services repo. `gitea-bootstrap.sh` auto-provisions
  the two Gitea OAuth2 apps and the CODER_SESSION_TOKEN CI secret.
- **gitea-runners** — executes the "Push Coder Templates" Gitea Actions workflow.
- **longhorn** — provides the encrypted storage classes for the database
  (`nssharedkey-*`) and workspace home volumes (`pvckey-*`).

## Dependents

- None. Coder is a leaf workload.

## User Guide

### Authentication (automated)

Coder authenticates users against **Gitea OIDC** and gives workspaces
pre-authenticated git access via **Gitea external auth**. Both are wired up
automatically by `gitea-bootstrap.sh` during cluster bootstrap — there is no
manual OAuth-app or token step.

1. **Gitea OIDC + external-auth apps (automated).** `gitea-bootstrap.sh` creates
   two Gitea OAuth2 applications and writes their credentials into the
   `coder-oidc` and `coder-external-auth` secrets in the `${CODER_NAMESPACE}`
   namespace. Callbacks:
   - login: `https://${CODER_DOMAIN_NAME}/api/v2/users/oidc/callback`
   - workspace git: `https://${CODER_DOMAIN_NAME}/external-auth/gitea/callback`

   The secret references are `optional: true`, so Coder starts even before the
   apps exist (OIDC login simply stays disabled in that window).

2. **Break-glass owner (automated).** The `coderOwnerBootstrapJob` PostSync hook
   seeds the first Coder owner once the control plane is healthy — username
   `admin`, email `admin@${CODER_DOMAIN_NAME}`, with a randomly generated
   password written back into the `coder-owner-bootstrap` secret. This is the
   password-auth fallback used if Gitea OIDC is unavailable. Retrieve it with:
   ```bash
   kubectl -n ${CODER_NAMESPACE} get secret coder-owner-bootstrap \
     -o jsonpath='{.data.password}' | base64 -d; echo
   ```
   The Job is idempotent: it does nothing if an owner already exists, and reuses
   any password already stored in the secret (so the stored value stays valid
   after a database restore).

3. **Template CI credentials (automated).** The "Push Coder Templates" workflow
   needs a Coder API token as the `CODER_SESSION_TOKEN` repo secret. This is
   published automatically without ever staging a Gitea credential into the coder
   namespace: `gitea-bootstrap.sh` (running in the devenv) execs into the Coder
   pod, logs in as the bootstrap owner (credentials read from the
   `coder-owner-bootstrap` secret and fed on stdin, never in argv), mints a token
   named `gitea-ci-templates` (deleting any stale one first), and publishes it to
   the repo using the Gitea **admin** token, which never leaves the devenv. The
   Coder URL is rendered into the workflow from `${CODER_DOMAIN_NAME}`, so no
   `CODER_URL` secret is required.

   Because the Coder token can only be minted after Coder is up (asynchronous on a
   greenfield cluster), the publish is eventually-consistent: it runs as the final
   step of **Apply Overlay** (after the ArgoCD apps are applied), waits for the
   Coder deployment to become Available, and if Coder is not yet ready defers to
   the next **Apply Overlay**. It is a no-op when the repo secret already exists.
   To force a re-publish (e.g. the stored token was revoked), delete the
   `CODER_SESSION_TOKEN` repo secret in Gitea and re-run **Apply Overlay**.

### Restarting after a secret change

Reloader watches the referenced secrets, so updating `coder-oidc` (or the other
referenced secrets) triggers an automatic rollout. To force one manually:
```bash
kubectl -n ${CODER_NAMESPACE} rollout restart deploy/coder
```

### Connecting

Browse to `https://${CODER_DOMAIN_NAME}`. Workspaces are created from the
`k8s-dev-image` template and land in `${CODER_WORKSPACES_NAMESPACE}`.

### Notes

- Docker-in-workspace is intentionally **not** enabled; workspaces are
  unprivileged Pods.
- Workspace templates live in `templates/` and are pushed to Coder by the Gitea
  Actions workflow whenever `_rendered/coder/templates/**` changes.
- Workspace resource requests/limits (default 500m/1Gi request, 4 CPU/8Gi limit)
  are defined in the `k8s-dev-image` template and are tunable — lower them for
  small clusters if workspaces fail to schedule.
- Each workspace home PVC is encrypted with its **own** LUKS key. The
  `pvckey-2replica-notretained-backedup-ssd-wn` storage class resolves the key
  from a `Secret` named after the PVC, and the `k8s-dev-image` Terraform template
  provisions that key (`random_password` → `kubernetes_secret_v1`) as part of the
  same workspace build, so it is created with the workspace and deleted with it.
  The key persists across workspace stop/start (it has no `count`, matching the
  PVC); only deleting the workspace removes both the volume (reclaim `Delete`) and
  its key.
