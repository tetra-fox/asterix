# Typed ConfBridge options (confbridge.conf): bridge profiles, user profiles
# and DTMF menus. Layer-1 ids: "bridge:<name>", "user:<name>", "menu:<name>".
{ config, lib, ... }:
let
  inherit (lib)
    filterAttrs
    isList
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterisk;
  ccfg = cfg.confbridge;
  asteriskLib = import ../lib { inherit lib; };
  inherit (asteriskLib) format;

  secretOrString = types.either types.str format.types.secret // {
    description = "string or secret reference";
  };

  settingsOption =
    what:
    mkOption {
      type = types.attrsOf format.types.value;
      default = { };
      description = "Additional keys of the ${what} section.";
    };

  optionalBool =
    description:
    mkOption {
      type = types.nullOr types.bool;
      default = null;
      inherit description;
    };

  bridgeType = types.submodule {
    options = {
      maxMembers = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Maximum number of participants (`max_members`).";
      };
      recordConference = optionalBool "Record the conference (`record_conference`).";
      musicOnHoldClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Music on hold class for users waiting alone.";
      };
      language = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Language of the conference prompts.";
      };
      settings = settingsOption "bridge profile";
    };
  };

  userType = types.submodule {
    options = {
      admin = optionalBool "Users with this profile are administrators.";
      marked = optionalBool "Users with this profile are marked users.";
      pin = mkOption {
        type = types.nullOr secretOrString;
        default = null;
        description = "PIN required to join, normally a secret reference.";
      };
      waitMarked = optionalBool "Wait (with music) until a marked user joins (`wait_marked`).";
      endMarked = optionalBool "Leave when the last marked user leaves (`end_marked`).";
      startMuted = optionalBool "Join muted (`startmuted`).";
      quiet = optionalBool "Do not play join/leave sounds for this user.";
      announceUserCount = optionalBool "Announce the number of participants on join (`announce_user_count`).";
      musicOnHoldWhenEmpty = optionalBool "Play music on hold while alone (`music_on_hold_when_empty`).";
      settings = settingsOption "user profile";
    };
  };

  # Scalars become defaults, lists stay definitions, nulls are dropped.
  toSection =
    attrs: mapAttrs (_: v: if isList v then v else mkDefault v) (filterAttrs (_: v: v != null) attrs);

  profiles =
    kind: attrs: toValues:
    mapAttrs' (
      name: p:
      nameValuePair "${kind}:${name}" (mkMerge [
        (
          {
            inherit name;
            type = kind;
          }
          // toSection (toValues p)
        )
        (p.settings or { })
      ])
    ) attrs;
in
{
  options.services.asterisk.confbridge = {
    bridges = mkOption {
      type = types.attrsOf bridgeType;
      default = { };
      example = {
        board.maxMembers = 10;
      };
      description = ''
        Bridge profiles (`type = bridge`), used as `ConfBridge(room,board)`.
        Asterisk adds `default_bridge` when it is not defined.
      '';
    };

    users = mkOption {
      type = types.attrsOf userType;
      default = { };
      example = lib.literalExpression ''
        {
          chair = { admin = true; marked = true; };
          guest = { waitMarked = true; endMarked = true; pin = config.lib.asterisk.secret config.sops.secrets.conf-pin.path; };
        }
      '';
      description = ''
        User profiles (`type = user`), used as `ConfBridge(room,,guest)`.
        Asterisk adds `default_user` when it is not defined.
      '';
    };

    menus = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      example = {
        admin_menu = {
          "*1" = "toggle_mute";
          "*2" = "admin_toggle_conference_lock";
          "*3" = "admin_kick_last";
        };
      };
      description = "DTMF menus (`type = menu`), mapping key sequences to actions.";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk.settings."confbridge.conf" = mkMerge [
      (profiles "bridge" ccfg.bridges (b: {
        max_members = b.maxMembers;
        record_conference = b.recordConference;
        music_on_hold_class = b.musicOnHoldClass;
        inherit (b) language;
      }))
      (profiles "user" ccfg.users (u: {
        inherit (u)
          admin
          marked
          pin
          quiet
          ;
        wait_marked = u.waitMarked;
        end_marked = u.endMarked;
        startmuted = u.startMuted;
        announce_user_count = u.announceUserCount;
        music_on_hold_when_empty = u.musicOnHoldWhenEmpty;
      }))
      (profiles "menu" ccfg.menus (m: m))
    ];
  };
}
