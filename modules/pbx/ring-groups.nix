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
      external = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["5551234"];
        description = ''
          Numbers outside, called through `trunk`. Whoever answers hears
          "press 1 to accept this call, or 2 to reject it", so a mobile
          phone's voicemail cannot take the call. `ringTime` includes the
          time to answer and press 1.
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

  channels = name: group:
    map pbxLib.devices group.members
    ++ map (number: "Local/${number}@${pbxLib.objectContext "ringgroup" name}/n") group.external;

  groupSection = name: group: let
    dial = members: pbxLib.app "Dial" [(concatStringsSep "&" members) group.ringTime];
    outsideCallerId = optional (cfg.outbound != null && cfg.outbound.callerId != null) (
      pbxLib.app "Set" ["CALLERID(num)=${cfg.outbound.callerId}"]
    );
  in {
    comment = mkDefault "from pbx.ringGroups.${name}";
    extensions =
      {
        s =
          (
            if group.strategy == "ringall"
            then [(dial (channels name group))]
            else map (channel: dial [channel]) (channels name group)
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
            "U(pbx-confirm^s^1)"
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
    filterAttrs (_: group: group.trunk != null && !(config.services.asterisk.pjsip.trunks ? ${group.trunk})) cfg.ringGroups
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
    description = "Ring groups: several phones, and numbers outside, for one call.";
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts =
      mapAttrs' (name: group: nameValuePair (pbxLib.objectContext "ringgroup" name) (groupSection name group)) cfg.ringGroups
      // optionalAttrs (withExternal != {}) {
        # a Dial U() routine on the external leg: GOSUB_RESULT=CONTINUE hangs
        # that leg up, and the Local channel ends with it
        pbx-confirm = {
          comment = mkDefault "from pbx.ringGroups: confirmation of external members";
          extensions.s = [
            (pbxLib.app "Read" [
              "PBX_CONFIRM"
              "followme/no-recording&followme/options"
              1
              ""
              3
              5
            ])
            (pbxLib.app "GotoIf" [''$["''${PBX_CONFIRM}" = "1"]?accept''])
            (pbxLib.app "Set" ["GOSUB_RESULT=CONTINUE"])
            {
              app = "Return";
              args = [];
              label = "accept";
            }
          ];
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
