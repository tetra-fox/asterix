# All flake checks. VM tests are nixosTest derivations; the rest are cheap
# evaluation/build checks.
{ pkgs, self }:
let
  inherit (pkgs) lib;

  # Build-time failure with a readable report instead of an evaluation error,
  # so `nix flake check` still evaluates every other check.
  reportFailures =
    name: failures:
    pkgs.runCommand name
      {
        report = lib.generators.toPretty { } failures;
        passAsFile = [ "report" ];
      }
      ''
        if [ "$(cat "$reportPath")" != "[ ]" ]; then
          echo "failed:" >&2
          cat "$reportPath" >&2
          exit 1
        fi
        touch $out
      '';

  nixSources = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
  };
in
{
  lib-unit = reportFailures "asterisk-lib-unit-tests" (
    import ./lib.nix {
      inherit lib;
      asteriskLib = self.lib;
    }
  );

  eval = reportFailures "asterisk-eval-tests" (import ./eval.nix { inherit pkgs self; });

  assertions = reportFailures "asterisk-assertion-tests" (
    import ./assertions.nix { inherit pkgs self; }
  );

  vm-core = import ./vm/core.nix { inherit pkgs self; };

  formatting = pkgs.runCommand "asterisk-nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
    cd ${nixSources}
    find . -name '*.nix' -print0 | xargs -0 nixfmt --check
    touch $out
  '';
}
