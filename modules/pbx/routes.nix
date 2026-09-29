# pbx.inbound, pbx.outbound and pbx.emergency: calls between the phones and
# trunks. Calls from a trunk start in pbx-inbound-<trunk>, the default context
# pbx gives every trunk, which holds the trunk's numbers of pbx.inbound.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMapStringsSep
    concatStringsSep
    filterAttrs
    genAttrs
    mapAttrs
    mapAttrsToList
    mkDefault
    mkIf
    mkMerge
    mkOption
    optional
    types
    unique
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  format = (import ../../lib {inherit lib;}).format;

  inboundType = types.submodule {
    options = {
      trunk = mkOption {
        type = types.str;
        example = "provider";
        description = "Trunk of {option}`services.asterisk.pjsip.trunks` the number's calls arrive on.";
      };
      destination = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        example = {ringGroup = "sales";};
        description = "Where calls go, whatever the time. Use either this or `hours`.";
      };
      hours = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "office";
        description = "Opening hours of {option}`pbx.hours` that choose between `open` and `closed`.";
      };
      open = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        description = "Where calls go during `hours`.";
      };
      closed = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        description = "Where calls go outside `hours`, on holidays and after closing early.";
      };
    };
  };

  outboundType = types.submodule {
    options = {
      prefix = mkOption {
        type = types.strMatching "[0-9*#]*";
        example = "9";
        description = ''
          Digits dialled before a number outside, removed before the call
          leaves. Can be empty. A pbx number that starts with them still
          reaches the pbx: with `9`, a ring group on 900 takes the calls to
          900, so 00 outside cannot be dialled. So does a call pickup code
          (`pickupexten` of features.conf) that starts with them, which
          chan_pjsip takes before the dialplan: with `9` and a pickup code of
          `981`, 81 outside cannot be dialled.
        '';
      };
      trunk = mkOption {
        type = types.str;
        description = "Trunk of {option}`services.asterisk.pjsip.trunks` calls go out through.";
      };
      callerId = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "5551000";
        description = "Number presented to the called party; the trunk decides without it.";
      };
    };
  };

  emergencyType = types.submodule {
    options = {
      numbers = mkOption {
        type = types.nonEmptyListOf (types.strMatching "[0-9]+");
        example = ["911"];
        description = ''
          Emergency numbers where the PBX is. Phones can dial them with and
          without the outbound prefix.
        '';
      };
      trunk = mkOption {
        type = types.str;
        description = "Trunk of {option}`services.asterisk.pjsip.trunks` emergency calls go out through.";
      };
      callerId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Number presented to the emergency service, usually the one the site's address is registered with.";
      };
      notify = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["201"];
        description = ''
          Extensions called at the same moment, which hear the caller's
          number, for example the front desk. Some places require this.
        '';
      };
    };
  };

  hasHours = route: route.hours != null || route.open != null || route.closed != null;
  complete = route:
    if route.destination != null
    then !(hasHours route)
    else route.hours != null && route.open != null && route.closed != null;

  trunks = config.services.asterisk.pjsip.trunks;
  inboundTrunks = unique (map (route: route.trunk) (builtins.attrValues cfg.inbound));
  # trunks whose calls start in pbx-inbound-<trunk>
  pbxTrunks = builtins.attrNames (filterAttrs (name: trunk: trunk.context == pbxLib.objectContext "inbound" name) trunks);

  inboundSteps = route:
    if route.destination != null
    then pbxLib.steps route.destination
    else
      [
        (pbxLib.app "Gosub" [
          (pbxLib.objectContext "hours" route.hours)
          "s"
          "1"
        ])
        (pbxLib.app "GotoIf" [''$["''${GOSUB_RETVAL}" = "open"]?open''])
      ]
      ++ pbxLib.steps route.closed
      ++ pbxLib.labelled "open" route.open;

  setCallerId = callerId: optional (callerId != null) (pbxLib.app "Set" ["CALLERID(num)=${callerId}"]);

  # Originate() calls one channel, so a Local channel into
  # pbx-emergency-notify rings every device of the extension
  emergencySteps = e: number:
    map (extension:
      pbxLib.app "Originate" [
        "Local/${extension}@pbx-emergency-notify"
        "app"
        "SayDigits"
        "\${CALLERID(num)}"
        ""
        30
        "acn"
      ])
    e.notify
    ++ setCallerId e.callerId
    ++ [
      (pbxLib.app "Dial" ["PJSIP/${number}@${e.trunk}"])
      (pbxLib.app "Hangup" [])
    ];

  prefix = cfg.outbound.prefix;
  numberAfterPrefix =
    if prefix == ""
    then "\${EXTEN}"
    else "\${EXTEN:${toString (builtins.stringLength prefix)}}";

  outboundTrunkUses =
    optional (cfg.outbound != null) {
      where = "pbx.outbound.trunk";
      inherit (cfg.outbound) trunk;
    }
    ++ optional (cfg.emergency != null) {
      where = "pbx.emergency.trunk";
      inherit (cfg.emergency) trunk;
    };
  trunkUses =
    mapAttrsToList (number: route: {
      where = ''pbx.inbound."${number}".trunk'';
      inherit (route) trunk;
    })
    cfg.inbound
    ++ outboundTrunkUses;
  unknownTrunks = builtins.filter (use: !(trunks ? ${use.trunk})) trunkUses;
  # trunks pbx dials as PJSIP/<number>@<trunk>; a ring group without a trunk
  # of its own uses pbx.outbound's
  badTrunkNames = builtins.filter (use: pbxLib.breaksDialString use.trunk) (
    outboundTrunkUses
    ++ mapAttrsToList (name: group: {
      where = "pbx.ringGroups.${name}.trunk";
      inherit (group) trunk;
    }) (filterAttrs (_: group: group.external != [] && group.trunk != null) cfg.ringGroups)
  );

  unknownHours = builtins.filter (number: cfg.inbound.${number}.hours != null && !(cfg.hours ? ${cfg.inbound.${number}.hours})) (builtins.attrNames cfg.inbound);
  unknownNotify = builtins.filter (extension: !(cfg.extensions ? ${extension})) (lib.optionals (cfg.emergency != null) cfg.emergency.notify);
  # where calls from a trunk start is the context of its endpoint in the final
  # pjsip.conf, which settings can change
  endpointContexts = lib.listToAttrs (map (s: lib.nameValuePair s.name (s.context or null)) (
    builtins.filter (s: (s.type or null) == "endpoint") (format.resolveInheritance (config.services.asterisk.settings."pjsip.conf" or {})).sections
  ));
  foreignContexts = builtins.filter (trunk: trunks ? ${trunk} && (endpointContexts.${trunk} or null) != pbxLib.objectContext "inbound" trunk) inboundTrunks;
in {
  # a default in each trunk rather than trunks.<name>.context, which would
  # create a trunk for a misspelt name
  options.services.asterisk.pjsip.trunks = mkOption {
    type = types.attrsOf (types.submodule ({name, ...}: {
      config.context = mkIf cfg.enable (mkDefault (pbxLib.objectContext "inbound" name));
    }));
  };

  options.pbx = {
    inbound = mkOption {
      type = types.attrsOf inboundType;
      default = {};
      example = lib.literalExpression ''
        {
          "5551000" = {
            trunk = "provider";
            hours = "office";
            open.ringGroup = "sales";
            closed.voicemail = "200";
          };
        }
      '';
      description = ''
        Numbers calls arrive at from trunks, keyed by the number the trunk
        sends, and where their calls go: `destination`, or `hours` with
        `open` and `closed`. With pbx, calls from a trunk start in
        `pbx-inbound-<trunk>`, which holds these numbers, unless the trunk
        sets a `context` of its own. Other numbers are rejected.
      '';
    };

    outbound = mkOption {
      type = types.nullOr outboundType;
      default = null;
      example = {
        prefix = "9";
        trunk = "provider";
        callerId = "5551000";
      };
      description = "Calls from phones to numbers outside: the prefix, then the number.";
    };

    emergency = mkOption {
      type = types.nullOr emergencyType;
      default = null;
      example = {
        numbers = ["911"];
        trunk = "provider";
        callerId = "5551000";
        notify = ["201"];
      };
      description = ''
        Emergency calls. There are no defaults: the numbers, and who must be
        told, depend on where the PBX is.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.asterisk.dialplan.contexts = lib.listToAttrs (map (trunk:
        lib.nameValuePair (pbxLib.objectContext "inbound" trunk) {
          comment = mkDefault "from pbx.inbound: calls from trunk ${trunk}";
          # an incomplete number has no steps, the assertion below names it
          extensions = mapAttrs (_: inboundSteps) (filterAttrs (_: route: route.trunk == trunk && complete route) cfg.inbound);
        })
      pbxTrunks);

      assertions = [
        {
          assertion = builtins.all complete (builtins.attrValues cfg.inbound);
          message = "pbx.inbound: ${
            concatStringsSep ", " (builtins.attrNames (filterAttrs (_: route: !(complete route)) cfg.inbound))
          } need either `destination`, or `hours` with `open` and `closed`.";
        }
        {
          assertion = unknownHours == [];
          message = "pbx.inbound: ${concatStringsSep ", " unknownHours} use hours that are not defined in pbx.hours.";
        }
        {
          assertion = unknownTrunks == [];
          message = ''
            pbx: trunks that are not defined in services.asterisk.pjsip.trunks:
              ${concatMapStringsSep "\n  " (use: "${use.where}: ${use.trunk}") unknownTrunks}
          '';
        }
        {
          assertion = badTrunkNames == [];
          message = ''
            pbx: trunk names that Asterisk would misread in a dial string (they may not contain , ; [ ] " \ ''${ $[ & / or an unclosed parenthesis):
              ${concatMapStringsSep "\n  " (use: "${use.where}: ${use.trunk}") badTrunkNames}
          '';
        }
        {
          assertion = foreignContexts == [];
          message = "pbx.inbound: the trunk(s) ${concatStringsSep ", " foreignContexts} have a context of their own, so their calls do not reach pbx.inbound; remove it.";
        }
      ];
    }

    (mkIf (cfg.outbound != null) {
      services.asterisk.dialplan.contexts.pbx-outbound = {
        comment = mkDefault "from pbx.outbound";
        extensions."_${prefix}X." =
          setCallerId cfg.outbound.callerId
          ++ [
            (pbxLib.app "Dial" ["PJSIP/${numberAfterPrefix}@${cfg.outbound.trunk}"])
            (pbxLib.app "Hangup" [])
          ];
      };
    })

    (mkIf (cfg.emergency != null) {
      services.asterisk.dialplan.contexts = {
        pbx-emergency = {
          comment = mkDefault "from pbx.emergency";
          extensions = genAttrs cfg.emergency.numbers (emergencySteps cfg.emergency);
        };
        # Dial() has no timeout: Originate() hangs up the Local channel after
        # its own
        pbx-emergency-notify = mkIf (cfg.emergency.notify != []) {
          comment = mkDefault "from pbx.emergency.notify";
          extensions = genAttrs cfg.emergency.notify (extension: [
            (pbxLib.app "Dial" [(pbxLib.devices extension)])
            (pbxLib.app "Hangup" [])
          ]);
        };
      };

      assertions = [
        {
          assertion = unknownNotify == [];
          message = "pbx.emergency.notify: ${concatStringsSep ", " unknownNotify} are not extensions of pbx.extensions.";
        }
      ];
    })
  ]);
}
