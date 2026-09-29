# pbx.ivrs: a menu that plays a prompt and sends each key to a destination,
# in pbx-ivr-<name>. A prompt given as text is spoken by flite when the
# system is built.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatStringsSep
    filterAttrs
    genAttrs
    mapAttrs'
    mapAttrsToList
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optionalAttrs
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};

  ivrType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "700";
        description = "Number phones dial to reach the menu.";
      };
      prompt = mkOption {
        type = types.attrTag {
          sound = mkOption {
            type = types.str;
            example = "custom/main-menu";
            description = "Sound file, as Playback() names it: without extension, relative to the sounds directory.";
          };
          text = mkOption {
            type = types.str;
            example = "For sales, press 1. For support, press 2.";
            description = "Text spoken by flite (voice slt) when the system is built.";
          };
        };
        description = "What the caller hears before choosing.";
      };
      options = mkOption {
        type = types.attrsOf pbxLib.destination;
        default = {};
        example = lib.literalExpression ''{ "1" = { ringGroup = "sales"; }; "2" = { queue = "support"; }; }'';
        description = "Destination of each key: a digit, `*` or `#`.";
      };
      directDial = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let callers dial the numbers of {option}`pbx.extensions` from the
          menu. A key that starts an extension number counts on its own once
          no digit follows within 5 seconds.
        '';
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Seconds to wait for a key after the prompt.";
      };
      attempts = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "How often the prompt plays before `noInput` or `invalid` apply.";
      };
      noInput = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        description = "Where the call goes when no key was pressed after the last attempt.";
      };
      invalid = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        description = "Where the call goes when the last attempt got a key with no destination.";
      };
    };
  };

  soundFile = name: "pbx/ivr-${name}";

  spoken = filterAttrs (_: ivr: ivr.prompt ? text) cfg.ivrs;
  prompts = pkgs.runCommand "pbx-ivr-prompts" {nativeBuildInputs = [pkgs.flite];} ''
    mkdir -p $out/sounds/pbx
    ${concatStringsSep "\n" (mapAttrsToList (name: ivr: ''
        flite -voice slt -o $out/sounds/${soundFile name}.wav16 -t ${lib.escapeShellArg ivr.prompt.text}
      '')
      spoken)}
  '';

  ivrSection = name: ivr: let
    again = pbxLib.app "GotoIf" [''$[''${PBX_ATTEMPT} < ${toString ivr.attempts}]?s,prompt''];
  in {
    comment = mkDefault "from pbx.ivrs.${name}";
    extensions =
      {
        s = [
          (pbxLib.app "Answer" [])
          (pbxLib.app "Set" ["PBX_ATTEMPT=0"])
          {
            app = "Set";
            args = [''PBX_ATTEMPT=$[''${PBX_ATTEMPT} + 1]''];
            label = "prompt";
          }
          (pbxLib.app "Background" [
            (
              if ivr.prompt ? text
              then soundFile name
              else ivr.prompt.sound
            )
          ])
          (pbxLib.app "WaitExten" [ivr.timeout])
        ];
        t = [again] ++ pbxLib.steps ivr.noInput;
        i = [(pbxLib.app "Playback" ["pbx-invalid"]) again] ++ pbxLib.steps ivr.invalid;
      }
      // optionalAttrs ivr.directDial (genAttrs (builtins.attrNames cfg.extensions) (number: [
        (pbxLib.goto (pbxLib.objectContext "extension" number))
      ]))
      // lib.mapAttrs (_: pbxLib.steps) ivr.options;
  };

  badKeys = concatMap (name: map (key: "pbx.ivrs.${name}.options.${key}") (builtins.filter (key: builtins.match "[0-9*#]" key == null) (builtins.attrNames cfg.ivrs.${name}.options))) (builtins.attrNames cfg.ivrs);
  # a key that is also an extension number would be defined twice
  shadowed = concatMap (name: let
    ivr = cfg.ivrs.${name};
  in
    map (key: "pbx.ivrs.${name}.options.${key}") (
      builtins.filter (key: ivr.directDial && cfg.extensions ? ${key}) (builtins.attrNames ivr.options)
    )) (builtins.attrNames cfg.ivrs);
in {
  options.pbx.ivrs = mkOption {
    type = types.attrsOf ivrType;
    default = {};
    example = lib.literalExpression ''
      {
        main = {
          number = "700";
          prompt.text = "For sales, press 1. For support, press 2.";
          options = {
            "1".ringGroup = "sales";
            "2".queue = "support";
          };
        };
      }
    '';
    description = "Voice menus, keyed by menu name.";
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      dialplan.contexts = mapAttrs' (name: ivr: nameValuePair (pbxLib.objectContext "ivr" name) (ivrSection name ivr)) cfg.ivrs;
      sounds.packages = lib.optional (spoken != {}) prompts;
    };

    assertions = [
      {
        assertion = builtins.all (name: builtins.match "[A-Za-z0-9_-]+" name != null) (builtins.attrNames cfg.ivrs);
        message = "pbx.ivrs: menu names may only contain letters, digits, _ and -: ${concatStringsSep ", " (builtins.attrNames cfg.ivrs)}.";
      }
      {
        assertion = badKeys == [];
        message = "pbx.ivrs: keys must be one digit, * or #: ${concatStringsSep ", " badKeys}.";
      }
      {
        assertion = shadowed == [];
        message = "pbx.ivrs: these keys are also extension numbers, which directDial makes dialable: ${concatStringsSep ", " shadowed}.";
      }
    ];
  };
}
