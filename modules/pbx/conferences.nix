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
  core = config.services.asterisk;

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
        description = "Bridge profile of {file}`confbridge.conf`, from {option}`services.asterisk.confbridge.bridges` or `settings`; Asterisk's `default_bridge` without it.";
      };
      userProfile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User profile of {file}`confbridge.conf`, from {option}`services.asterisk.confbridge.users` or `settings`; Asterisk's `default_user` without it.";
      };
    };
  };

  # ConfBridge needs a conference name
  badNames = builtins.filter (name: name == "" || pbxLib.breaksContext name || pbxLib.breaksArgument name) (builtins.attrNames cfg.conferences);
  # ConfBridge refuses a name of 80 bytes or more (apps/app_confbridge.c
  # confbridge_exec), and finds a conference by its name in any case
  # (conference_bridge_cmp_cb)
  longNames = builtins.filter (name: builtins.stringLength name > 79) (builtins.attrNames cfg.conferences);
  alike = builtins.filter (names: builtins.length names > 1) (builtins.attrValues (builtins.groupBy lib.toLower (builtins.attrNames cfg.conferences)));

  # the profiles of a type in the final confbridge.conf, with the default one
  # Asterisk adds, in lower case as ConfBridge finds a profile in any case
  # (conf_config_parser.c bridge_cmp_cb); null when included files or raw
  # text can define more
  profiles = type:
    if core.includes."confbridge.conf" or [] != [] || core.extraConfig."confbridge.conf" or "" != ""
    then null
    else
      map (section: lib.toLower section.name) (builtins.filter (section: section.type or null == type) (format.resolveInheritance (core.settings."confbridge.conf" or {})).sections)
      ++ ["default_${type}"];
  bridges = profiles "bridge";
  users = profiles "user";
  undefined = known: profile: profile != null && known != null && !(builtins.elem (lib.toLower profile) known);
  missingProfiles = concatMap (
    name: let
      conference = cfg.conferences.${name};
    in
      optional (undefined bridges conference.bridgeProfile) "pbx.conferences.${name}.bridgeProfile: ${conference.bridgeProfile}"
      ++ optional (undefined users conference.userProfile) "pbx.conferences.${name}.userProfile: ${conference.userProfile}"
  ) (builtins.attrNames cfg.conferences);
in {
  options.pbx.conferences = mkOption {
    type = types.attrsOf conferenceType;
    default = {};
    example = lib.literalExpression ''{ board = { number = "800"; }; }'';
    description = ''
      Conference rooms, keyed by room name. ConfBridge takes names of up to
      79 bytes and tells them apart without regard to case.
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
        assertion = alike == [];
        message = "pbx.conferences: names that differ only in case, which ConfBridge takes for one conference: ${concatMapStringsSep "; " (concatStringsSep ", ") alike}.";
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
