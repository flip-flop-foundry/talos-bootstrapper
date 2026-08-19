# KubeVirt

## What it does

KubeVirt extends Kubernetes with virtualization capabilities, allowing you to run and manage traditional virtual machines (VMs) alongside container workloads. It deploys a set of controllers (`virt-api`, `virt-controller`, `virt-handler`) that enable creating, scheduling, and managing VMs using standard Kubernetes APIs and resources such as `VirtualMachine` and `VirtualMachineInstance`.

## Why it was added

KubeVirt enables running legacy or non-containerisable workloads as VMs within the same Kubernetes cluster used for containerised services. This avoids maintaining a separate hypervisor infrastructure and allows VMs to benefit from Kubernetes scheduling, networking (via Cilium), and storage (via Longhorn).

## How it is deployed

KubeVirt does **not** have an official Helm chart. The deployment is fully managed by ArgoCD using a **Kustomize remote resource**:

- `kustomization.yaml` references the upstream `kubevirt-operator.yaml` release manifest directly from GitHub, plus the local `kubevirtCR.yaml`.
- ArgoCD detects the `kustomization.yaml` and runs `kustomize build`, which downloads the operator manifest and combines it with the CR.
- The operator manifest includes the namespace, CRDs, RBAC, and the virt-operator Deployment.
- The `kubevirtCR.yaml` contains the KubeVirt custom resource that configures the actual KubeVirt installation (networking, tolerations, etc.).

This follows the same pattern as the `csi-snapshot-controller`, which also deploys upstream manifests directly via ArgoCD.

## Enabling KubeVirt

KubeVirt is **excluded by default** in the example overlays. To enable it:

1. Remove `"kubevirt"` from the `EXCLUDED_BASE` array in your overlay's `.env` file.
2. Ensure `KUBEVIRT_VERSION` and `KUBEVIRT_NAMESPACE` are exported (they are pre-defined in the example `.env` files).
3. Re-render via the "Render Overlay" VS Code task (or run `render-overlay.sh` from the devenv workspace).
4. For new clusters, the "Apply Overlay" task (`cluster-bootstrap.sh` in the devenv workspace) deploys the ArgoCD Application automatically.
5. For existing clusters, apply the ArgoCD Application:
   ```bash
   kubectl apply -f $env/_rendered/kubevirt/kubevirtArgoApp.yaml
   ```

## Upgrading

1. Update `KUBEVIRT_VERSION` in your overlay's `.env` file.
2. Re-render the overlay.
3. ArgoCD will automatically sync the updated operator and CR via the new Kustomize remote resource URL.

## Talos-specific notes

`base/talos/talosPatchConfig.yaml` includes settings that support KubeVirt out of the box:

- **`vfio_pci`** kernel module — enables PCI device passthrough for GPU/NIC passthrough to VMs.
- **`vm.nr_hugepages: "1024"`** — pre-allocates hugepages for VM memory performance.
- **KVM support** — Talos Linux includes KVM kernel support by default (`kvm`, `kvm_intel`, `kvm_amd` are compiled in).
- **Containerd changes:** - for disk imports to work containerd config changes are needed "device_ownership_from_security_context"

Hardware virtualization (Intel VT-x or AMD-V) must be enabled in the node BIOS/UEFI.
On proxmox the cpu type must be set to "host"

### CDI importer failure on Talos — Block volumes and `device_ownership_from_security_context`

**Symptom**: CDI importer pod crashes immediately with:
```
blockdev: cannot open /dev/cdi-block-volume: Permission denied
```

**Root cause**: When importing to a `volumeMode: Block` PVC, CDI runs `blockdev --getsize64 /dev/cdi-block-volume` to check the device size before starting the transfer. On Talos, containerd creates block device nodes inside the pod owned by `root:root` with mode `0660`. The CDI importer runs as a non-root user and cannot open the device, so the process fails immediately — before any data is transferred.

**Fix — `device_ownership_from_security_context`**

Add the following stanza to the containerd CRI runtime config:

```toml
[plugins."io.containerd.cri.v1.runtime"]
  device_ownership_from_security_context = true
```

This instructs containerd to `chown` block device nodes inside the pod to match the pod's `runAsUser`/`runAsGroup`, making the device accessible to non-root containers. With this in place, the CDI importer can open the block device and the DataVolume import completes successfully (`Succeeded` at 100%).

**Applying on Talos**

On Talos this is applied via a `machine.files` drop-in at `/etc/cri/conf.d/20-customization.part`. Because `yq` deep-merge replaces arrays wholesale, an overlay `machine.files` entry must include **all** required containerd stanzas in a single file — not just the new one. The existing Spegel stanza (`discard_unpacked_layers = false`) must be carried alongside. This is handled in `base/talos/talosPatchConfig.yaml` and applies to all clusters.

After applying the patch with `talosctl apply-config`, Talos triggers an automatic reboot (the CRI config cannot be reloaded in-place). Verify the file on each node after reboot:

```bash
talosctl read /etc/cri/conf.d/20-customization.part --nodes <node>
```

**Workaround if the containerd fix cannot be applied**

If the patch cannot be rolled out immediately, VM disks can temporarily use `volumeMode: Filesystem` with a standard RWO storage class. CDI's filesystem import path writes a `disk.img` file via `qemu-img` and never touches block devices, so the permission error does not occur. Set `evictionStrategy: None` — live migration is not available without Block + RWX volumes.

## Dependencies

None beyond standard cluster infrastructure. KubeVirt uses:
- Kubernetes API for scheduling and management
- Node-level KVM for hardware virtualization
- Cilium for pod/VM networking (masquerade mode by default)
- Longhorn RWX migratable block volumes for stateful VM live migration tests

> **Known limitation — encrypted volumes + live migration**: Longhorn encrypted volumes (`encrypted: "true"`) are incompatible with KubeVirt live migration in Longhorn ≤ v1.11.x. During migration the CSI node plugin on the target node tries to run `cryptsetup luksOpen` on the block device while it is already open on the source node, which crashes the plugin and leaves the migration pod stuck. The `longhorn-csi-plugin` DaemonSet pod on the target node will show multiple restarts. This is tracked in [longhorn/longhorn #11510](https://github.com/longhorn/longhorn/issues/11510) and targeted for fix in Longhorn v1.12.0.
>
> **Workaround**: Use an unencrypted `migratable: "true"` storage class for VM volumes that need live migration. If no unencrypted migratable class exists, add one to `base/longhorn/storage-classes.yaml` (omit the `encrypted` and `csi.storage.k8s.io/*-secret-*` parameters, keep `migratable: "true"` and `accessMode: ReadWriteMany`). VMs that do not require live migration can continue to use encrypted storage.

## Dependents

None currently.

## User Guide

### Verifying the installation

```bash
# Check operator status
kubectl get pods -n kubevirt

# Check KubeVirt CR status
kubectl get kubevirt -n kubevirt -o yaml

# All components should show phase "Deployed"
kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}'
```


### Creating a VM

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: example-vm
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
        resources:
          requests:
            memory: 1Gi
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/kubevirt/cirros-container-disk-demo
```

### Managing VMs

```bash
# Install virtctl CLI for VM management
export VERSION=$(kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.targetKubeVirtVersion}')
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-amd64
chmod +x virtctl

# Start/stop VMs
./virtctl start <vm-name>
./virtctl stop <vm-name>

# Console access
./virtctl console <vm-name>
```

### Console access options

`virtctl` remains the most direct option for serial console and VNC access. If you want to avoid local client installation on user laptops, two practical alternatives are:

- Run `virtctl` in a browser-accessible admin environment (for example, a hardened toolbox pod or shared jump-host) and provide shell access there.
- Deploy a web UI that integrates with KubeVirt subresources (for example, KubeVirt Manager) behind your existing ingress/auth stack.

For production access, treat VNC/noVNC endpoints as privileged operations and protect them with SSO, RBAC, and audit logging.

### Future enhancements

- **CDI (Containerized Data Importer)** — an optional companion component for importing VM disk images and managing DataVolumes when your KubeVirt workloads need image import workflows.
- **Multus** — for attaching VMs to additional networks (bridge, SR-IOV).
- **Snapshot/restore** — KubeVirt supports VM snapshots via the CSI snapshot controller already deployed in this cluster.

### kubevirt-manager compatibility

The KubeVirt CR in this repository enables a conservative subset of feature gates used by kubevirt-manager:

- `LiveMigration`
- `Snapshot`
- `VMExport`
- `ExpandDisks`
- `HotplugVolumes`

`HostDisk` and `ExperimentalIgnitionSupport` are intentionally not enabled by default due to broader security and operational impact.
