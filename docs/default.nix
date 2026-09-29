# Options reference: `nix build .#docs` produces options.md, options.html and
# options.json for services.asterisk and, in a section of its own, pbx.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  eval = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      self.nixosModules.pbx
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
      }
    ];
  };

  # link declarations to the repository instead of the store
  repository = "https://github.com/tetra-fox/asterix/blob/main";
  prefix = toString self;

  optionsDoc = options:
    pkgs.nixosOptionsDoc {
      inherit options;
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

  core = optionsDoc {inherit (eval.options.services) asterisk;};
  pbx = optionsDoc {inherit (eval.options) pbx;};
in
  pkgs.runCommand "asterix-docs" {
    nativeBuildInputs = [
      pkgs.cmark
      pkgs.jq
    ];
  } ''
    mkdir -p $out
    {
      echo '# services.asterisk'
      echo
      cat ${core.optionsCommonMark}
      echo
      echo '# pbx'
      echo
      echo 'The PBX layer of `nixosModules.pbx`, written into the options above.'
      echo
      cat ${pbx.optionsCommonMark}
    } > $out/options.md
    jq -s add ${core.optionsJSON}/share/doc/nixos/options.json ${pbx.optionsJSON}/share/doc/nixos/options.json > $out/options.json
    {
      echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>asterix options</title></head><body>'
      cmark --unsafe $out/options.md
      echo '</body></html>'
    } > $out/options.html
  ''
