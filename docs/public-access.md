# Public Access (Tunnel + TLS)

Public services are exposed **without any inbound ports at home**. A client in
the cluster keeps a persistent outbound connection to the edge VM; public
traffic rides that tunnel.

## Request path

```mermaid
sequenceDiagram
    autonumber
    participant U as Internet user
    participant DNS as Managed DNS
    participant C as Edge: Caddy :443
    participant F as Edge: frps
    participant FC as Cluster: frpc
    participant T as Traefik ingress
    participant A as App pod

    U->>DNS: resolve app.example.com
    DNS-->>U: 203.0.113.10 (edge VM)
    U->>C: TLS handshake + HTTP request
    Note over C: SNI-based host routing,<br/>auto Let's Encrypt certs
    C->>F: connect localhost:808x
    F->>FC: stream over established tunnel
    FC->>T: forward (host-routed IngressRoute)
    T->>A: route to service
    A-->>U: response (reverse path)
```

## Proxies

| Public name | Edge port | Backend |
|---|---|---|
| `auth.example.com` | 8081 (via Caddy) | Traefik :80 → auth app |
| `vpn.example.com` | 8082 (via Caddy) | VPN control plane :8080 (direct, not via Traefik) |
| `tracker.example.com` | 8083 (via Caddy) | Traefik :80 → tracker app |

## Key properties

```mermaid
flowchart TD
    A["frpc keeps ONLY outbound<br/>connections to edge :7000"] --> B["No router port-forwarding"]
    B --> C["Home IP stays hidden for public apps"]
    C --> D["Token auth between frpc and frps"]
    D --> E["CrowdSec-protected apps stay behind Traefik"]
```

- frpc targets the ingress (Traefik) for most apps so bot-protection
  middleware still applies; the VPN control plane is forwarded directly.
- TLS certificates are issued on the edge by Caddy (HTTP-01 via ports 80/443).
- Only one frpc instance may claim a proxy name at a time; restarting two
  clients concurrently causes a benign "proxy already exists" race that
  resolves on frp's retry cycle.
