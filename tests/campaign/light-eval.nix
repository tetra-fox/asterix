# Evaluates asterix modules without the rest of NixOS, for the campaign's
# many evaluations. Only the NixOS options the modules read or write are
# declared, with the types NixOS gives them, so assertions, warnings, the
# rendered files and the checks come out as in a whole system. options.py
# compares it with a whole NixOS evaluation on a sample.
{pkgs}: let
  inherit (pkgs) lib;
  nixos = "${pkgs.path}/nixos/modules";

  stubs = {
    config,
    lib,
    ...
  }: let
    inherit (lib) mkOption types;
    utils = import "${pkgs.path}/nixos/lib/utils.nix" {inherit lib config pkgs;};
    # networking.firewall and networking.firewall.interfaces.<name>
    firewallOptions = {
      allowedTCPPorts = mkOption {
        type = types.listOf types.port;
        default = [];
      };
      allowedUDPPorts = mkOption {
        type = types.listOf types.port;
        default = [];
      };
      allowedTCPPortRanges = mkOption {
        type = types.listOf (types.attrsOf types.port);
        default = [];
      };
      allowedUDPPortRanges = mkOption {
        type = types.listOf (types.attrsOf types.port);
        default = [];
      };
    };
  in {
    imports = [
      "${nixos}/misc/assertions.nix"
      "${nixos}/misc/ids.nix"
      "${nixos}/misc/lib.nix"
      "${nixos}/security/ca.nix"
    ];

    options = {
      system.checks = mkOption {
        type = types.listOf types.package;
        default = [];
      };
      systemd = {
        package = mkOption {
          type = types.package;
          default = pkgs.systemd;
        };
        services = mkOption {
          type = utils.systemdUtils.types.services;
          default = {};
        };
        sockets = mkOption {
          type = utils.systemdUtils.types.sockets;
          default = {};
        };
      };
      users = {
        users = mkOption {
          type = types.attrsOf (types.attrsOf types.anything);
          default = {};
        };
        groups = mkOption {
          type = types.attrsOf (types.attrsOf types.anything);
          default = {};
        };
      };
      networking.firewall =
        firewallOptions
        // {
          interfaces = mkOption {
            type = types.attrsOf (types.submodule {options = firewallOptions;});
            default = {};
          };
        };
      environment = {
        etc = mkOption {
          type = types.attrsOf (types.attrsOf types.anything);
          default = {};
        };
        systemPackages = mkOption {
          type = types.listOf types.package;
          default = [];
        };
      };
    };

    config._module.args = {
      inherit pkgs utils;
    };
  };
in
  # like lib.nixosSystem: `modules` on top of asterix's `module`
  # (nixosModules.default or nixosModules.pbx), with `config` and `options`
  module: modules:
    lib.evalModules {
      specialArgs.modulesPath = nixos;
      modules = [stubs module] ++ modules;
    }
