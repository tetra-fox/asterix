# services.asterix.ivrs: a menu that plays a prompt and sends each key to a
# destination, in pbx-ivr-<name>, which includes pbx-directdial with
# directDial. A prompt given as text is spoken by flite when the system is
# built.
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
    genAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    types
    ;

  cfg = config.services.asterix;
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
        type = pbxLib.prompt;
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
          Whether to let callers dial the numbers of
          {option}`services.asterix.extensions` from the menu. A key that
          starts an extension number counts on its own once no digit follows
          within 5 seconds. A key of `options` that is an extension number
          fails evaluation.
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

  ivrSection = name: ivr: let
    again = pbxLib.app "GotoIf" [''$[''${PBX_ATTEMPT} < ${toString ivr.attempts}]?s,prompt''];
  in {
    comment = mkDefault "from services.asterix.ivrs.${name}";
    # searched after the menu's own keys
    includes = optional ivr.directDial "pbx-directdial";
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
          (pbxLib.app "Background" [(pbxLib.promptSound "ivr" name ivr.prompt)])
          (pbxLib.app "WaitExten" [ivr.timeout])
        ];
        t = [again] ++ pbxLib.steps ivr.noInput;
        i = [(pbxLib.app "Playback" ["pbx-invalid"]) again] ++ pbxLib.steps ivr.invalid;
      }
      // lib.mapAttrs (_: pbxLib.steps) ivr.options;
  };

  directDial = builtins.any (ivr: ivr.directDial) (builtins.attrValues cfg.ivrs);

  badKeys = concatMap (name: map (key: "services.asterix.ivrs.${name}.options.${key}") (builtins.filter (key: builtins.match "[0-9*#]" key == null) (builtins.attrNames cfg.ivrs.${name}.options))) (builtins.attrNames cfg.ivrs);
  # a key that is also an extension number would hide that number from
  # directDial, as the menu's own keys come before its includes
  shadowed = concatMap (name: let
    ivr = cfg.ivrs.${name};
  in
    map (key: "services.asterix.ivrs.${name}.options.${key}") (
      builtins.filter (key: ivr.directDial && cfg.extensions ? ${key}) (builtins.attrNames ivr.options)
    )) (builtins.attrNames cfg.ivrs);
in {
  options.services.asterix.ivrs = mkOption {
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
    description = "Voice menus, keyed by menu name: letters, digits, `_` and `-`.";
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      dialplan.contexts =
        mapAttrs' (name: ivr: nameValuePair (pbxLib.objectContext "ivr" name) (ivrSection name ivr)) cfg.ivrs
        # one context every menu with directDial includes, so the dialplan
        # grows with the menus plus the extensions, not with their product
        // optionalAttrs directDial {
          pbx-directdial = {
            comment = mkDefault "from services.asterix.ivrs: the extensions a menu with directDial lets callers dial";
            extensions = genAttrs (builtins.attrNames cfg.extensions) (number: [
              (pbxLib.goto (pbxLib.objectContext "extension" number))
            ]);
          };
        };
      sounds.packages = pbxLib.promptSounds pkgs "ivr" cfg.ivrs;
    };

    assertions =
      pbxLib.promptAssertions "ivrs" cfg.ivrs
      ++ [
        {
          assertion = badKeys == [];
          message = "services.asterix.ivrs: keys must be one digit, * or #: ${concatStringsSep ", " badKeys}.";
        }
        {
          assertion = shadowed == [];
          message = "services.asterix.ivrs: these keys are also extension numbers, which directDial makes dialable: ${concatStringsSep ", " shadowed}.";
        }
      ];
  };
}
