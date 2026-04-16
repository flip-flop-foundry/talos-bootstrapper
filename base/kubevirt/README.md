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
3. Re-render: `./adminTasks/render-overlay.sh overlays/<cluster>/<cluster>.env`
4. For new clusters, `cluster-bootstrap.sh` deploys the ArgoCD Application automatically.
5. For existing clusters, apply the ArgoCD Application:
   ```bash
   kubectl apply -f rendered/<cluster>/kubevirt/kubevirtArgoApp.yaml
   ```

## Upgrading

1. Update `KUBEVIRT_VERSION` in your overlay's `.env` file.
2. Re-render the overlay.
3. ArgoCD will automatically sync the updated operator and CR via the new Kustomize remote resource URL.

## Talos-specific notes

The existing Talos machine configuration (`base/talos/talosPatchConfig.yaml`) already includes settings that support KubeVirt:

- **`vfio_pci`** kernel module — enables PCI device passthrough for GPU/NIC passthrough to VMs.
- **`vm.nr_hugepages: "1024"`** — pre-allocates hugepages for VM memory performance.
- **KVM support** — Talos Linux includes KVM kernel support by default (`kvm`, `kvm_intel`, `kvm_amd` are compiled in).

Hardware virtualization (Intel VT-x or AMD-V) must be enabled in the node BIOS/UEFI.

## Dependencies

None beyond standard cluster infrastructure. KubeVirt uses:
- Kubernetes API for scheduling and management
- Node-level KVM for hardware virtualization
- Cilium for pod/VM networking (masquerade mode by default)
- Longhorn RWX migratable block volumes for stateful VM live migration tests

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
