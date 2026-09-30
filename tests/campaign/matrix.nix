# The VM tests of matrix-<rows>.json (matrix.py) for vmtest.py --expr: those
# on nixos-26.05 from the flake's nixpkgs, those on nixos-unstable from
# `unstable`'s, with the phones from the flake's either way. With `only`, a
# list of row ids, a test has just those rows and their pbxs, to run a failed
# row alone.
#
#   vmtest.py three-wise-1 OUT --expr '(import ./tests/campaign/matrix.nix { flake = ./.; }).three-wise-1'
{
  flake,
  rows ? "three-wise",
  unstable ? "github:NixOS/nixpkgs/nixos-unstable",
  only ? null,
}: let
  self = builtins.getFlake (toString flake);
  pin = self.inputs.nixpkgs.legacyPackages.x86_64-linux;
  nixpkgs = {
    "nixos-26.05" = pin;
    "nixos-unstable" = (builtins.getFlake unstable).legacyPackages.x86_64-linux;
  };
  inherit (pin) lib;

  keep = test: let
    kept = builtins.filter (row: only == null || builtins.elem row.id only) test.rows;
    used = map (row: row.pbx) kept;
  in
    test
    // {
      rows = kept;
      pbxs = builtins.filter (pbx: builtins.elem pbx.name used) test.pbxs;
    };
in
  lib.listToAttrs (map (test: let
    pkgs = nixpkgs.${test.nixpkgs};
  in
    lib.nameValuePair test.name (import ../vm/matrix.nix {
      inherit pkgs self;
      test = keep test;
      sopsSecrets = import ../sops.nix {
        inherit pkgs;
        inherit (self.inputs) sops-nix;
      };
      harnessPkgs = pin;
    }))
  (lib.importJSON ./matrix-${rows}.json).tests)
