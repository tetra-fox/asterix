# pbx.conferences: a ConfBridge room with a number, in pbx-conference-<name>
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatMapStringsSep
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  format = (import ../../lib {inherit lib;}).format;
  ccfg = config.services.asterisk.confbridge;

  conferenceType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "800";
        description = "Number phones dial to join the conference.";
      };
      bridgeProfile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Bridge profile of {option}`services.asterisk.confbridge.bridges`; Asterisk's `default_bridge` without it.";
      };
      userProfile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User profile of {option}`services.asterisk.confbridge.users`; Asterisk's `default_user` without it.";
      };
    };
  };

  # ConfBridge needs a conference name
  badNames = builtins.filter (name: name == "" || pbxLib.breaksContext name || pbxLib.breaksArgument name) (builtins.attrNames cfg.conferences);
  # ConfBridge refuses a name of 80 bytes or more (apps/app_confbridge.c
  # confbridge_exec)
  longNames = builtins.filter (name: builtins.stringLength name > 79) (builtins.attrNames cfg.conferences);

  # profiles Asterisk has without configuration
  missingProfiles = concatMap (
    name: let
      conference = cfg.conferences.${name};
    in
      optional (conference.bridgeProfile != null && !(builtins.elem conference.bridgeProfile (builtins.attrNames ccfg.bridges ++ ["default_bridge"]))) "pbx.conferences.${name}.bridgeProfile: ${conference.bridgeProfile}"
      ++ optional (conference.userProfile != null && !(builtins.elem conference.userProfile (builtins.attrNames ccfg.users ++ ["default_user"]))) "pbx.conferences.${name}.userProfile: ${conference.userProfile}"
  ) (builtins.attrNames cfg.conferences);
in {
  options.pbx.conferences = mkOption {
    type = types.attrsOf conferenceType;
    default = {};
    example = lib.literalExpression ''{ board = { number = "800"; }; }'';
    description = ''
      Conference rooms, keyed by room name. ConfBridge takes names of up to
      79 bytes.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts =
      mapAttrs' (
        name: conference:
          nameValuePair (pbxLib.objectContext "conference" name) {
            comment = mkDefault "from pbx.conferences.${name}";
            extensions.s = [
              (pbxLib.app "Answer" [])
              {
                app = "ConfBridge";
                args = [
                  (format.joinFields [
                    name
                    (
                      if conference.bridgeProfile == null
                      then ""
                      else conference.bridgeProfile
                    )
                    (
                      if conference.userProfile == null
                      then ""
                      else conference.userProfile
                    )
                  ])
                ];
              }
              (pbxLib.app "Hangup" [])
            ];
          }
      )
      cfg.conferences;

    assertions = [
      {
        assertion = badNames == [];
        message = ''
          pbx.conferences: names that Asterisk would misread in the dialplan (they may not be empty, or contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["pbx" "conferences" name]) badNames}
        '';
      }
      {
        assertion = longNames == [];
        message = "pbx.conferences: names longer than 79 bytes, which ConfBridge refuses: ${concatStringsSep ", " longNames}.";
      }
      {
        assertion = missingProfiles == [];
        message = ''
          pbx.conferences: profiles that are not defined:
            ${concatStringsSep "\n  " missingProfiles}
        '';
      }
    ];
  };
}
