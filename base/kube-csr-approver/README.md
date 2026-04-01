# kube-csr-approver

## What it does

Automatically approves kubelet serving certificate signing requests (CSRs) in the cluster.
When a Talos node starts or rotates its kubelet serving certificate, it submits a CSR to the Kubernetes API. Without an approver controller, these CSRs sit pending and features that depend on kubelet serving certs (e.g. `kubectl top node`, metrics-server, some monitoring integrations) will not work until an operator manually approves them.

This component runs the [postfinance/kubelet-csr-approver](https://github.com/postfinance/kubelet-csr-approver) controller, which watches for pending CSRs and automatically approves those that match the configured `providerRegex` and IP prefix rules.

## Why it was added

The cluster bootstrap scripts (`cluster-initialSetup.sh`) already call `approve_node_csrs` to approve the initial CSRs when nodes first join. However this only covers the initial bootstrap pass — any subsequent certificate rotations (triggered by node reboots, certificate expiry, or manual rotation) require a human to manually run `kubectl certificate approve`. The `kube-csr-approver` controller handles these ongoing approvals automatically.

## Dependencies

None beyond standard cluster infrastructure (Cilium, ArgoCD).

## Dependents

- **metrics-server** — relies on approved kubelet serving certs to scrape node metrics

## User Guide

### Configuration

The `CSR_APPROVER_PROVIDER_REGEX` overlay variable controls which node names are eligible for automatic approval. The regex is matched against the node name from the CSR username (`system:node:<nodename>`).

Examples:
- `.*` — approve all nodes (suitable for a fully controlled cluster)
- `^.*\.yourcluster\.example\.com$` — restrict to nodes in a specific domain

### Checking pending CSRs

```bash
kubectl get csr
```

### Checking controller logs

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kubelet-csr-approver
```
