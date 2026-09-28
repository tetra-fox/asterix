{
  description = "Declarative Asterisk PBX for NixOS: freeform settings for every config file, typed options for common subsystems, runtime-rendered secrets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # only used by the examples and their tests; the module works with any
    # secret manager that puts files on disk
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      lib = import ./lib { inherit lib; };

      nixosModules = {
        default = self.nixosModules.asterisk;
        asterisk = ./modules;
        # optional: provisioning for Grandstream phones
        grandstream-provisioning = ./modules/provisioning/grandstream.nix;
      };

      checks = forAllSystems (pkgs: import ./tests { inherit pkgs self sops-nix; });

      packages = forAllSystems (pkgs: {
        docs = import ./docs { inherit pkgs self; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
