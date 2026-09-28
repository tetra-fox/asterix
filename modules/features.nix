{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrs
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  fcfg = cfg.features;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;

  applicationType = types.submodule {
    options = {
      dtmf = mkOption {
        type = types.str;
        example = "*9";
        description = "Key sequence that triggers the feature.";
      };
      activateOn = mkOption {
        type = types.enum [
          "self"
          "peer"
        ];
        default = "self";
        description = "Whose key presses trigger the feature.";
      };
      app = mkOption {
        type = types.str;
        example = "Playback";
        description = "Dialplan application to run.";
      };
      args = mkOption {
        type = types.str;
        default = "";
        example = "tt-monkeys";
        description = "Arguments of the application.";
      };
    };
  };
in {
  options.services.asterisk.features = {
    general = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        transferdigittimeout = 3;
        featuredigittimeout = 1500;
      };
      description = "Keys of the `[general]` section.";
    };

    featureMap = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {
        blindxfer = "#1";
        atxfer = "*2";
        disconnect = "*0";
        automixmon = "*3";
      };
      description = ''
        Built-in features and their key sequences (`[featuremap]`). They are
        only available on calls dialled with the matching Dial() options
        (`t`/`T` for transfers, `x`/`X` for automixmon, ...).
      '';
    };

    applications = mkOption {
      type = types.attrsOf applicationType;
      default = {};
      example = {
        monkeys = {
          dtmf = "*9";
          activateOn = "peer";
          app = "Playback";
          args = "tt-monkeys";
        };
      };
      description = ''
        Custom features (`[applicationmap]`), enabled per call through the
        `DYNAMIC_FEATURES` channel variable.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.asterisk.settings."features.conf" =
      {
        general = mapAttrs (_: v:
          if builtins.isList v
          then v
          else mkDefault v)
        fcfg.general;
      }
      // lib.optionalAttrs (fcfg.featureMap != {}) {
        featuremap = mapAttrs (_: mkDefault) fcfg.featureMap;
      }
      // lib.optionalAttrs (fcfg.applications != {}) {
        applicationmap =
          mapAttrs (
            _: a:
              mkDefault (
                concatStringsSep "," [
                  a.dtmf
                  a.activateOn
                  a.app
                  a.args
                ]
              )
          )
          fcfg.applications;
      };
  };
}
