{
  description = "Declarative Asterisk PBX for NixOS: freeform settings for every config file, typed options for common subsystems, runtime-rendered secrets";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
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

      checks = forAllSystems (pkgs: import ./tests { inherit pkgs self; });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
