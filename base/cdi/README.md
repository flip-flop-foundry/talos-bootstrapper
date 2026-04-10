# CDI (Containerized Data Importer)

CDI provides `DataVolume` and import/clone/upload workflows for KubeVirt virtual machine disks.
If you use `kubevirt-manager`, CDI should be installed.

## Why CDI with Longhorn

Longhorn provides the storage backend (PVCs/volume replicas), while CDI provides disk lifecycle workflows:

- Import VM images from HTTP/S3/registry sources into PVC-backed volumes.
- Clone/blank DataVolumes and populate VM disks declaratively.
- Support upload-based image onboarding workflows.

In short: Longhorn stores the bytes, CDI manages how VM disk bytes are created and moved.

## Security Considerations

- Restrict who can create `DataVolume` resources; they can trigger image imports and consume storage quickly.
- Prefer trusted image sources and pin/check checksums where possible.
- Keep CDI webhooks/APIServices healthy; failed validation can block VM disk workflows.
- Treat image import as an egress path; enforce network policy/egress controls according to your security model.
- Keep storage encryption-at-rest enabled at the StorageClass/backend layer (for this repo, Longhorn classes already support encrypted modes).

## Placement

This repo uses a conservative default:

- Base CDI CR pins infra/workload placement to Linux nodes.
- The `tuborgnetes` overlay additionally excludes nodes `brew-10` through `brew-17` from CDI infra/workload placement.

This mirrors the existing strategy used for KubeVirt workload scheduling in `tuborgnetes`.
