# BGP Cluster Template — Setup Guide

This directory contains a starting point for a **BGP mode** cluster (using eBGP to advertise LoadBalancer IPs to an external router).

## How to Use This Template

1. **Fork or copy** this entire directory as a new private git repository.
2. **Edit `yourCluster-bgp.env`** with your cluster details (domain, node hostnames, Pod/Service CIDRs, versions).
3. **Use the base Traefik configuration by default.** It already works for BGP with `externalTrafficPolicy: Cluster` and does not require any pod-placement constraints.
4. **Set `EXCLUDED_BASE`** in your `.env` to **exclude the L2 policy files** (you're using BGP):
   ```bash
   export EXCLUDED_BASE=(
     "cilium/ciliumL2AnnouncementPolicy.yaml"
     "external-dns/externalDnsTsigSecret.yaml"
   )
   ```
5. **Configure BGP variables** in your `.env`:
   ```bash
   export CILIUM_BGP_LOCAL_ASN="64513"
   export CILIUM_BGP_PEER_ASN="64512"
   export CILIUM_BGP_PEER_ADDRESS="192.168.1.1"  # Your router's IP
   export CILIUM_LB_IP_CIDR="203.0.113.0/24"      # Your public CIDR (routable)
   ```

## Key Design Points

### Traefik + externalTrafficPolicy: Cluster

For BGP mode, the default and recommended setting is still `externalTrafficPolicy: Cluster` if you do not want any affinity setup.

Traffic routing works like this:
- Cilium advertises the service VIP to the BGP peer.
- The router picks one advertising node for a given flow.
- That node receives the packet and Cilium selects any ready Traefik pod in the cluster.
- If the chosen pod is remote, Cilium forwards the packet across the cluster to that node.

This design is more robust than `Local` because ingress availability is no longer tied to having a Traefik pod on every BGP-speaking node.

### Optional ECMP optimization: Local + affinity

If you deliberately want router ECMP to land directly on Traefik-bearing nodes, you can opt into the override at [templates/yourCluster-bgp/traefik/traefikHelmValuesOverride-bgp.yaml](/workspaces/talos-bootstrapper-data/talos-bootstraper/templates/yourCluster-bgp/traefik/traefikHelmValuesOverride-bgp.yaml).

That override:
- switches Traefik to `externalTrafficPolicy: Local`
- pins pods to control-plane nodes
- spreads one pod per node with `podAntiAffinity`

Only use it if you accept the operational constraint that ingress behavior now depends on pod placement.

## Comparison: L2 vs BGP

| Aspect | L2 Mode (base) | BGP Mode (default template) |
|--------|---|---|
| LoadBalancer IP | On same subnet as nodes | Any routable CIDR |
| Announcement | ARP from one node | eBGP VIP advertisement from ingress nodes |
| Pod Placement | No constraints | No constraints |
| ETP Setting | `Cluster` | `Cluster` |
| Replicas | No constraint | No constraint |

## Migrating to L2 Mode

If you later decide to use L2 mode instead:
1. Delete any optional Traefik override files from your overlay directory.
2. Update `EXCLUDED_BASE` to exclude only `external-dns/externalDnsTsigSecret.yaml`.
3. Change `CILIUM_LB_IP_CIDR` to an IP range on your node subnet (e.g., `192.168.1.64/26`).
4. Remove BGP variables from your `.env`.
5. Remove any Traefik placement constraints you added for a `Local` optimization.

The base configuration uses `externalTrafficPolicy: Cluster` in both L2 and BGP modes unless you opt into the advanced BGP override.

## Further Reading

- [Talos Kubernetes Bootstrapper — L2 vs BGP LoadBalancer Modes](../../README.md#loadbalancer-mode-l2-vs-bgp)
- [Cilium L2 Announcements Docs](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [Cilium BGP Control Plane Docs](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
