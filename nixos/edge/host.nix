# Values that belong to this particular VPS (OVH VPS, 51.75.161.134, 4 GB, legacy BIOS).
{
  edge.disk = "/dev/sda";

  # OVH gives a VPS one static IPv6 address and gateway (no RA/DHCPv6), from the panel's
  # IP tab.
  edge.ipv6 = {
    address = "2001:41d0:801:2000::1ad6/128";
    gateway = "2001:41d0:801:2000::1";
  };
}
