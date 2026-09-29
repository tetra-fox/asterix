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

  # The cases that did not behave as expected. Each case evaluates `base` and
  # its `module`, and expects a substring in a failed assertion (`assertion`),
  # in a warning (`warning`), exactly these assertions or warnings
  # (`assertions`, `warnings`), or evaluation of the generated files to throw
  # (`throws`).
  checkCases = base: cases:
    lib.concatLists (lib.mapAttrsToList (name: case: let
      config = evalConfig [
        base
        case.module
      ];
      failed = failedAssertions config;
      inherit (config) warnings;
      has = needle: haystack: builtins.any (lib.hasInfix needle) haystack;
      problems =
        lib.optional (case ? assertion && !(has case.assertion failed)) {
          expectedAssertion = case.assertion;
          inherit failed;
        }
        ++ lib.optional (case ? assertions && failed != case.assertions) {
          expectedAssertions = case.assertions;
          inherit failed;
        }
        ++ lib.optional (case ? warning && !(has case.warning warnings)) {
          expectedWarning = case.warning;
          inherit warnings;
        }
        ++ lib.optional (case ? warnings && warnings != case.warnings) {
          expectedWarnings = case.warnings;
          inherit warnings;
        }
        ++ lib.optional (case.throws or false && !(throws config.services.asterisk.renderedFiles)) {
          expectedThrow = true;
        };
    in
      lib.optional (problems != []) {${name} = problems;})
    cases);
}
