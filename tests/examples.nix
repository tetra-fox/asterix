# Every example evaluates to a complete system without failed assertions or
# warnings, and its generated configuration builds.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig failedAssertions;

  examples = {
    minimal = [../examples/minimal.nix];
    household-intercom = [../examples/household-intercom.nix];
    small-office = [../examples/small-office.nix];
    # the add-on, with the example it extends
    household-intercom-ht801 = [
      ../examples/household-intercom.nix
      ../examples/household-intercom-ht801.nix
    ];
  };

  # the examples take their secrets from sops-nix; nothing is decrypted here
  configs = lib.mapAttrs (_: modules: evalConfig ([(sopsSecrets {})] ++ modules)) examples;
in {
  # evaluation of the whole system, without building it
  problems = lib.concatLists (
    lib.mapAttrsToList (
      name: config: let
        failed = failedAssertions config;
        # forces evaluation of every unit, file and option of the system
        toplevel = builtins.unsafeDiscardStringContext config.system.build.toplevel.drvPath;
      in
        lib.optional (failed != [] || config.warnings != [] || toplevel == "") {
          ${name} = {
            inherit failed;
            inherit (config) warnings;
          };
        }
    )
    configs
  );

  # the configuration trees and the module check, built for real
  derivations =
    lib.mapAttrs (
      _: config:
        pkgs.linkFarm "asterisk-example" (
          [
            {
              name = "config";
              path = config.services.asterisk.generatedConfig;
            }
          ]
          ++ lib.imap0 (i: check: {
            name = "check-${toString i}";
            path = check;
          })
          config.system.checks
        )
    )
    configs;
}
