# services.asterix.conferences: a ConfBridge room with a number, in
# pbx-conference-<name>, with a bridge and a user profile of that name
{
  config,
  lib,
  options,
  ...
}: let
  inherit
    (lib)
    concatMapStringsSep
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;
  inherit (import ../lib.nix {inherit lib;}) confbridgeModules;
  coreBridge = options.services.asterisk.confbridge.bridges.type.getSubOptions [];
  coreUser = options.services.asterisk.confbridge.users.type.getSubOptions [];

  # the bridge and the user profile share a name, since ConfBridge keeps the
  # profiles of each type apart (conf_config_parser.c struct confbridge_cfg)
  profile = pbxLib.objectContext "conference";
  # confbridge.conf keeps 79 bytes of a profile's name (main/config.c struct
  # ast_category), and ConfBridge looks for the whole name
  maxName = 79 - builtins.stringLength (profile "");

  conferenceType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "800";
        description = "Number phones dial to join the conference.";
      };
      maxMembers = mkOption {
        inherit (coreBridge.maxMembers) type default;
        description = "Maximum number of callers in the conference (`max_members`).";
      };
      musicOnHoldWhenEmpty = mkOption {
        inherit (coreUser.musicOnHoldWhenEmpty) type default;
        description = "Play music on hold to a caller who is alone in the conference (`music_on_hold_when_empty`).";
      };
      announceJoinLeave = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Ask each caller for their name on joining, and announce it when they join and leave (`announce_join_leave`).";
      };
    };
  };

  # ConfBridge needs a conference name
  badNames = builtins.filter (name: name == "" || pbxLib.breaksContext name || pbxLib.breaksArgument name) (builtins.attrNames cfg.conferences);
  longNames = builtins.filter (name: builtins.stringLength name > maxName) (builtins.attrNames cfg.conferences);
  # ConfBridge finds a conference and a profile by its name in any case
  # (apps/app_confbridge.c conference_bridge_cmp_cb, conf_config_parser.c
  # bridge_cmp_cb and user_cmp_cb)
  alike = builtins.filter (names: builtins.length names > 1) (builtins.attrValues (builtins.groupBy lib.toLower (builtins.attrNames cfg.conferences)));
in {
  options.services.asterix.conferences = mkOption {
    type = types.attrsOf conferenceType;
    default = {};
    example = lib.literalExpression ''
      {
        board = {
          number = "800";
          maxMembers = 10;
          musicOnHoldWhenEmpty = true;
        };
      }
    '';
    description = ''
      Conference rooms, keyed by room name. Each one defines the bridge and
      the user profile `pbx-conference-<name>` of
      {option}`services.asterisk.confbridge.bridges` and `users`, where
      settings without an option here can be added. A name has up to
      ${toString maxName} bytes, so the profile's name fits the 79 bytes
      confbridge.conf keeps, and ConfBridge tells names apart without regard
      to case. A name cannot be empty or contain `,` `;` `[` `]` `"` `\`
      `''${` `$[`, an unclosed `(` or a line break, nor end with white space.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.modules.needed."services.asterix.conferences" = mkIf (cfg.conferences != {}) confbridgeModules;

    services.asterisk.confbridge.bridges = mapAttrs' (name: conference:
      nameValuePair (profile name) {
        maxMembers = mkDefault conference.maxMembers;
      })
    cfg.conferences;

    services.asterisk.confbridge.users = mapAttrs' (name: conference:
      nameValuePair (profile name) {
        musicOnHoldWhenEmpty = mkDefault conference.musicOnHoldWhenEmpty;
        settings = lib.optionalAttrs (conference.announceJoinLeave != null) {
          announce_join_leave = mkDefault conference.announceJoinLeave;
        };
      })
    cfg.conferences;

    services.asterisk.dialplan.contexts =
      mapAttrs' (
        name: _:
          nameValuePair (pbxLib.objectContext "conference" name) {
            comment = mkDefault "from services.asterix.conferences.${name}";
            extensions.s = [
              (pbxLib.app "Answer" [])
              {
                app = "ConfBridge";
                args = [
                  (format.joinFields [
                    name
                    (profile name)
                    (profile name)
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
          services.asterix.conferences: names that Asterisk would misread in the dialplan (they may not be empty, or contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["services" "asterix" "conferences" name]) badNames}
        '';
      }
      {
        assertion = longNames == [];
        message = "services.asterix.conferences: names longer than ${toString maxName} bytes, whose profile pbx-conference-<name> confbridge.conf cuts to 79 bytes, so ConfBridge does not find it: ${concatStringsSep ", " longNames}.";
      }
      {
        assertion = alike == [];
        message = "services.asterix.conferences: names that differ only in case, which ConfBridge takes for one conference: ${concatMapStringsSep "; " (concatStringsSep ", ") alike}.";
      }
    ];
  };
}
