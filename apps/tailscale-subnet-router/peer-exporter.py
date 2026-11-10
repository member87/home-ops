"""Prometheus exporter for how this tailnet node reaches each peer it is talking to.

Reads tailscaled's LocalAPI status over the shared unix socket on every scrape and
exports one series per active peer with the path in use: direct (WireGuard peer to
peer), derp (relayed through Headscale's embedded DERP on the AWS edge) or peer_relay.
A peer stuck on derp sends every byte through the edge and its 4mbit egress cap.

It also exports each peer's WireGuard byte counters, without the path label so a path
change does not split the counter, which tells a relayed peer that is actually moving
data apart from one that only woke up briefly over the relay.
"""

import http.client
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOCKET = os.environ.get("TAILSCALED_SOCKET", "/tmp/tailscaled.sock")
PORT = int(os.environ.get("PORT", "9186"))


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=5):
        # tailscaled rejects LocalAPI requests whose Host is not local-tailscaled.sock.
        super().__init__("local-tailscaled.sock", timeout=timeout)
        self.socket_path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def status():
    conn = UnixHTTPConnection(SOCKET)
    try:
        conn.request("GET", "/localapi/v0/status")
        resp = conn.getresponse()
        body = resp.read()
        if resp.status != 200:
            raise RuntimeError(f"LocalAPI status returned {resp.status}")
        return json.loads(body)
    finally:
        conn.close()


def label(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def path_of(peer):
    if peer.get("CurAddr"):
        return "direct"
    if peer.get("PeerRelay"):
        return "peer_relay"
    return "derp"


def render(st):
    observer = st.get("Self", {}).get("HostName", "")
    users = st.get("User") or {}
    active = []
    traffic = []
    for peer in (st.get("Peer") or {}).values():
        # Headscale makes DNS names unique; HostName is often just "localhost" on iOS.
        name = (peer.get("DNSName") or "").split(".")[0] or peer.get("HostName", "")
        user = users.get(str(peer.get("UserID")), {})
        base = (
            ("observer", observer),
            ("peer", name),
            ("user", (user.get("DisplayName") or user.get("LoginName") or "").strip()),
            ("os", peer.get("OS", "")),
        )
        labels = ",".join(f'{key}="{label(value)}"' for key, value in base)
        if peer.get("Active"):
            active.append(f'tailscale_peer_active{{{labels},path="{path_of(peer)}"}} 1')
        # Counters reset when tailscaled restarts or the peer gets a new node key; rate()
        # handles both.
        if peer.get("RxBytes") or peer.get("TxBytes"):
            traffic.append((labels, int(peer.get("RxBytes") or 0), int(peer.get("TxBytes") or 0)))
    lines = [
        "# HELP tailscale_peer_active A peer this node exchanged traffic with recently "
        "(tailscaled's Active flag), by path: direct, derp or peer_relay.",
        "# TYPE tailscale_peer_active gauge",
        *active,
        "# HELP tailscale_peer_rx_bytes_total WireGuard bytes received from the peer.",
        "# TYPE tailscale_peer_rx_bytes_total counter",
        *(f"tailscale_peer_rx_bytes_total{{{labels}}} {rx}" for labels, rx, _ in traffic),
        "# HELP tailscale_peer_tx_bytes_total WireGuard bytes sent to the peer.",
        "# TYPE tailscale_peer_tx_bytes_total counter",
        *(f"tailscale_peer_tx_bytes_total{{{labels}}} {tx}" for labels, _, tx in traffic),
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            try:
                payload = render(status()).encode()
            except (OSError, ValueError, RuntimeError, http.client.HTTPException) as err:
                # A failed scrape shows up as up == 0 instead of an empty peer list.
                print(f"[peer-exporter] status failed: {err}", flush=True)
                self.send_error(503)
                return
            ctype = "text/plain; version=0.0.4; charset=utf-8"
        elif self.path == "/healthz":
            payload, ctype = b"ok\n", "text/plain"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"[peer-exporter] serving :{PORT}, tailscaled socket {SOCKET}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
