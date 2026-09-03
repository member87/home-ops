# Network Topology

## Global view

```mermaid
flowchart LR
    subgraph INT["Internet"]
        RU["Remote users<br/>(phones, laptops)"]
    end

    subgraph EDGE["Cloud edge VM - 203.0.113.10"]
        CADDY["TLS termination<br/>(Caddy :443)"]
        FRPS["Tunnel server<br/>(frps :7000)"]
        STUN["STUN server<br/>(coturn :3478/udp)"]
    end

    subgraph HOME["Home network 192.168.10.0/24"]
        ROUTER["Home router"]

        subgraph CLUSTER["Kubernetes cluster (3 nodes)"]
            ING["Ingress VIP<br/>192.168.10.200"]
            FRPC["Tunnel client<br/>(frpc)"]
            VPN["VPN control plane<br/>(headscale)"]
            APPS["App workloads<br/>(media, auth, downloads...)"]
            TSROUTER["Subnet router<br/>(advertises LAN)"]
        end

        NAS["NAS<br/>(NFS media)"]
        DNSL["LAN DNS<br/>(Pi-hole)"]
    end

    subgraph CLIENTS["Home clients (192.168.20.0/24)"]
        TV["TV / media player"]
        WS["Workstations"]
    end

    RU -->|"HTTPS"| CADDY
    RU -.->|"WireGuard direct (preferred)"| TSROUTER
    RU -.->|"WireGuard relay (fallback)"| CADDY

    CADDY --> FRPS
    FRPS <-.->|"persistent outbound tunnel"| FRPC
    FRPC --> ING
    FRPC -.->|"VPN control + relay"| VPN

    TV -->|"LAN only"| ING
    WS --> DNSL
    TSROUTER -.->|"SNAT"| DNSL
    APPS -->|"NFS media"| NAS
    ROUTER --- CLUSTER
```

## Traffic classes

| Class | Path | Touches edge VM? |
|---|---|---|
| Public web (auth, dashboard) | Internet → edge Caddy → tunnel → ingress → app | Yes (small) |
| VPN control + endpoint discovery | Client → edge (HTTPS + STUN) → VPN control | Yes (tiny) |
| VPN **direct** peer stream | Client ↔ peer (WireGuard, internet or LAN) | **No** |
| VPN **relayed** stream (fallback) | Client → edge relay → tunnel → peer | Yes (large — this is the guarded path) |
| Home LAN media (TV) | TV → ingress → media pod → NAS | **No** |

## DNS

```mermaid
flowchart TD
    C["Client DNS"] -->|"public zones"| PUB["Managed DNS"]
    C -->|"*.lab.example.com"| PH["Pi-hole 192.168.10.201"]
    C -.->|"via VPN"| TSD["Pi-hole tailnet front (DNAT node)"]
    PH -->|"public names"| UP["Upstream resolver"]
```

- Public service names resolve to the **edge VM IP**.
- Internal `*.lab.example.com` names resolve to the **ingress VIP**, served by
  Pi-hole so both LAN and VPN clients get the same answers.
