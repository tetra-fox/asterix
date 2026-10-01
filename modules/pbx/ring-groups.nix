# pbx.ringGroups: several phones for one call, in pbx-ringgroup-<name>.
# External numbers are dialled from the group's own context through a Local
# channel, so their confirmation prompt only runs on their leg.
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
    filterAttrs
    hasInfix
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  trunks = config.services.asterisk.pjsip.trunks;

  groupType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "600";
        description = "Number phones dial to call the group.";
      };
      members = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "201"
          "202"
        ];
        description = "Extensions of {option}`pbx.extensions` that ring. Their own busy and no-answer destinations do not apply.";
      };
      # each number is an extension of the group's own context, next to its
      # `s`, and part of the Local channel Dial calls it through
      external = mkOption {
        type = types.listOf (types.strMatching "[+]?[0-9*#]+" // {description = "phone number: digits, * and #, with an optional leading +";});
        default = [];
        example = ["5551234"];
        description = ''
          Numbers outside, called through `trunk`: digits, `*` and `#`, with
          an optional leading `+`. Whoever answers hears "press 1 to accept
          this call, or 2 to reject it", so a mobile phone's voicemail cannot
          take the call. `ringTime` includes the time to answer and press 1.
        '';
      };
      trunk = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = lib.literalExpression "config.pbx.outbound.trunk";
        description = "Trunk of {option}`services.asterisk.pjsip.trunks` the external numbers are called through.";
      };
      strategy = mkOption {
        type = types.enum [
          "ringall"
          "hunt"
        ];
        default = "ringall";
        description = "`ringall` rings everyone at once for `ringTime`, `hunt` rings them one after the other, each for `ringTime`.";
      };
      ringTime = mkOption {
        type = types.ints.positive;
        default = 20;
        description = "Seconds a ring lasts, see `strategy`.";
      };
      noAnswer = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        example = {voicemail = "200";};
        description = "Where the call goes when nobody answers.";
      };
    };
  };

  trunkOf = group:
    if group.trunk != null
    then group.trunk
    else if cfg.outbound != null
    then cfg.outbound.trunk
    else null;

  groupSection = name: group: let
    members = map pbxLib.devices group.members;
    external = map (number: "Local/${number}@${pbxLib.objectContext "ringgroup" name}/n") group.external;
    # b() runs `leg` of pbx-confirm on each channel before it is called
    dial = channels: withLocal:
      pbxLib.app "Dial" (
        [(concatStringsSep "&" channels) group.ringTime]
        ++ optional withLocal "b(pbx-confirm^leg^1)"
      );
    withCallerId = cfg.outbound != null && cfg.outbound.callerId != null;
    outsideCallerId = optional withCallerId (
      pbxLib.app "Set" ["CALLERID(num)=${cfg.outbound.callerId}"]
    );
    # an assertion below reports a trunk that does not exist
    callerIdOption = lib.optionalString (withCallerId && trunks ? ${trunkOf group}) (pbxLib.callerIdOption trunks.${trunkOf group});
  in {
    comment = mkDefault "from pbx.ringGroups.${name}";
    extensions =
      {
        s =
          (
            if group.strategy == "ringall"
            then [(dial (members ++ external) (external != []))]
            else map (channel: dial [channel] false) members ++ map (channel: dial [channel] true) external
          )
          ++ pbxLib.steps group.noAnswer;
      }
      # without a trunk the assertion below reports it
      // lib.genAttrs (lib.optionals (trunkOf group != null) group.external) (_:
        outsideCallerId
        ++ [
          (pbxLib.app "Dial" [
            "PJSIP/\${EXTEN}@${trunkOf group}"
            group.ringTime
            "U(pbx-confirm)${callerIdOption}"
          ])
          (pbxLib.app "Hangup" [])
        ]);
  };

  withExternal = filterAttrs (_: group: group.external != []) cfg.ringGroups;
  # Dial splits its channels at &, and the Local channel of an external
  # number names the group's context
  badNames = builtins.filter (name: pbxLib.breaksContext name || pbxLib.breaksArgument name || (withExternal ? ${name} && hasInfix "&" name)) (builtins.attrNames cfg.ringGroups);
  # a group without a trunk uses pbx.outbound's, which routes.nix checks
  unknownTrunks = builtins.attrNames (
    filterAttrs (_: group: group.trunk != null && !(trunks ? ${group.trunk})) cfg.ringGroups
  );
in {
  options.pbx.ringGroups = mkOption {
    type = types.attrsOf groupType;
    default = {};
    example = lib.literalExpression ''
      {
        sales = {
          number = "600";
          members = [ "201" "202" ];
          ringTime = 15;
          noAnswer.voicemail = "200";
        };
      }
    '';
    description = ''
      Ring groups: several phones, and numbers outside, for one call. A name
      cannot contain `,` `;` `[` `]` `"` `\` `''${` `$[`, an unclosed `(` or a
      line break, nor end with white space, and with `external` numbers not
      `&` either.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts =
      mapAttrs' (name: group: nameValuePair (pbxLib.objectContext "ringgroup" name) (groupSection name group)) cfg.ringGroups
      // optionalAttrs (withExternal != {}) {
        pbx-confirm = {
          comment = mkDefault "from pbx.ringGroups: confirmation of external members";
          extensions = {
            # a Dial U() routine on the external leg, which Dial hangs up, and
            # the Local channel with it, unless 1 was pressed (apps/app_dial.c)
            s = [
              (pbxLib.app "Set" ["GOSUB_RESULT=CONTINUE"])
              (pbxLib.app "Read" [
                "PBX_CONFIRM"
                "followme/no-recording&followme/options"
                1
                ""
                3
                5
              ])
              (pbxLib.app "GotoIf" [''$["''${PBX_CONFIRM}" != "1"]?reject''])
              (pbxLib.app "Set" ["GOSUB_RESULT="])
              {
                app = "Return";
                args = [];
                label = "reject";
              }
            ];
            # Dial finishes `s` even after the call is gone, so the ;1 side of
            # the Local channel hangs up the leg when the ring group drops it
            leg = [
              (pbxLib.app "GotoIf" [''$["''${CHANNEL(channeltype)}" != "Local"]?done''])
              (pbxLib.app "Set" ["CHANNEL(hangup_handler_push)=pbx-confirm,drop,1"])
              {
                app = "Return";
                args = [];
                label = "done";
              }
            ];
            # the ;2 side names the leg once it answered
            drop = [
              (pbxLib.app "Set" ["PBX_LEG=\${IMPORT(\${CHANNEL:0:-1}2,DIALEDPEERNAME)}"])
              (pbxLib.app "GotoIf" [''$["''${PBX_LEG}" = ""]?done''])
              (pbxLib.app "SoftHangup" ["\${PBX_LEG}"])
              {
                app = "Return";
                args = [];
                label = "done";
              }
            ];
          };
        };
      };

    assertions = [
      {
        assertion = builtins.all (group: group.members != [] || group.external != []) (builtins.attrValues cfg.ringGroups);
        message = "pbx.ringGroups: a ring group needs members or external numbers.";
      }
      {
        assertion = badNames == [];
        message = ''
          pbx.ringGroups: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis, nor & with external numbers):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["pbx" "ringGroups" name]) badNames}
        '';
      }
      {
        assertion = builtins.all (group: trunkOf group != null) (builtins.attrValues withExternal);
        message = "pbx.ringGroups: ${
          concatStringsSep ", " (builtins.attrNames (filterAttrs (_: group: trunkOf group == null) withExternal))
        } call external numbers, but name no trunk and pbx.outbound is not set.";
      }
      {
        assertion = unknownTrunks == [];
        message = ''
          pbx: trunks that are not defined in services.asterisk.pjsip.trunks:
            ${concatStringsSep "\n  " (map (name: "pbx.ringGroups.${name}.trunk: ${cfg.ringGroups.${name}.trunk}") unknownTrunks)}
        '';
      }
      (
        let
          missing = concatMap (
            name:
              map (member: "pbx.ringGroups.${name}: ${member}") (
                builtins.filter (member: !(cfg.extensions ? ${member})) cfg.ringGroups.${name}.members
              )
          ) (builtins.attrNames cfg.ringGroups);
        in {
          assertion = missing == [];
          message = ''
            pbx.ringGroups: members that are not extensions of pbx.extensions:
              ${concatStringsSep "\n  " missing}
          '';
        }
      )
    ];
  };
}
