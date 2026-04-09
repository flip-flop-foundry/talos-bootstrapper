# Talos Kubernetes Bootstrapper

GitOps-based Talos Kubernetes cluster bootstrapper. Automates provisioning of production-grade K8s clusters from bare metal to fully operational, using a three-tier templating system and ArgoCD for ongoing management.

## Usage Modes

### Mode A — Submodule (recommended)

Keep sensitive cluster configuration in a **private cluster repo** and use this repo as a git submodule. Scripts and base templates remain public; overlays (with passwords, CIDRs, domain names) stay private.

```
my-cluster-repo/            # Private git repo
├── talos-bootstraper/      # This repo as a git submodule
│   ├── adminTasks/
│   └── base/
├── overlays/               # Your private cluster configs
│   └── mycluster/
│       └── mycluster.env
└── rendered/               # Gitignored output
```

**Quick start:**

```bash
# 1. Create your cluster repo and add this as a submodule
git init my-cluster && cd my-cluster
git submodule add https://github.com/flip-flop-foundry/talos-bootstraper talos-bootstraper

# 2. Create the expected directories and copy an example overlay into your cluster repo
mkdir -p overlays rendered
cp -r talos-bootstraper/overlays/yourCluster-l2 overlays/mycluster
mv overlays/mycluster/yourCluster-l2.env overlays/mycluster/mycluster.env

# 3. Edit the env file, then run the scripts via the submodule path
./talos-bootstraper/adminTasks/cluster-initialSetup.sh overlays/mycluster/mycluster.env
./talos-bootstraper/adminTasks/render-overlay.sh overlays/mycluster/mycluster.env
./talos-bootstraper/adminTasks/cluster-bootstrap.sh overlays/mycluster/mycluster.env
```

See [`examples/cluster-repo/`](examples/cluster-repo/) for a full template including `.vscode/tasks.json` and `.gitignore`.

### Mode B — Single repo (original)

Clone this repo directly and create overlays inside it. Simpler setup, but your cluster configuration lives in the same repo as the scripts.

```bash
# 1. Copy an example overlay
cp -r overlays/yourCluster-l2 overlays/mycluster
mv overlays/mycluster/yourCluster-l2.env overlays/mycluster/mycluster.env

# 2. Edit the env file, then run the scripts
./adminTasks/cluster-initialSetup.sh overlays/mycluster/mycluster.env
./adminTasks/render-overlay.sh overlays/mycluster/mycluster.env
./adminTasks/cluster-bootstrap.sh overlays/mycluster/mycluster.env
```

## Architecture

```
base/                    # Component templates with ${VAR} placeholders
overlays/                # Mode A: example overlays in this repo; Mode B: real cluster overlays live here
  <cluster>/
    <cluster>.env        # All cluster configuration for that cluster overlay
    talos/               # Generated Talos machine configs + optional cluster/node patch files
rendered/                # OUTPUT (gitignored) — final manifests after rendering
adminTasks/              # Bootstrap and rendering scripts
  lib/                   # Shared shell libraries
  pxe/                   # iPXE network boot infrastructure (Docker-based)
examples/
  cluster-repo/          # Template for a private cluster repo using this as a submodule
```

### Rendering Pipeline

```
base/<component>/*.yaml  ──┐
                            ├──> yq merge (overlay wins) ──> envsubst ──> rendered/<cluster>/
overlays/<cluster>/<component>/*.yaml ─┘
```

The `EXCLUDED_BASE` array in each `.env` file controls which base components or files are skipped during rendering.

## LoadBalancer Mode: L2 vs BGP

Cilium provides LoadBalancer IP advertisement. Two modes are supported, toggled entirely through the `EXCLUDED_BASE` array in the overlay `.env` file.

### L2 Mode (default)

Uses ARP announcements on the node network. LoadBalancer IPs must be from the node subnet and excluded from DHCP.

**Configuration:**
```bash
# IP range on the node subnet, excluded from DHCP
export CILIUM_LB_IP_CIDR="192.168.1.200/28"

# Exclude BGP CRDs (not needed for L2)
export EXCLUDED_BASE=(
    "cilium/ciliumBGPClusterConfig.yaml"
    "cilium/ciliumBGPPeerConfig.yaml"
    "cilium/ciliumBGPAdvertisement.yaml"
)
```

See [overlays/yourCluster-l2/](overlays/yourCluster-l2/) for a complete example.

### BGP Mode

Advertises LoadBalancer IPs via eBGP to an external router. IPs can be any routable CIDR that doesn't overlap with Pod or Service CIDRs.

**Configuration:**
```bash
# Any routable CIDR
export CILIUM_LB_IP_CIDR="10.32.0.0/24"

# BGP peering parameters
export CILIUM_BGP_LOCAL_ASN="64513"
export CILIUM_BGP_PEER_ASN="64512"
export CILIUM_BGP_PEER_ADDRESS="192.168.0.1"

# Exclude L2 policy (not needed for BGP)
export EXCLUDED_BASE=(
    "cilium/ciliumL2AnnouncementPolicy.yaml"
)
```

BGP overlays also need a Talos patch to add the `bgpPeer` node label. Create `overlays/<cluster>/talos/talosPatchConfig.yaml`:
```yaml
machine:
  nodeLabels:
    bgpPeer: "true"
```

See [overlays/yourCluster-bgp/](overlays/yourCluster-bgp/) for a complete example.

### Design

- **CiliumLoadBalancerIPPool** is common to both modes — always rendered
- **Services** (Traefik, ArgoCD) are mode-agnostic — no `loadBalancerClass` needed since Cilium is the sole LoadBalancer controller
- Mode selection is controlled purely by which Cilium CRs get rendered via `EXCLUDED_BASE`

## Components

| Component | Purpose | Helm Chart |
|-----------|---------|------------|
| Cilium | CNI, kube-proxy replacement, LoadBalancer | `https://helm.cilium.io/` |
| Traefik | Ingress controller | `https://traefik.github.io/charts` |
| ArgoCD | GitOps continuous delivery | `https://argoproj.github.io/argo-helm` |
| cert-manager | TLS certificate management | `https://charts.jetstack.io` |
| Longhorn | Distributed block storage | `https://charts.longhorn.io/` |
| CNPG | PostgreSQL operator | CloudNativePG |
| Gitea | Self-hosted Git + CI runners | `https://dl.gitea.com/charts/` |
| External-DNS | Automatic DNS record management | `https://kubernetes-sigs.github.io/external-dns/` |
| Metrics Server | Resource metrics for HPA/VPA | `https://kubernetes-sigs.github.io/metrics-server/` |
| Reloader | Automatic pod restart on config changes | `https://stakater.github.io/stakater-helm-charts/` |

## Bootstrap Workflow

```
1. cluster-initialSetup.sh  → Install prerequisites, generate Talos machine configs
2. [Manual]                  → Install Talos OS on nodes
3. cluster-bootstrap.sh      → Full bootstrap:
   ├─ Setup kubeconfig + helm repos
   ├─ Install Cilium (networking — must be first)
   ├─ Install ArgoCD with bootstrap values
   ├─ Deploy temporary git-bootstrap-server pod
   ├─ kubectl apply initial manifests
   ├─ Deploy all ArgoCD Applications
   ├─ gitea-bootstrap.sh → Create Gitea org/repo, push code
   └─ Upgrade ArgoCD to final config pointing at Gitea
4. ArgoCD manages everything → auto-sync, self-heal, prune
```

## iPXE Network Boot

Instead of manually flashing USB sticks with Talos, nodes can PXE boot directly into Talos maintenance mode over the network. The PXE setup uses the [Talos Image Factory](https://factory.talos.dev) API to build custom schematics with your configured extensions and kernel args, then serves boot assets via Docker containers.

### Setup

```bash
./adminTasks/pxe-setup.sh overlays/<cluster>/<cluster>.env
```

This single command:
1. Creates a schematic on the Image Factory (with your extensions + kernel args)
2. Downloads kernel, initramfs, and cmdline assets
3. Generates the iPXE boot script
4. Builds iPXE firmware or generates dnsmasq config (depending on mode)
5. Starts Docker containers (nginx for HTTP, dnsmasq for TFTP)

### Two Modes

**Manual DHCP mode** (`TALOS_PXE_PROXY_DHCP_ENABLED=false`) — default, works cross-subnet:
- Builds custom iPXE firmware (`ipxe.efi`) with an embedded chainload script
- Firmware is served via TFTP; boot assets via HTTP
- Requires router/DHCP config: option 66 (next-server, IP of server running script) + option 67 (boot filename = `ipxe.efi`)
- Works when PXE server and nodes are on different VLANs/subnets

**ProxyDHCP mode** (`TALOS_PXE_PROXY_DHCP_ENABLED=true`) — no router config, same subnet only:
- Runs dnsmasq as a proxyDHCP server alongside your existing DHCP
- Automatically directs PXE clients to TFTP boot firmware, then chainloads to HTTP
- No changes needed on your router
- Requires PXE server and nodes on the same L2 broadcast domain

### PXE Environment Variables

```bash
export TALOS_PXE_ENABLED=true                                    # Enable iPXE network boot
export TALOS_PXE_SERVER_IP="192.168.1.100"                       # IP of the PXE Docker host
export TALOS_PXE_SERVER_PORT=80                                  # HTTP port (use 80 for DHCP compatibility)
export TALOS_PXE_PROXY_DHCP_ENABLED=false                        # false=manual DHCP, true=proxyDHCP
export TALOS_PXE_DHCP_RANGE="192.168.1.0,proxy,255.255.255.0"    # Only used when proxyDHCP=true, should be the subnet of the nodes
export TALOS_SCHEMATIC_EXTENSIONS=("siderolabs/iscsi-tools")     # Extensions for PXE schematic
export TALOS_SCHEMATIC_EXTRA_KERNEL_ARGS=("net.ifnames=0")       # Extra kernel args for PXE schematic
```

### Infrastructure

```
adminTasks/pxe/
  docker-compose.yml         # nginx (HTTP) + dnsmasq (TFTP, two profiles)
  nginx.conf                 # Static file server for boot assets
  ipxe-boot.ipxe.template    # iPXE boot script template
  dnsmasq.conf.template      # proxyDHCP config template
  Dockerfile.ipxe            # Builds custom iPXE UEFI firmware (manual DHCP mode)
  assets/                    # Downloaded kernel, initramfs, cmdline (gitignored)
  tftp/                      # Built iPXE firmware for TFTP (gitignored)
```
