# Every example evaluates to a complete system without failed assertions or
# warnings, and its generated configuration builds.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig systemProblems systemBuild;

  examples = {
    minimal = [../examples/minimal.nix];
    household-intercom = [../examples/household-intercom.nix];
    # written with the pbx layer
    small-office = [
      self.nixosModules.pbx
      ../examples/small-office.nix
    ];
    # the add-on, with the example it extends; phones are part of pbx
    household-intercom-ht801 = [
      self.nixosModules.pbx
      ../examples/household-intercom.nix
      ../examples/household-intercom-ht801.nix
    ];
  };

  # the examples take their secrets from sops-nix; nothing is decrypted here
  configs = lib.mapAttrs (_: modules: evalConfig ([(sopsSecrets {})] ++ modules)) examples;
in {
  inherit configs;

  # evaluation of the whole system, without building it
  problems = lib.concatLists (lib.mapAttrsToList systemProblems configs);

  # the configuration trees and the module check, built for real
  derivations = lib.mapAttrs (_: systemBuild) configs;
}
