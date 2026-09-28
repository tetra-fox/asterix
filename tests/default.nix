# All flake checks. VM tests are nixosTest derivations; the rest are cheap
# evaluation/build checks.
{
  pkgs,
  self,
  sops-nix,
}: let
  inherit (pkgs) lib;

  sopsSecrets = import ./sops.nix {inherit pkgs sops-nix;};

  # Build-time failure with a readable report instead of an evaluation error,
  # so `nix flake check` still evaluates every other check.
  reportFailures = name: failures:
    pkgs.runCommand name
    {
      report = lib.generators.toPretty {} failures;
      passAsFile = ["report"];
    }
    ''
      if [ "$(cat "$reportPath")" != "[ ]" ]; then
        echo "failed:" >&2
        cat "$reportPath" >&2
        exit 1
      fi
      touch $out
    '';

  examples = import ./examples.nix {inherit pkgs self sopsSecrets;};

  nixSources = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
  };
in {
  lib-unit = reportFailures "asterisk-lib-unit-tests" (
    import ./lib.nix {
      inherit lib;
      asteriskLib = self.lib;
    }
  );

  eval = reportFailures "asterisk-eval-tests" (import ./eval.nix {inherit pkgs self;});

  assertions = reportFailures "asterisk-assertion-tests" (
    import ./assertions.nix {inherit pkgs self;}
  );

  examples = reportFailures "asterisk-examples-eval" examples.problems;

  examples-config-minimal = examples.derivations.minimal;
  examples-config-household-intercom = examples.derivations.household-intercom;
  examples-config-small-office = examples.derivations.small-office;

  vm-core = import ./vm/core.nix {inherit pkgs self;};

  vm-reload = import ./vm/reload.nix {inherit pkgs self sopsSecrets;};

  vm-minimal = import ./vm/minimal.nix {inherit pkgs self sopsSecrets;};

  vm-household-intercom = import ./vm/household-intercom.nix {inherit pkgs self sopsSecrets;};

  vm-small-office = import ./vm/small-office.nix {inherit pkgs self sopsSecrets;};

  vm-tier2 = import ./vm/tier2.nix {inherit pkgs self;};

  vm-tls-realtime = import ./vm/tls-realtime.nix {inherit pkgs self;};

  # every option has a description and the reference builds
  docs = import ../docs {inherit pkgs self;};

  # the same formatter `nix fmt` runs
  formatting = pkgs.runCommand "asterisk-format-check" {} ''
    ${lib.getExe self.formatter.${pkgs.stdenv.hostPlatform.system}} --check ${nixSources}
    touch $out
  '';

  # no unused let bindings, function arguments or inherits
  deadnix = pkgs.runCommand "asterisk-deadnix-check" {nativeBuildInputs = [pkgs.deadnix];} ''
    deadnix --fail --no-lambda-pattern-names ${nixSources}
    touch $out
  '';
}
