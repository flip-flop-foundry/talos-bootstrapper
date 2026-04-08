# Longhorn

## What it does

[Longhorn](https://longhorn.io/) is a cloud-native distributed block storage system for Kubernetes. It provides persistent volumes with built-in replication, snapshotting, and backup capabilities — all managed through Kubernetes custom resources.

This component installs the Longhorn system and configures:

- **Storage classes** for different replication and retention profiles
- **Snapshot classes** for CSI-based volume snapshots
- **Backup target** credentials for off-cluster backup storage
- **Auto-disk discovery** for worker nodes

## Why it was added

The cluster runs on bare-metal nodes without a cloud storage backend. Longhorn provides replicated, resilient persistent storage that survives individual node failures and supports scheduled backups via the CSI snapshot mechanism.

## Dependencies

- **csi-snapshot-controller** — Longhorn uses `VolumeSnapshotClass` resources that require the CSI snapshot CRDs and controller.

## Dependents

- **cnpg** — all CNPG database clusters use Longhorn storage classes for their persistent volumes and Longhorn snapshot classes for backups.
- **gitea** — Gitea's CNPG database uses Longhorn-backed storage.

## User Guide

### Accessing the Longhorn dashboard

The Longhorn dashboard is exposed via a Traefik `IngressRoute`. The URL is configured per cluster. Access requires authentication via a `Secret`-backed BasicAuth middleware.

### Checking volume health

```bash
kubectl -n longhorn-system get volumes.longhorn.io
```

Or use the Longhorn UI for a visual overview.

### Storage classes

The cluster defines several storage classes for different use cases:

| Storage Class | Replicas | Retain Policy | Use Case |
|---------------|----------|---------------|---------|
| `pvckey-2replica-retained-backedup-ssd-cp` | 2 | Retain | Database volumes (CNPG) |

Check the `storage-classes.yaml` file for the full list.

### Backup configuration

Backup targets (S3, NFS, etc.) are configured via `LONGHORN_BACKUP_TARGET` in the overlay `.env` file. Credentials are stored in a Kubernetes `Secret` (`defaultBackupTargetCredentials.yaml`).

### Disk configuration — two-stage process

Disk handling is split across two systems that work together:

**Stage 1 — Talos machine config (at node provisioning time)**

`cluster-initialSetup.sh` calls `detect_node_disks` (via `lib/disk-detection.sh`) for each node. It queries `talosctl get mounts` to identify the system disk and `talosctl get disks` to find additional disks. For each extra disk it appends a `UserVolumeConfig` document to the node's machine config YAML:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: disk1Ssd
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/sdb" && disk.rotational == false
  grow: true
  minSize: 10GB
```

Talos reads this at boot and formats and mounts the disk at `/var/mnt/disk1Ssd`.

**Stage 2 — Longhorn node config (at runtime, on every ArgoCD sync)**

The `autoDiscoverDisksJob.yaml` Job runs as an ArgoCD sync hook (`BeforeHookCreation` ensures the previous Job is deleted first). It runs an Alpine container that:

1. Waits for Longhorn nodes to reach Ready state
2. For each node, queries `talosctl get mounts` to find `/var/lib/longhorn` (root disk) and all `/var/mnt/*` mounts (the UserVolumes from Stage 1)
3. Detects whether each disk is SSD or HDD via the Talos API
4. Tags the Longhorn node as `controlplane` or `workernode`
5. Patches `node.longhorn.io` with the discovered disk paths and tags — preserving any existing manual configuration

The two stages connect like this:
```
Talos UserVolumeConfig → formats /dev/sdb → mounts at /var/mnt/disk1Ssd
                                                         ↓
Longhorn Job → sees /var/mnt/disk1Ssd in talosctl get mounts
             → patches Longhorn node to use /var/mnt/disk1Ssd as a storage disk
```

Set `LONGHORN_IGNORE_USB_DISKS=true` in the overlay `.env` to exclude USB-attached disks from both stages.
