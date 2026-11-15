{ config, lib, ... }:
let
  cfg = config.edge;
in
{
  options.edge = {
    disk = lib.mkOption {
      type = lib.types.str;
      description = "Whole disk that nixos-anywhere partitions (disko). Wiped on install.";
    };
    ipv6 = lib.mkEnableOption ''
      the static IPv6 address and gateway from public_ipv6 and public_ipv6_gateway in
      secrets.yaml (the provider gives no RA/DHCPv6). They live in sops rather than here so
      this public repo does not publish the box's addresses
    '';
  };

  config = {
    networking.hostName = "edge";

    # eth0 on every VPS image, which the coturn unit binds to.
    networking.usePredictableInterfaceNames = false;
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks."10-wan" = {
      matchConfig.Name = "eth0";
      networkConfig.DHCP = "ipv4";
    };

    # A drop-in for 10-wan.network; networkd reads drop-ins from /run/systemd/network too.
    sops.secrets = lib.mkIf cfg.ipv6 {
      public_ipv6 = { };
      public_ipv6_gateway = { };
    };
    sops.templates."edge-ipv6.conf" = lib.mkIf cfg.ipv6 {
      path = "/run/systemd/network/10-wan.network.d/ipv6.conf";
      mode = "0444";
      restartUnits = [ "systemd-networkd.service" ];
      content = ''
        [Network]
        Address=${config.sops.placeholder.public_ipv6}

        [Route]
        Gateway=${config.sops.placeholder.public_ipv6_gateway}
        GatewayOnLink=true
      '';
    };

    # No egress shaping: the Lightsail box's 4mbit tbf guarded a 1 TB transfer allowance,
    # and OVH VPS traffic is unmetered.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        80 # Caddy: ACME HTTP-01 and the HTTPS redirect
        443 # Caddy: auth, headscale (control + DERP), terrakube-hook, gotify
        7000 # frps control channel for the in-cluster frpc (token-authenticated)
      ];
      allowedUDPPorts = [
        3478 # STUN for the Headscale DERP region
      ];
      # Tailscale's own UDP port is opened by services.tailscale.openFirewall.
      interfaces.tailscale0.allowedTCPPorts = [ 22 ];
    };
  };
}
