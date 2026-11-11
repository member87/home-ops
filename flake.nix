{
  description = "home-ops NixOS hosts: the public edge (nixos/edge)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # frp only: frps follows the in-cluster frpc image (apps/frp-client), which tracks
    # upstream releases; stable nixpkgs lags several minors.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko/v1.13.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    comin = {
      url = "github:nlewo/comin/v0.14.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere/1.13.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      disko,
      sops-nix,
      comin,
      nixos-anywhere,
      ...
    }:
    {
      # comin on the box builds nixosConfigurations.<networking.hostName> from main.
      nixosConfigurations.edge = nixpkgs.lib.nixosSystem {
        specialArgs.unstable = nixpkgs-unstable.legacyPackages.x86_64-linux;
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          comin.nixosModules.comin
          ./nixos/edge
        ];
      };

      # Pinned by flake.lock, used by scripts/edge-install.sh.
      packages.x86_64-linux.nixos-anywhere = nixos-anywhere.packages.x86_64-linux.default;
    };
}
