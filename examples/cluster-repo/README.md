# My Cluster Repo

This repository manages the configuration for my Talos Kubernetes cluster(s).
It uses [talos-bootstraper](https://github.com/flip-flop-foundry/talos-bootstraper)
as a git submodule, keeping private cluster config here and public scripts/base
templates in the submodule.

## Structure

```
my-cluster-repo/
├── talos-bootstraper/      # git submodule — scripts + base component templates
│   ├── adminTasks/         # Bootstrap, render, and utility scripts
│   └── base/               # Cluster-agnostic YAML templates
├── overlays/               # Cluster-specific configuration (this repo, private)
│   └── mycluster/
│       ├── mycluster.env   # All cluster configuration
│       └── talos/          # Generated Talos machine configs + secrets
├── rendered/               # Generated manifests (gitignored, re-run render to regenerate)
└── .vscode/
    └── tasks.json          # VSCode tasks referencing submodule scripts
```

## Setup

### 1. Add the submodule

```bash
git submodule add https://github.com/flip-flop-foundry/talos-bootstraper talos-bootstraper
git submodule update --init --recursive
```

### 2. Create your cluster overlay

Copy one of the example overlays from the submodule:

```bash
# L2 mode (ARP announcements, recommended for most setups)
cp -r talos-bootstraper/overlays/yourCluster-l2 overlays/mycluster

# OR BGP mode (eBGP to a router)
cp -r talos-bootstraper/overlays/yourCluster-bgp overlays/mycluster

# Rename the env file to match your cluster name
mv overlays/mycluster/yourCluster-l2.env overlays/mycluster/mycluster.env
```

Edit `overlays/mycluster/mycluster.env` and update at minimum:
- `OVERLAY_NAME` — must match the directory name
- `CLUSTER_EXTERNAL_DOMAIN` — your cluster's DNS domain
- `TALOS_CONTROL_NODES` and `TALOS_WORKER_NODES` — node FQDNs
- `CILIUM_LB_IP_CIDR` — LoadBalancer IP range
- Passwords/secrets (never commit real values to a public repo)

### 3. Set up VSCode tasks

Copy the VSCode tasks template from the submodule:

```bash
mkdir -p .vscode
cp talos-bootstraper/examples/cluster-repo/.vscode/tasks.json .vscode/tasks.json
```

Update the `options` list in the `envFile` input to include your overlay path(s).

### 4. Generate Talos configs

```bash
./talos-bootstraper/adminTasks/cluster-initialSetup.sh overlays/mycluster/mycluster.env
```

### 5. Render manifests

```bash
./talos-bootstraper/adminTasks/render-overlay.sh overlays/mycluster/mycluster.env
```

### 6. Bootstrap the cluster

```bash
./talos-bootstraper/adminTasks/cluster-bootstrap.sh overlays/mycluster/mycluster.env
```

## .gitignore

Add the following to your `.gitignore`:

```gitignore
rendered/
.DS_Store
.vscode/current/kubeconfig
.vscode/current/talosconfig
```

## Keeping the submodule updated

```bash
# Update to latest talos-bootstraper
git submodule update --remote talos-bootstraper
git add talos-bootstraper
git commit -m "chore: update talos-bootstraper submodule"
```
