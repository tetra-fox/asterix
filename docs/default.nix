# Options reference: `nix build .#docs` produces options.md, options.html and
# options.json for services.asterix, then the core under it, services.asterisk.
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

  asterix = optionsDoc {inherit (eval.options.services) asterix;};
  core = optionsDoc {inherit (eval.options.services) asterisk;};
in
  pkgs.runCommand "asterix-docs" {
    nativeBuildInputs = [
      pkgs.cmark
      pkgs.jq
    ];
  } ''
    mkdir -p $out
    {
      echo '# services.asterix'
      echo
      cat ${asterix.optionsCommonMark}
      echo
      echo '# services.asterisk'
      echo
      echo 'The core that services.asterix writes into, for what the options above do not cover.'
      echo
      cat ${core.optionsCommonMark}
    } > $out/options.md
    jq -s add ${asterix.optionsJSON}/share/doc/nixos/options.json ${core.optionsJSON}/share/doc/nixos/options.json > $out/options.json
    {
      echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>asterix options</title></head><body>'
      cmark --unsafe $out/options.md
      echo '</body></html>'
    } > $out/options.html
  ''
