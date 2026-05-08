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

## BGP mode — ECMP and replicas

When the cluster uses Cilium BGP mode, Traefik's `LoadBalancer` Service is configured with `externalTrafficPolicy: Local`. This means:

- Cilium only advertises the LB IP as a BGP `/32` host route from **nodes that have a running Traefik pod**.
- The upstream router (e.g. OPNsense/FRR) receives one route per pod-bearing node and, with ECMP enabled, distributes flows across them at the IP level.
- Traffic is guaranteed to arrive at a node that already has a local pod — no extra WireGuard inter-node hop for ingress traffic.

**To take advantage of this**, set `TRAEFIK_REPLICAS` to the number of control-plane BGP-peering nodes (the example configs derive this automatically from `${#TALOS_CONTROL_NODES[@]}`). The built-in `podAntiAffinity` and `nodeAffinity` ensure exactly one pod per control-plane node. With a single replica the LB IP is only advertised from one node and there is no ECMP benefit.

**Router ECMP prerequisite (OPNsense):** OPNsense uses FRR for BGP. ECMP is disabled by default — FRR installs only one best-path into the routing table. To enable it:

1. Go to **Routing → BGP → General** in the OPNsense UI.
2. Set **Maximum Paths** (eBGP multipath) to the number of Traefik replicas / BGP-peering nodes.
3. Save and apply. Verify with `show ip bgp <LB-IP>/32` in the FRR shell — each node's next-hop should appear with `*>`.

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
