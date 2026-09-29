{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
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
  inherit (import ./lib.nix {inherit lib;}) toSection;

  # modules that implement built-in features (the transfers are in the core);
  # without res_parking Asterisk drops a call dialled with k or K when answered
  featureModules = {
    parkcall = ["res_parking.so"];
    disconnect = ["bridge_builtin_features.so"];
    automixmon = [
      "bridge_builtin_features.so"
      "app_mixmonitor.so"
    ];
  };
  usedFeatures = lib.filterAttrs (key: _: (fcfg.featureMap.${key} or "") != "") featureModules;
  parksCalls = usedFeatures ? parkcall;

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
        description = ''
          Where the application runs: on the side that pressed the keys
          (`self`) or on the other side of the call (`peer`). Whose key
          presses trigger the feature is up to `DYNAMIC_FEATURES`.
        '';
      };
      app = mkOption {
        type = types.str;
        example = "Playback";
        description = "Dialplan application to run.";
      };
      args = mkOption {
        type = types.str;
        default = "";
        example = "tt-monkeys,skip";
        description = "Arguments of the application, separated by commas as in the dialplan.";
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
        (`t`/`T` for transfers, `k`/`K` for parkcall, `x`/`X` for automixmon,
        ...). The modules that provide them are loaded: res_parking.so for
        `parkcall`, bridge_builtin_features.so for `disconnect` and
        `automixmon`, which also needs app_mixmonitor.so.
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
        Custom features (`[applicationmap]`). A channel's key presses trigger
        the features its `DYNAMIC_FEATURES` variable names, separated by `#`.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.asterisk.modules.needed = lib.mapAttrs' (key: lib.nameValuePair "services.asterisk.features.featureMap.${key}") usedFeatures;
    # res_parking declines to load without its file
    services.asterisk.settings."res_parking.conf" = mkIf parksCalls {};

    services.asterisk.settings."features.conf" =
      {
        general = toSection fcfg.general;
      }
      // lib.optionalAttrs (fcfg.featureMap != {}) {
        featuremap = toSection fcfg.featureMap;
      }
      // lib.optionalAttrs (fcfg.applications != {}) {
        # arguments in parentheses: otherwise Asterisk takes only the next field as
        # the argument, and the one after it as a music class (applicationmap_handler)
        applicationmap =
          mapAttrs (_: a: mkDefault "${a.dtmf},${a.activateOn},${a.app}(${a.args})") fcfg.applications;
      };
  };
}
