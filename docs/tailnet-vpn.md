# Tailnet VPN

Self-hosted VPN coordination (headscale-compatible control plane) runs in the
cluster. Devices join from anywhere and should talk to each other **directly**;
the relay is only a bootstrap and fallback.

## Components

```mermaid
flowchart TD
    subgraph CLUSTER["Cluster"]
        HC["VPN control plane<br/>(coordination + netmap)"]
        DERP["Embedded relay<br/>(advertised region)"]
        SR["Subnet router<br/>advertises 192.168.10.0/24, 192.168.20.0/24<br/>SNAT for VPN -> LAN"]
        EXIT["Exit nodes<br/>(optional egress presets)"]
    end

    subgraph EDGE["Edge VM"]
        STUN["STUN server :3478/udp<br/>(coturn, host network)"]
        PUB["Public HTTPS<br/>(control plane via Caddy)"]
    end

    C1["Client: phone (mobile)"]
    C2["Client: TV (LAN)"]
    C3["Client: laptop"]

    C1 & C2 & C3 -->|"netmap sync"| PUB --> HC
    C1 & C3 -->|"STUN :3478"| STUN
    HC --- DERP
    C1 -.->|"fallback relay"| DERP
    C1 -->|"direct WireGuard"| SR
    SR -->|"SNAT"| APPS["Home apps (LAN)"]
    C1 -.->|"exit node"| EXIT
```

## Why STUN runs on the edge VM

STUN must answer with the client's IP **as the internet sees it**.

```mermaid
flowchart LR
    WRONG["STUN behind the tunnel<br/>(in-cluster)"] -->|"sees tunnel-internal<br/>source IP"| BAD["Reports pod IP<br/>= useless endpoint"]
    RIGHT["STUN on edge VM<br/>(host network)"] -->|"sees real<br/>client IP"| GOOD["Reports real public<br/>endpoint = direct works"]
```

- A STUN server placed behind the tunnel reports the tunnel client's internal
  pod address as the caller's public endpoint; peers then try to connect to an
  unroutable address and stay on the relay.
- The relay socket inside the VPN control pod is also known-bad in this
  version (binds but never answers); it keeps port 3478 bound, so the working
  STUN server lives on the edge where nothing competes for the port.

## How a direct path forms

```mermaid
sequenceDiagram
    autonumber
    participant A as Client A (remote)
    participant HC as VPN control
    participant S as STUN (edge)
    participant B as Client B (home)

    A->>HC: register + fetch netmap
    HC-->>A: peer list + DERP region + STUN address
    A->>S: STUN binding request
    S-->>A: your public endpoint is ip:port
    B->>S: STUN binding request
    S-->>B: your public endpoint is ip:port
    A->>B: discovery ping to B's endpoints
    B->>A: discovery reply
    Note over A,B: WireGuard session is now DIRECT<br/>(peer-to-peer, not via edge)
    Note over A,B: relay remains as fallback only
```

## Health checks that matter

| Symptom | Meaning |
|---|---|
| `UDP: true` + public IPv4 in netcheck | Endpoint discovery works |
| `pong ... via <peer-ip>:port` | **Direct** path (desired) |
| `pong ... via DERP(relay)` | Relaying — every byte bills against edge transfer |
| Peer advertises no endpoints | Broken/limited client app; fix or update it |

## Guardrails

- Edge egress is capped (4 mbit) so a relayed/broken client cannot exhaust the
  data-transfer allowance.
- Devices that refuse direct paths should stay off the VPN or be updated;
  on-LAN devices do not need the VPN at home at all.
