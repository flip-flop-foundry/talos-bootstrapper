# Talos Kubernetes Bootstrapper

GitOps-based Talos Kubernetes cluster bootstrapper. Automates provisioning of production-grade K8s clusters from bare metal to fully operational, using a three-tier templating system and ArgoCD for ongoing management.

## Usage Modes

### Mode A — Submodule (recommended)

Keeps sensitive cluster configuration in a **private cluster repo** and uses this repo as a git submodule. Scripts and base templates remain public; overlays (with passwords, CIDRs, domain names) stay private.

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

Fork https://github.com/flip-flop-foundry/talos-bootstraper-cluster-repo-example

Follow the README.md in that repo to get started

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
```

### Rendering Pipeline

```
base/<component>/*.yaml  ──┐
                            ├──> yq merge (overlay wins) ──> envsubst ──> rendered/<cluster>/
overlays/<cluster>/<component>/*.yaml ─┘
```

The `EXCLUDED_BASE` array in each `.env` file controls which components or files are skipped during rendering. Matching is done on the rendered output path, so it applies to base files, overlay files, and merged files.

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
1. [Manual]                  → Boot nodes from Talos ISO/image into maintenance mode
                               (skip for PXE — cluster-initialSetup.sh handles this automatically)
2. cluster-initialSetup.sh  → Generate Talos machine configs and apply them to nodes in maintenance mode
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

## Node Provisioning — Installing Talos OS

Before running `cluster-initialSetup.sh`, nodes must be booted into Talos maintenance mode. The script generates machine configs and immediately applies them to the waiting nodes — so they need to be reachable first. How you get them there depends on your hardware.

> **Exception — PXE boot:** When `TALOS_PXE_ENABLED=true`, `cluster-initialSetup.sh` starts the PXE server automatically and waits for nodes to boot. No manual step required.

### Choosing the Right Installer Type

`TALOS_INSTALLER_TYPE` in your `.env` file controls which image the cluster uses for the [Talos Image Factory](https://factory.talos.dev). It also controls how Talos identifies the machine's platform at boot time.

| Installer Type | Platform | When to Use |
|----------------|----------|-------------|
| `installer` | `metal` | Bare metal, no Secure Boot |
| `installer-secureboot` | `metal` | Bare metal with UEFI Secure Boot |
| `metal-installer-secureboot` | `metal` | Bare metal with Secure Boot (preferred for modern hardware) |
| `nocloud-installer-secureboot` | `nocloud` | VMs on Proxmox, cloud, or any hypervisor — Secure Boot |

> **Raspberry Pi 4** does not use `TALOS_INSTALLER_TYPE` for the initial flash. It uses a dedicated `rpi_generic` overlay image (raw `.raw.xz`). See below.

### Bare Metal (USB ISO)

1. Get the ISO URL — run `pxe-setup.sh` (it prints the URL), or build it manually once you have the schematic ID (printed by `cluster-initialSetup.sh` or `pxe-setup.sh`):
   ```
   https://factory.talos.dev/image/<SCHEMATIC_ID>/<TALOS_INSTALL_VERSION>/metal-amd64.iso
   https://factory.talos.dev/image/<SCHEMATIC_ID>/<TALOS_INSTALL_VERSION>/metal-amd64-secureboot.iso
   ```
2. Flash the ISO to a USB stick (e.g. with [Balena Etcher](https://etcher.balena.io/) or `dd`).
3. Boot the node from USB — Talos enters maintenance mode.
4. With all nodes in maintenance mode, run `cluster-initialSetup.sh` — it generates and applies the machine configs.

Use `TALOS_INSTALLER_TYPE="metal-installer-secureboot"` for modern bare-metal hardware with Secure Boot, or `installer-secureboot` / `installer` for older setups.

### Proxmox VMs

Talos runs as a VM on Proxmox using the `nocloud` platform. The `nocloud` installer type tells Talos it is running in a generic VM environment (not a named cloud provider). Machine config is applied via `talosctl apply-config` over the network once the VM is in maintenance mode — no cloud-init drive is needed.

**Installer type:**
```bash
export TALOS_INSTALLER_TYPE="nocloud-installer-secureboot"
```

**VM setup in Proxmox:**
1. Download the Talos ISO from the Image Factory:
   ```
   https://factory.talos.dev/image/<SCHEMATIC_ID>/<TALOS_INSTALL_VERSION>/metal-amd64.iso
   ```
2. Upload the ISO to your Proxmox ISO storage (Datacenter → Storage → ISO Images).
3. Create a VM:
   - **Machine type:** `q35`
   - **BIOS:** `OVMF (UEFI)` with EFI disk enabled (required for Secure Boot; use `SeaBIOS` + `installer` type if you want non-Secure Boot)
   - **Boot disk:** `VirtIO SCSI` or `SATA`, ≥ `TALOS_MIN_INSTALL_DISK_SIZE_GB`
   - **Network:** `VirtIO` — ensure the VM NIC is on the same network as your other cluster nodes
   - **CD-ROM:** attach the Talos ISO
4. Start the VM — it boots from the ISO into Talos maintenance mode.
5. With all VMs in maintenance mode, run `cluster-initialSetup.sh` — it generates and applies the machine configs.
6. After Talos installs to disk and reboots, detach/remove the ISO.

> **Tip:** Set `LONGHORN_IGNORE_USB_DISKS=true` and `TALOS_MIN_INSTALL_DISK_SIZE_GB=64` in your overlay — VMs don't have USB storage, and the install disk should be a proper virtual disk.

### Raspberry Pi 4

Raspberry Pi 4 uses a dedicated image with U-Boot and the `rpi_generic` SBC overlay — no separate UEFI firmware is needed.

**Installer type:** Not applicable for initial flash. The RPi image is built automatically alongside your cluster schematic when running `pxe-setup.sh`.

1. Run `pxe-setup.sh` — it prints an SD card image URL:
   ```
   https://factory.talos.dev/image/<RPI_SCHEMATIC_ID>/<TALOS_INSTALL_VERSION>/metal-arm64.raw.xz
   ```
   The RPi schematic includes the same extensions as your cluster, plus the `siderolabs/sbc-raspberrypi` overlay.
2. Flash to a microSD card (or USB boot drive):
   ```bash
   # macOS
   xz -d -c metal-arm64.raw.xz | sudo dd conv=fsync bs=16m of=/dev/rdiskN

   # Linux
   xz -d -c metal-arm64.raw.xz | sudo dd conv=fsync bs=4M of=/dev/sdX
   ```
3. Insert the card and power on the Pi — Talos enters maintenance mode.
4. With all nodes in maintenance mode, run `cluster-initialSetup.sh` — it generates and applies the machine configs.

**Raspberry Pi node tuning** — RPi 4 nodes are often memory-constrained. Disable hugepages in the per-node patch:
```yaml
# overlays/<cluster>/talos/nodes/<hostname>.yaml
machine:
  sysctls:
    vm.nr_hugepages: "0"
```

> **Mixed clusters:** You can run Proxmox VMs and Raspberry Pis in the same cluster. Each node gets its own machine config regardless of hardware type. The `TALOS_INSTALLER_TYPE` in your `.env` applies to the **install image** embedded in the machine config; ensure it matches the majority of your nodes or use per-node patches for outliers.

### PXE Boot

For bare-metal nodes that can network boot, see the [iPXE Network Boot](#ipxe-network-boot) section below. PXE eliminates the need to flash USB sticks and works well in rack environments. Not applicable to Proxmox VMs or Raspberry Pis.

---

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
