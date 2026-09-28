# Options reference: `nix build .#docs` produces options.md, options.html and
# options.json for services.asterisk.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  eval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      self.nixosModules.default
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
      }
    ];
  };

  # link declarations to the repository instead of the store
  repository = "https://github.com/tetra-fox/asterix/blob/main";
  prefix = toString self;

  optionsDoc = pkgs.nixosOptionsDoc {
    options = {
      inherit (eval.options.services) asterisk;
    };
    transformOptions = option:
      option
      // {
        declarations =
          map (
            declaration: let
              path = lib.removePrefix "${prefix}/" (toString declaration);
            in {
              url = "${repository}/${path}";
              name = path;
            }
          )
          option.declarations;
      };
  };
in
  pkgs.runCommand "asterix-docs" {nativeBuildInputs = [pkgs.cmark];} ''
    mkdir -p $out
    cp ${optionsDoc.optionsCommonMark} $out/options.md
    cp ${optionsDoc.optionsJSON}/share/doc/nixos/options.json $out/options.json
    {
      echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>asterix options</title></head><body>'
      cmark --unsafe $out/options.md
      echo '</body></html>'
    } > $out/options.html
  ''
