# Overlays

Each subdirectory here is a cluster overlay — the cluster-specific configuration
that is merged with the base templates from `../talos-bootstraper/base/` during rendering.

## Creating a new overlay

```bash
# Copy an example from the submodule
cp -r ../talos-bootstraper/overlays/yourCluster-l2 yourCluster

# Rename the env file
mv yourCluster/yourCluster-l2.env yourCluster/yourCluster.env
```

Edit the `.env` file and set at minimum:
- `OVERLAY_NAME` (must match the directory name)
- `CLUSTER_EXTERNAL_DOMAIN`
- `TALOS_CONTROL_NODES` and `TALOS_WORKER_NODES`
- `CILIUM_LB_IP_CIDR`

Refer to `../talos-bootstraper/overlays/yourCluster-l2/yourCluster-l2.env` for a
fully documented example of every available variable.
