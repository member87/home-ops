# Values that belong to this particular VPS, from the OVH panel.
{
  edge.disk = "/dev/sda";

  # OVH gives a VPS one static IPv6 address and gateway (no RA/DHCPv6). Fill both in from
  # the panel's IP tab to enable it, e.g.
  #   edge.ipv6 = { address = "2001:db8:1:2::abcd/128"; gateway = "2001:db8:1:2::1"; };
  edge.ipv6 = null;
}
