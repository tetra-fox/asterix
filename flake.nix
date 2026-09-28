{
  description = "Asterisk PBX for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # only used by the examples and their tests; the module works with any
    # secret manager that puts files on disk
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    sops-nix,
  }: let
    inherit (nixpkgs) lib;
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    lib = import ./lib {inherit lib;};

    nixosModules = {
      default = self.nixosModules.asterisk;
      asterisk = ./modules;
    };

    checks = forAllSystems (pkgs: import ./tests {inherit pkgs self sops-nix;});

    packages = forAllSystems (pkgs: {
      docs = import ./docs {inherit pkgs self;};
      provisioning-server = pkgs.callPackage ./pkgs/provisioning-server/package.nix {};
    });

    # the same toolchain that builds the package, plus the tools to work on it
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.provisioning-server];
        packages = [
          pkgs.clippy
          pkgs.rust-analyzer
          pkgs.rustfmt
        ];
        RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
      };
    });

    # `nix fmt` formats the whole tree; the `formatting` check runs the same config
    formatter = forAllSystems (pkgs:
      pkgs.treefmt.withConfig {
        runtimeInputs = [
          pkgs.alejandra
          pkgs.rustfmt
        ];
        settings = {
          tree-root-file = "flake.nix";
          on-unmatched = "info";
          formatter.alejandra = {
            command = "alejandra";
            includes = ["*.nix"];
          };
          formatter.rustfmt = {
            command = "rustfmt";
            options = ["--edition" "2024"];
            includes = ["*.rs"];
          };
        };
      });
  };
}
