# Architecture Docs

Diagrams describe a self-hosted home lab: a 3-node Kubernetes cluster at home,
a small cloud edge VM for public access, and a self-hosted VPN (tailnet)
linking remote devices.

## Naming legend (used everywhere)

| Generic name | Role |
|---|---|
| `example.com` | Public domain |
| `*.lab.example.com` | Internal-only service names |
| `Edge VM` | Small cloud VPS running TLS termination, tunnel server, STUN (~$5/mo) |
| `Cluster` | 3-node Kubernetes cluster at home (control-plane + workloads) |
| `Ingress VIP` | Load-balanced cluster ingress address |
| `VPN control` | Self-hosted VPN coordination server (in cluster) |
| `Subnet router` | Cluster node advertising home LAN ranges into the VPN |
| `Tunnel client/server` | Reverse-tunnel pair exposing cluster services without port-forwarding |
| `Media`, `Auth`, `Downloads`, `Dashboard` | Example workloads |
| `NAS` | Network storage for media |

## Address plan

| Range | Use |
|---|---|
| `192.168.10.0/24` | Home LAN (nodes, NAS, ingress VIP) |
| `192.168.20.0/24` | Secondary LAN (Wi-Fi clients) |
| `10.42.0.0/16` | Pod network |
| `100.64.0.0/10` | VPN (tailnet) address space (CGNAT range) |
| `203.0.113.10` | Edge VM public IP (RFC 5737 example) |

## Documents

| File | Contents |
|---|---|
| [network-topology.md](network-topology.md) | Global topology: internet, edge, home, clients |
| [gitops-flow.md](gitops-flow.md) | Declarative pipeline: Git → Flux, Terraform → edge |
| [public-access.md](public-access.md) | How public services are exposed (tunnel + TLS) |
| [tailnet-vpn.md](tailnet-vpn.md) | VPN control plane, STUN, direct vs relayed paths |
| [media-streaming.md](media-streaming.md) | Media streaming paths and bandwidth guardrails |

## Design principles

1. **Declarative everything**: cluster state comes from Git via Flux; the edge
   VM is built by Terraform from a launch script. No hand-built state.
2. **No inbound ports at home**: all public exposure rides an outbound-only
   tunnel to the edge VM.
3. **Direct-first VPN**: peers should talk to each other directly (STUN +
   endpoint discovery); the relay is only a bootstrap/fallback.
4. **Budget guardrails**: egress rate cap on the edge, included-transfer
   awareness, no workloads that transit the cloud unnecessarily.
