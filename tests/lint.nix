# Checks that read the source without running it. CI builds them in a job of
# their own (legacyPackages.ci in flake.nix).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  sources = extensions:
    lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.fileFilter (file: builtins.any file.hasExt extensions) ../.;
    };
  nixSources = sources ["nix"];
in {
  # the same formatter `nix fmt` runs
  formatting = self.formatter.${pkgs.stdenv.hostPlatform.system}.check (sources ["nix" "rs"]);

  # no unused let bindings, function arguments or inherits
  deadnix = pkgs.runCommand "asterisk-deadnix-check" {nativeBuildInputs = [pkgs.deadnix];} ''
    deadnix --fail ${nixSources}
    touch $out
  '';

  statix = pkgs.runCommand "asterisk-statix-check" {nativeBuildInputs = [pkgs.statix];} ''
    statix check --config ${../statix.toml} ${nixSources}
    touch $out
  '';

  # the server and its tests, with warnings as errors
  clippy = self.packages.${pkgs.stdenv.hostPlatform.system}.provisioning-server.overrideAttrs (old: {
    pname = "${old.pname}-clippy";
    nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.clippy];
    buildPhase = "cargo clippy --all-targets --offline -- -D warnings";
    doCheck = false;
    installPhase = "touch $out";
  });

  # the github workflows, and their run steps with shellcheck. actionlint reads
  # the local actions they use only inside a git repository
  actionlint = pkgs.runCommand "asterisk-actionlint-check" {nativeBuildInputs = [pkgs.actionlint pkgs.gitMinimal pkgs.shellcheck];} ''
    cp -r --no-preserve=mode ${sources ["yml"]} project
    cd project
    git init -q
    actionlint
    touch $out
  '';
}
