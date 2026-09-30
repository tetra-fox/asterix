# Every check with each Asterisk package of nixpkgs: pkgs gets that package as
# asterisk, which the checks' configurations (eval-lib.nix) and the VM tests'
# nodes use.
{
  pkgs,
  self,
  sops-nix,
}:
pkgs.lib.genAttrs ["asterisk_20" "asterisk_22" "asterisk_23"] (package:
    import ./. {
      pkgs = pkgs.extend (_: prev: {asterisk = prev.${package};});
      inherit self sops-nix;
    })
