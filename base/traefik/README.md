# Traefik

## What it does

[Traefik](https://traefik.io/) is the cluster's ingress controller and reverse proxy. It terminates TLS for all externally-accessible services, routes HTTP/HTTPS traffic to backend `Service` objects, and handles middleware (authentication, redirects, rate limiting, etc.).

All external access to cluster services goes through Traefik. It is assigned a Cilium `LoadBalancer` IP from the cluster's IP pool.

## Why it was added

Traefik provides a single, consistent entry point for all HTTP/HTTPS traffic into the cluster. Its integration with cert-manager (via annotations) and external-dns makes it simple to expose services securely with automatic certificate management and DNS record creation.

## Dependencies

None — Traefik is a foundational infrastructure component. It has no dependencies on other components in this repository beyond Cilium (for its `LoadBalancer` IP) and cert-manager (for TLS certificates).

## Dependents

Every service exposed via an `IngressRoute` or `Ingress` object depends on Traefik being healthy, including:

- **argocd** — ArgoCD UI is exposed via Traefik
- **gitea** — Gitea web UI is exposed via Traefik
- **longhorn** — Longhorn dashboard is exposed via Traefik

## BGP mode — safe default vs optional optimization

For BGP-based clusters, the base Traefik configuration uses `externalTrafficPolicy: Cluster`.
This is the safer default when you do **not** want to guarantee one Traefik pod per BGP-speaking node.

With `Cluster` policy:

- Cilium advertises the LoadBalancer VIP through the BGP control plane from the eligible ingress nodes.
- The upstream router forwards a flow to one of those advertising nodes.
- The receiving node can send the traffic to **any** ready Traefik pod in the cluster, including a pod on another node.
- You do not need `nodeAffinity`, `podAntiAffinity`, or a one-pod-per-control-plane design.

Trade-offs of `Cluster` policy:

- Ingress traffic may take an extra in-cluster hop when the selected backend pod is on a different node.
- Source IP preservation semantics are weaker than with `Local`; if an application requires the original client IP at the pod, validate that explicitly.
- Router ECMP no longer maps 1:1 to Traefik pods; the node chosen by BGP and the pod chosen by Cilium are separate decisions.

If you explicitly want router-level ECMP to land only on nodes that already host Traefik pods, the repository ships an **optional** BGP override in [templates/yourCluster-bgp/traefik/traefikHelmValuesOverride-bgp.yaml](/workspaces/talos-bootstrapper-data/talos-bootstraper/templates/yourCluster-bgp/traefik/traefikHelmValuesOverride-bgp.yaml). That override switches to `externalTrafficPolicy: Local` and adds pod-placement constraints. Use it only if you are willing to couple ingress availability to pod placement.

## User Guide

### Exposing a new service

Add a Traefik `IngressRoute` (or standard Kubernetes `Ingress` with Traefik annotations). Always use HTTPS and a cert-manager annotation:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myservice
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myservice.example.com
    cert-manager.io/cluster-issuer: ${TALOS_CLUSTER_NAME}-ca-issuer
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myservice.example.com`)
      kind: Rule
      services:
        - name: myservice
          port: 8080
  tls:
    secretName: myservice-tls
```

### Checking Traefik logs

```bash
kubectl -n <traefik-namespace> logs -l app.kubernetes.io/name=traefik --tail=50
```

### Traefik dashboard

The Traefik dashboard is available internally and shows all routers, services, and middleware. It is not exposed externally by default. To access it temporarily:

```bash
kubectl -n <traefik-namespace> port-forward svc/traefik 9000:9000
# Then open http://localhost:9000/dashboard/
```
