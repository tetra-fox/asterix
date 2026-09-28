# Evaluate NixOS configurations using the module, without building them.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
in rec {
  evalConfig = modules:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules =
        [
          self.nixosModules.default
          {
            boot.isContainer = true;
            system.stateVersion = "26.05";
          }
        ]
        ++ modules;
    }).config;

  rendered = modules: (evalConfig modules).services.asterisk.renderedFiles;

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  placeholderFor = path: self.lib.secrets.placeholderOf (self.lib.secret path);

  # Does evaluating `value` (deeply) throw?
  throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
}
