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
    ipv6 = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "IPv6 address with prefix length.";
            };
            gateway = lib.mkOption {
              type = lib.types.str;
              description = "IPv6 gateway, reached on-link.";
            };
          };
        }
      );
      default = null;
      description = "Static IPv6 from the provider panel; null leaves the box IPv4-only.";
    };
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
      address = lib.optional (cfg.ipv6 != null) cfg.ipv6.address;
      routes = lib.optional (cfg.ipv6 != null) {
        Gateway = cfg.ipv6.gateway;
        GatewayOnLink = true;
      };
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
