{
  config,
  pkgs,
  unstable,
  ...
}:
let
  # The Caddyfile Jevil's FRP/Caddy/DNS lint reads. Validated at build time on a copy whose
  # log files point into the build sandbox, since /var/log/caddy does not exist there.
  caddyfileSource = ../../terraform/aws-edge/config/Caddyfile;
  caddyfile = pkgs.runCommand "edge-caddyfile" { nativeBuildInputs = [ pkgs.caddy ]; } ''
    export HOME=$TMPDIR XDG_DATA_HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR
    mkdir -p "$TMPDIR/log"
    sed "s#/var/log/caddy#$TMPDIR/log#g" ${caddyfileSource} > "$TMPDIR/Caddyfile"
    caddy validate --adapter caddyfile --config "$TMPDIR/Caddyfile"
    cp ${caddyfileSource} $out
  '';

  frpsSettings = config.services.frp.instances.frps.settings;
  frpsVerify =
    pkgs.runCommand "edge-frps-verify" { nativeBuildInputs = [ config.services.frp.package ]; }
      ''
        FRPS_AUTH_TOKEN=build-check FRPS_DASHBOARD_PASSWORD=build-check \
          frps verify -c ${(pkgs.formats.toml { }).generate "frps.toml" frpsSettings}
        touch $out
      '';
in
{
  services.caddy = {
    enable = true;
    configFile = caddyfile;
  };

  sops.secrets.frps_auth_token = { };
  sops.secrets.frps_dashboard_password = { };
  sops.templates."frps.env".content = ''
    FRPS_AUTH_TOKEN=${config.sops.placeholder.frps_auth_token}
    FRPS_DASHBOARD_PASSWORD=${config.sops.placeholder.frps_dashboard_password}
  '';

  # Same release as the in-cluster frpc (fatedier/frpc in apps/frp-client/deployment.yaml).
  services.frp.package = unstable.frp;

  services.frp.instances.frps = {
    enable = true;
    role = "server";
    environmentFiles = [ config.sops.templates."frps.env".path ];
    settings = {
      bindPort = 7000;
      # Caddy is the public entrypoint. Every proxy port, including the metrics receiver
      # (9091), is loopback-only; frpc's control traffic uses bindPort.
      proxyBindAddr = "127.0.0.1";
      auth = {
        method = "token";
        token = "{{ .Envs.FRPS_AUTH_TOKEN }}";
      };
      # Dashboard: ssh -L 7500:127.0.0.1:7500 root@<edge tailnet IP>
      webServer = {
        addr = "127.0.0.1";
        port = 7500;
        user = "admin";
        password = "{{ .Envs.FRPS_DASHBOARD_PASSWORD }}";
      };
      transport.tls.force = false;
    };
  };

  # STUN only, bound to eth0's IPv4. On the Lightsail box binding every interface (the
  # tailscale0 address included) coincided with two full network blackholes.
  systemd.services.coturn-stun = {
    description = "coturn STUN server for the Headscale DERP region";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.iproute2
      pkgs.gawk
    ];
    script = ''
      ip=$(ip -4 -o addr show dev eth0 scope global | awk '{ split($4, a, "/"); print a[1]; exit }')
      test -n "$ip"
      exec ${pkgs.coturn}/bin/turnserver -n --stun-only --no-tls --no-dtls --no-cli \
        --listening-ip="$ip" --listening-port=3478 --log-file=stdout --simple-log
    '';
    serviceConfig = {
      DynamicUser = true;
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Joins with the one-off preauth key scripts/edge-install.sh creates; tailscaled keeps its
  # node identity in /var/lib/tailscale afterwards.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/var/lib/edge/tailscale-authkey";
    extraUpFlags = [
      "--login-server=https://headscale.jackhumes.com"
      "--hostname=edge"
      "--accept-dns=false"
    ];
  };

  system.checks = [ frpsVerify ];
}
