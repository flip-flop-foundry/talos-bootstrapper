# Customer Provisioning

This directory contains the `customer-apps` ApplicationSet, which is the GitOps engine that automatically discovers and deploys applications for every customer on the cluster.

## Provisioning a New Customer

```bash
./adminTasks/bootstrap-customer.sh overlays/<cluster>/<cluster>.env <customer-name> [OPTIONS]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--org-name <name>` | `CUSTOMER_NAME` | Gitea organisation name |
| `--repo-name <name>` | `example-repo` | Initial repository / application name |
| `--ingress-host <host>` | `CUSTOMER_NAME.CLUSTER_EXTERNAL_DOMAIN` | Ingress hostname for the app |
| `--template-branch <br>` | `master` | Branch of the customer template repo to clone |
| `--force-recreate` | — | Delete and re-create existing Gitea org/repo. **Requires interactive confirmation — you must type the org name to proceed.** |

**Namespace** is always derived as `<orgName>-<repoName>` — matching the formula used by the ApplicationSet, so it never needs to be specified.

**Example:**

```bash
# Minimal — uses all defaults
./adminTasks/bootstrap-customer.sh overlays/mycluster/mycluster.env acme

# Custom org/repo names
./adminTasks/bootstrap-customer.sh overlays/mycluster/mycluster.env acme \
  --org-name acme-corp \
  --repo-name api \
  --ingress-host api.acme.example.com

# Re-run safely — all steps are idempotent
./adminTasks/bootstrap-customer.sh overlays/mycluster/mycluster.env acme
```

---

## What Happens During Bootstrap

`bootstrap-customer.sh` performs the following steps in order:

### Step 1 — Gitea organisation

Creates a private Gitea organisation named `<orgName>` to own all of this customer's repositories.

Also adds two cluster service accounts as org members:
- **`argocd-cluster-services`** — so the ApplicationSet SCM provider can scan the org for repositories
- **`registry-pull`** — so the cluster-wide `RegistryAuthConfig` credential covers this org's container images

### Step 2 — Gitea repository

Creates the initial application repository `<orgName>/<repoName>`.

### Step 3 — Push example application

Clones the [customer template repo](https://github.com/flip-flop-foundry/talos-bootstraper-customer-template), substitutes all `PLACEHOLDER_*` values (domain names, org, namespace, etc.), and pushes the result to the new Gitea repo on `main`.

The template includes:
- `src/` — a minimal Python web application
- `Dockerfile` — builds the container image
- `.gitea/workflows/` — CI pipeline (build → push to Gitea container registry → rollout restart)
- `deploy/` — Kubernetes manifests (Deployment, Service, IngressRoute)

The presence of `deploy/` is what makes the ApplicationSet discover this repo.

### Step 4 — Customer descriptor

Commits `customers/<customerName>/<customerName>.yaml` to the `cluster-services` repo in Gitea:

```yaml
customerName: acme
gitea:
  orgName: acme
```

This file is also written **locally** to `overlays/<cluster>/customers/<customerName>/<customerName>.yaml` so it is tracked in the cluster repo and included automatically in every future `push-to-gitea` / `cluster-bootstrap` run.

The ApplicationSet Git generator reads `customers/*/*.yaml` to discover which orgs to scan. Adding this file is what triggers ArgoCD to start watching the customer's org.

### Step 5 — ArgoCD AppProject

Creates an ArgoCD `AppProject` named `customer-<customerName>` that enforces:
- **Source repos** restricted to `https://<gitea-domain>/<orgName>/*`
- **Destinations** restricted to `<orgName>-*` namespaces
- No cluster-scoped resource access

This means a customer's ArgoCD Applications can only deploy into their own namespaces and only from their own repos.

### Step 6 — Kubernetes namespace + RBAC + image pull secret

Creates the initial namespace `<orgName>-<repoName>` and sets up:

**Runner RBAC:** A `Role` + `RoleBinding` that grants the `gitea-runner-service-account` permission to `get`/`list`/`patch` Deployments in the namespace. This is what allows the CI pipeline to trigger `kubectl rollout restart` after a successful image push.

**Image pull secret:** Creates a `kubernetes.io/dockerconfigjson` secret (`gitea-registry-pull`) in the namespace using the `registry-pull` service account credentials, and patches the `default` ServiceAccount to reference it as an `imagePullSecret`. This ensures all pods in the namespace can pull images from the Gitea container registry without needing explicit `imagePullSecrets` in each Deployment spec.

> **Note:** The cluster-wide `RegistryAuthConfig` (applied by `apply-node-registry-config.sh`) is also configured on every Talos node, but due to a containerd v2 limitation it does not take effect when `config_path` is also set (which it is, from `RegistryTLSConfig`). The Kubernetes imagePullSecret on the `default` ServiceAccount is therefore the reliable mechanism.

### Step 7 — CI service user + Actions secrets

Creates a dedicated CI service user `ci-<orgName>` with write access to the org, then:
- Creates a `write:package` token for container registry pushes
- Stores `CI_REGISTRY_TOKEN` and `CI_REGISTRY_USER` as **org-level secrets** in Gitea, so every repository in the org inherits them automatically
- Sets repo-level **variables**: `REGISTRY_DOMAIN`, `CUSTOMER_ORG`, `APP_NAME`, `NAMESPACE`

---

## What Happens After Bootstrap

Once the descriptor is committed to `cluster-services`, the automated flow takes over:

```
bootstrap-customer.sh commits customers/acme/acme.yaml
        │
        ▼
customer-apps ApplicationSet (polls every ~3 min)
        │  reads customers/*/*.yaml via Git generator
        │  scans acme Gitea org via SCM provider
        │
        ▼
ArgoCD Application "customer-acme-app" created
        │  source: https://gitea.../acme/app.git @ main
        │  path: deploy/
        │  project: customer-acme
        │
        ▼
ArgoCD syncs deploy/ manifests to namespace acme-app
  → Deployment, Service, IngressRoute created
  → Pod scheduled, pulls image from gitea.../acme/app:latest
  → Service becomes available at <ingress-host>

Developer pushes a commit
        │
        ▼
Gitea Actions CI pipeline runs on the cluster runner
  1. docker build
  2. docker push gitea.../acme/app:latest
  3. kubectl rollout restart deployment/app -n acme-app
        │
        ▼
New pod starts, pulls fresh image, old pod terminates
ArgoCD re-syncs on next poll (no manifest change, noop)
```

---

## How the ApplicationSet Discovers Repos

The `customer-apps` ApplicationSet uses a **Matrix generator** combining two child generators:

**Child 1 — Git files generator**
- Reads every `customers/*/*.yaml` from the `cluster-services` repo
- Provides `customerName` and `gitea.orgName` parameters to child 2

**Child 2 — SCM provider generator**
- Scans the Gitea org returned by child 1 for repositories containing a `deploy/` directory
- Returns repo metadata: `repository`, `branch`, `url`

**Matrix output:** One set of parameters per `(customer descriptor × matching repo)`. A customer org with three repos each containing `deploy/` will produce three ArgoCD Applications.

**Adding a new repo** to an existing customer's org: simply create the repo with a `deploy/` directory. The ApplicationSet discovers it on the next poll (~3 minutes) and creates an Application automatically — no re-running `bootstrap-customer.sh` required.

---

## Naming Conventions

| Object | Format | Example |
|--------|--------|---------|
| Gitea org | `<orgName>` | `acme` |
| Gitea repo | `<repoName>` | `app` |
| Kubernetes namespace | `<orgName>-<repoName>` | `acme-app` |
| ArgoCD Application | `customer-<customerName>-<repoName>` | `customer-acme-app` |
| ArgoCD AppProject | `customer-<customerName>` | `customer-acme` |
| Gitea CI user | `ci-<orgName>` | `ci-acme` |
| imagePullSecret | `gitea-registry-pull` | `gitea-registry-pull` |

---

## Prerequisites

Before running `bootstrap-customer.sh`, the cluster must be fully bootstrapped:

- Gitea running and bootstrapped (`gitea-bootstrap.sh` has been run)
- The `registry-pull` Gitea user and `gitea/gitea-registry-pull-credentials` K8s secret must exist (created by `gitea-bootstrap.sh`)
- The `customer-apps` ApplicationSet deployed (done by `cluster-bootstrap.sh`)
- ArgoCD connected to Gitea (done by `cluster-bootstrap.sh`)

---

## Re-running Safely

All steps in `bootstrap-customer.sh` are idempotent:
- Existing Gitea org/repo → skipped (use `--force-recreate` to replace)
- Existing K8s secrets and namespaces → skipped
- Existing Gitea org memberships → silently succeed
- Existing customer descriptor file → updated in place (no duplicate commit)
- Existing AppProject → applied with `kubectl apply` (no-op if unchanged)

It is safe to re-run the script at any time to repair a partial bootstrap or to add new memberships (e.g. `registry-pull`) to a customer org that was bootstrapped before these accounts existed.

---

## Information for Customer Developers

The [example-gitops-customer](../../../../example-gitops-customer/README.md) template repository contains a developer-facing README that `bootstrap-customer.sh` substitutes with real values (org name, namespace, ArgoCD project, ingress URL, CI variables, etc.) when it pushes the template to the customer's Gitea repo.

**The README a developer receives is therefore already customer-specific** — they see their actual namespace, project name, image registry path, and live URL rather than placeholder text.

To update the information all future customers receive, edit [example-gitops-customer/README.md](../../../../example-gitops-customer/README.md). Available substitution tokens:

| Token | Replaced with |
|-------|--------------|
| `PLACEHOLDER_GITEA_DOMAIN` | Gitea hostname (e.g. `gitea.example.com`) |
| `PLACEHOLDER_ORG` | Gitea org name |
| `PLACEHOLDER_APP` | Repo / application name |
| `PLACEHOLDER_NAMESPACE` | Kubernetes namespace (`<orgName>-<repoName>`) |
| `PLACEHOLDER_CLUSTER_DOMAIN` | Cluster external domain |
| `PLACEHOLDER_CUSTOMER_NAME` | Customer name (used for ArgoCD project: `customer-<name>`) |
| `PLACEHOLDER_INGRESS_HOST` | Ingress hostname (default: `<customerName>.<clusterDomain>`) |
