# KubeVirt Manager

## What it does

KubeVirt Manager provides a web UI for managing KubeVirt resources, including VMs, migrations, templates, and related objects.

## How it is deployed

This component is deployed via ArgoCD using a Kustomize bundle:

- Upstream release bundle from `kubevirt-manager` (version pinned by `KUBEVIRT_MANAGER_VERSION`)
- Local ingress/TLS/auth manifests for secure UI exposure

## Dependencies

- KubeVirt must already be deployed.
- cert-manager issuer `${TALOS_CLUSTER_NAME}-ca-issuer` must exist.
- Traefik CRDs (`IngressRoute`, `Middleware`) must exist.

## User Guide

### Accessing the UI

The UI is exposed at:

- `https://kubevirt-manager.${CLUSTER_EXTERNAL_DOMAIN}`

Credentials are stored in secret:

- `${KUBEVIRT_MANAGER_NAMESPACE}/kubevirt-manager-ui-auth-secret`

Retrieve password:

```bash
kubectl get secret kubevirt-manager-ui-auth-secret \
  -n ${KUBEVIRT_MANAGER_NAMESPACE} \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Username is `admin`.

### Short runbook: KubeVirt + Longhorn live migration test

1. Render and apply using one of the example overlays included in this repo (shown here with `yourCluster-l2`; use `yourCluster-bgp` if that matches your setup):

```

2. Verify core components:

```bash
kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}' && echo
kubectl get pods -n kubevirt
kubectl get pods -n kubevirt-manager
```

3. Verify test VM and migratable storage:

```bash
kubectl get vm,vmi,pvc -n kubevirt | grep kubevirt-live-migration-test
kubectl get vmi kubevirt-live-migration-test -n kubevirt -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' && echo
```

4. Trigger migration:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: kubevirt-live-migration-test-migration
  namespace: kubevirt
spec:
  vmiName: kubevirt-live-migration-test
EOF
```

5. Watch migration and confirm node change:

```bash
kubectl get vmi kubevirt-live-migration-test -n kubevirt -o wide -w
kubectl get vmim -n kubevirt
```

6. Optional node drain test:

```bash
SRC_NODE=$(kubectl get vmi kubevirt-live-migration-test -n kubevirt -o jsonpath='{.status.nodeName}')
kubectl cordon "$SRC_NODE"
kubectl drain "$SRC_NODE" --ignore-daemonsets --delete-emptydir-data --force
kubectl uncordon "$SRC_NODE"
```
