# Gitea

## What it does

[Gitea](https://gitea.com/) is a lightweight, self-hosted Git service. In this cluster it serves as the **GitOps source of truth**: ArgoCD pulls rendered manifests and Helm values from the Gitea repository, ensuring all cluster state is version-controlled and auditable.

Gitea also hosts the Gitea Actions runners that execute CI/CD pipelines for workloads hosted in the cluster.

## Why it was added

ArgoCD requires a Git repository to read application manifests from. Using a self-hosted Gitea instance keeps all cluster configuration internal — no dependency on external services like GitHub for day-to-day cluster operations.

## Dependencies

- **cnpg** — Gitea stores its application data in a PostgreSQL database managed by a CNPG `Cluster` (`giteaCnpgCluster.yaml`). The CNPG operator must be running before the Gitea `Application` is synced (enforced via ArgoCD sync waves).
- **reloader** — Gitea's `Deployment` is annotated with `reloader.stakater.com/auto: "true"` so it restarts automatically when its TLS certificate or database credentials are rotated.

## Dependents

- **gitea-runners** — the Gitea Actions runner `Deployment` authenticates to this Gitea instance and requires it to be running.
- **argocd** — ArgoCD's production configuration points at the Gitea repository URL. Gitea must be healthy for ArgoCD to reconcile cluster state.

## User Guide

### Accessing the Gitea UI

The Gitea web interface is exposed via a Traefik `IngressRoute` at `https://${GITEA_DOMAIN_NAME}`. DNS is managed by external-dns automatically.

### Admin credentials

The Gitea admin password is stored in a Kubernetes `Secret` in the Gitea namespace. Retrieve it with:

```bash
kubectl -n <gitea-namespace> get secret gitea-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Connecting to the database directly

```bash
kubectl -n <gitea-namespace> exec -it <gitea-sql-primary-pod> -- psql -U <GITEA_PSQL_USERNAME> gitea
```

### Rotating the admin password

Update the `Secret` and let Reloader restart the Gitea pod:

```bash
kubectl -n <gitea-namespace> patch secret gitea-admin-secret \
  --type='json' -p='[{"op":"replace","path":"/data/password","value":"'$(echo -n 'newpassword' | base64)'"}]'
```

Reloader will detect the change and perform a rolling restart automatically.

### Pushing code changes to the cluster's Gitea

During bootstrap, the "Apply Overlay" task's `gitea-bootstrap.sh` step (in the devenv workspace) creates the organisation, repository, and ArgoCD credentials. For subsequent pushes:

```bash
git remote add gitea https://<GITEA_DOMAIN_NAME>/<org>/<repo>.git
git push gitea main
```
