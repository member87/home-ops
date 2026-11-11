# The public edge: Caddy (TLS for the public hosts), frps (tunnel from the in-cluster frpc),
# coturn (STUN for Headscale's DERP region), a Tailscale client, and a Prometheus agent that
# remote-writes through the tunnel. Installed with `just edge-install`; afterwards comin
# pulls main and switches to nixosConfigurations.edge on its own.
{
  config,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./host.nix
    ./disk.nix
    ./network.nix
    ./services.nix
    ./monitoring.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  time.timeZone = "Europe/London";

  boot.initrd.availableKernelModules = [
    "ahci"
    "sd_mod"
    "sr_mod"
    "virtio_blk"
    "virtio_pci"
    "virtio_scsi"
    "xhci_pci"
  ];

  # Evaluating nixpkgs for a comin switch takes 1-2 GB on a 4 GB box.
  zramSwap.enable = true;

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # Pull-based GitOps, like Flux for the cluster: poll main and switch when it moves.
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        url = "https://github.com/member87/home-ops.git";
        branches.main.name = "main";
      }
    ];
    exporter = {
      listen_address = "127.0.0.1";
      port = 4243;
    };
  };

  # The host key is generated once, kept sops-encrypted in nixos/edge, and placed by
  # scripts/edge-install.sh, so the box's identity (and its age recipient in .sops.yaml)
  # survives a reinstall.
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];
    secrets.root_password_hash.neededForUsers = true;
  };

  users.mutableUsers = false;
  users.users.root = {
    # For the OVH KVM console when the tailnet is down; the password is root_password in
    # secrets.yaml (sops -d --extract '["root_password"]' nixos/edge/secrets.yaml).
    hashedPasswordFile = config.sops.secrets.root_password_hash.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3UXwi2ZmExP4hZLwcaRaryfSlUm9XTTwbMLv1pliEi"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKB5yZ34+4OSm/TIe0WEbvHRy8HR5QH22Im5K1UG4f84"
    ];
  };

  # SSH only over the tailnet (see network.nix); the OVH KVM console is the break-glass.
  services.openssh = {
    enable = true;
    openFirewall = false;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
}
