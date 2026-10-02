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
    concatLists
    concatMap
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
    optionalAttrs
    types
    unique
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;

  inboundType = types.submodule {
    options = {
      trunk = mkOption {
        type = types.coercedTo types.str lib.toList (types.nonEmptyListOf types.str);
        example = "provider";
        description = ''
          Trunk of {option}`services.asterisk.pjsip.trunks` the number's calls
          arrive on, or a list of them for a number that arrives through more
          than one provider or account.
        '';
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
          leaves; the number outside has two digits or more. Can be empty, and
          then every number of two digits or more that no pbx number takes
          goes out through the trunk, a mistyped extension number included. A
          pbx number that starts with them still reaches the pbx: with `9`, a
          ring group on 900 takes the calls to 900, so 00 outside cannot be
          dialled. So does a call pickup code (`pickupexten` of features.conf)
          that starts with them, which chan_pjsip takes before the dialplan:
          with `9` and a pickup code of `981`, 81 outside cannot be dialled.
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
        description = ''
          Number presented to the called party, on calls out and to the
          external numbers of ring groups. The trunk's From header keeps
          naming its account, so pbx sends this number in the
          P-Asserted-Identity header of these calls; a provider that ignores
          that header shows the account's number. Without it, the trunk
          decides.
        '';
      };
    };
  };

  emergencyType = types.submodule {
    options = {
      numbers = mkOption {
        # numbers left unset are an error, as with nonEmptyListOf, rather
        # than an empty list, so a PBX without emergency calls says so
        type = types.listOf (types.strMatching "[0-9]+") // {emptyValue = {};};
        example = ["911"];
        description = ''
          Emergency numbers where the PBX is. Phones can dial them with and
          without the outbound prefix. With {option}`pbx.outbound`, an empty
          list says that the PBX makes no emergency calls; an emergency number
          is then taken for a number outside, or reaches nothing.
        '';
      };
      trunk = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = lib.literalExpression "config.pbx.outbound.trunk";
        description = "Trunk of {option}`services.asterisk.pjsip.trunks` emergency calls go out through.";
      };
      callerId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Number presented to the emergency service, usually the one the
          site's address is registered with, sent in P-Asserted-Identity as
          {option}`pbx.outbound.callerId` is; without it, emergency calls
          present that one.
        '';
      };
      notify = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["201"];
        description = ''
          Extensions called at the same moment, which hear the caller's
          number, for example the front desk. Some places require this. The
          caller's own extension is left out, with all of its devices.
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
  inboundTrunks = unique (concatMap (route: route.trunk) (builtins.attrValues cfg.inbound));
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

  # an emergency call presents the site's number, not the caller's extension
  emergencyCallerId =
    if cfg.emergency.callerId != null
    then cfg.emergency.callerId
    else if cfg.outbound != null
    then cfg.outbound.callerId
    else null;

  # Dial's arguments after the dial string for a call that presents
  # `callerId`; an assertion below reports a trunk that does not exist
  callerIdArguments = callerId: trunk:
    lib.optionals (callerId != null && trunks ? ${trunk}) [
      ""
      (pbxLib.callerIdOption trunks.${trunk})
    ];

  # a call the trunk does not put through, as to a provider that does not
  # answer, ends with congestion (503), which phones play as a fast busy; a
  # busy one keeps the busy cause Dial left on the channel (486)
  dialTrunk = arguments: [
    (pbxLib.app "Dial" arguments)
    (pbxLib.app "GotoIf" [''$["''${DIALSTATUS}" = "BUSY"]?busy''])
    (pbxLib.app "Congestion" [])
    {
      app = "Hangup";
      args = [];
      label = "busy";
    }
  ];

  emergencySteps = e: number:
    map (extension: pbxLib.app "Gosub" ["notify" "1(${extension})"]) e.notify
    ++ setCallerId emergencyCallerId
    ++ dialTrunk (["PJSIP/${number}@${emergencyTrunk}"] ++ callerIdArguments emergencyCallerId emergencyTrunk);

  # emergency calls without a trunk of their own go out through pbx.outbound's
  emergencyTrunk =
    if cfg.emergency.trunk != null
    then cfg.emergency.trunk
    else if cfg.outbound != null
    then cfg.outbound.trunk
    else null;

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
    ++ optional (cfg.emergency != null && cfg.emergency.trunk != null) {
      where = "pbx.emergency.trunk";
      inherit (cfg.emergency) trunk;
    };
  trunkUses =
    concatLists (mapAttrsToList (number: route:
      map (trunk: {
        where = ''pbx.inbound."${number}".trunk'';
        inherit trunk;
      })
      route.trunk)
    cfg.inbound)
    ++ outboundTrunkUses
    ++ map (trunk: {
      where = "pbx.tieLines";
      inherit trunk;
    })
    cfg.tieLines;
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

  # a number, s, or a pattern of numbers: X, Z and N, sets in brackets, and
  # . and ! at the end (main/pbx.c ext_cmp_pattern_pos)
  badKeys = builtins.filter (key: builtins.match "[+]?[0-9*#]+|s|_([0-9*#+XZNxzn.!]|\\[[0-9*#+-]+])+" key == null) (builtins.attrNames cfg.inbound);
  unknownHours = builtins.filter (number: cfg.inbound.${number}.hours != null && !(cfg.hours ? ${cfg.inbound.${number}.hours})) (builtins.attrNames cfg.inbound);
  unknownNotify = builtins.filter (extension: !(cfg.extensions ? ${extension})) (lib.optionals (cfg.emergency != null) cfg.emergency.notify);
  # where calls from a trunk start is the context of its endpoint in the final
  # pjsip.conf, which settings can change
  endpointContexts = lib.listToAttrs (map (s: lib.nameValuePair s.name (s.context or null)) (
    builtins.filter (s: (s.type or null) == "endpoint") (format.resolveInheritance (config.services.asterisk.settings."pjsip.conf" or {})).sections
  ));
  foreignContexts = builtins.filter (trunk: trunks ? ${trunk} && (endpointContexts.${trunk} or null) != pbxLib.objectContext "inbound" trunk) inboundTrunks;

  # the contexts a context includes in the final extensions.conf, where
  # sections of one name are one context; raw text can add more
  sections = lib.groupBy (s: s.name) (builtins.attrValues (config.services.asterisk.settings."extensions.conf" or {}));
  includesOf = context: lib.concatMap (s: map format.includedContext (builtins.filter builtins.isString (lib.toList (s.include or [])))) (sections.${context} or []);
  reachesOutbound = context:
    builtins.any (c: c.key == "pbx-outbound") (builtins.genericClosure {
      startSet = [{key = context;}];
      operator = c: map (key: {inherit key;}) (includesOf c.key);
    });
  # trunks whose callers can dial out through pbx.outbound with no menu in
  # between, as from pbx-internal, which includes pbx-outbound
  dialOut = builtins.filter (trunk: !(builtins.elem trunk cfg.tieLines) && endpointContexts ? ${trunk} && endpointContexts.${trunk} != null && reachesOutbound endpointContexts.${trunk}) (builtins.attrNames trunks);
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
        Numbers calls arrive at from trunks, keyed by the user part of the
        Request-URI the trunk sends (a number only in To does not count), and
        where their calls go: `destination`, or `hours` with `open` and
        `closed`. With pbx, calls from a trunk start in
        `pbx-inbound-<trunk>`, which holds these numbers, unless the trunk
        sets a `context` of its own. Other numbers are rejected.

        A key is a number of digits, `*` and `#`, with an optional leading
        `+`; `s`, which takes the calls that name no number: those to the
        address a trunk registered, unless its `registration.contactUser`
        gives that a number, and those whose Request-URI has no user part; or
        a pattern of numbers, such as `_X.` for any number. A number of the
        trunk goes before its patterns, and of two patterns that match, the
        more specific one takes the call. chan_pjsip takes a call to the call
        pickup code (`pickupexten` of features.conf) as a call pickup before
        the dialplan runs, also when a pattern matches it.
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
      description = ''
        Calls from phones to numbers outside: the prefix, then the number. A
        call the trunk does not put through ends with congestion, which phones
        play as a fast busy, and one the far end answers busy stays busy. A
        provider that does not answer at all fails a call once its INVITE
        times out, after 32 s, and at once after the trunk's next qualify
        (`qualifyFrequency`). It needs {option}`pbx.emergency` beside it, with
        no emergency numbers if the PBX makes no emergency calls: without
        their own route they would go out as numbers outside, 911 as 11 with
        the prefix 9.
      '';
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
        Emergency calls, which {option}`pbx.outbound` needs. There are no
        defaults: the numbers, and who must be told, depend on where the PBX
        is. A call waits for the trunk as long as it takes, and one the trunk
        does not put through ends with congestion, as with
        {option}`pbx.outbound`.
      '';
    };

    tieLines = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Trunks of {option}`services.asterisk.pjsip.trunks` that connect
        another PBX, whose callers may dial out through
        {option}`pbx.outbound`. pbx refuses any other trunk whose calls start
        in a context that reaches `pbx-outbound`, as `pbx-internal` does,
        since anyone who can call in through it could dial out, emergency
        numbers included.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.asterisk.dialplan.contexts = lib.listToAttrs (map (trunk:
        lib.nameValuePair (pbxLib.objectContext "inbound" trunk) {
          comment = mkDefault "from pbx.inbound: calls from trunk ${trunk}";
          # an incomplete number has no steps, the assertion below names it
          extensions = mapAttrs (_: inboundSteps) (filterAttrs (_: route: builtins.elem trunk route.trunk && complete route) cfg.inbound);
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
          assertion = badKeys == [];
          message = "pbx.inbound: keys must be a number of digits, * and #, with an optional leading +; s, which takes the calls that name no number; or a pattern of such numbers that starts with _, such as _X.: ${concatMapStringsSep ", " (key: lib.showOption ["pbx" "inbound" key]) badKeys}.";
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
        {
          assertion = cfg.outbound == null || cfg.emergency != null;
          message = ''
            pbx.outbound is set but pbx.emergency is not, so an emergency number dialled from a phone goes out as a number outside, or nowhere: with the prefix 9, 911 reaches the trunk as 11. Add the emergency numbers where the PBX is, such as
              pbx.emergency.numbers = [ "911" ];
            which go out through pbx.outbound.trunk unless pbx.emergency.trunk names another, or, if this PBX makes no emergency calls,
              pbx.emergency.numbers = [ ];
          '';
        }
      ];
    }

    # Dial's b() option runs it on the call to the trunk before the INVITE
    # goes out, where the connected line is the caller ID Dial was given
    (mkIf (cfg.outbound != null && cfg.outbound.callerId != null || cfg.emergency != null && emergencyCallerId != null) {
      services.asterisk.dialplan.contexts.pbx-caller-id = {
        comment = mkDefault "from pbx.outbound and pbx.emergency: their caller ID in P-Asserted-Identity";
        extensions.s = [
          (pbxLib.app "Set" ["PJSIP_HEADER(add,P-Asserted-Identity)=<sip:\${CONNECTEDLINE(num)}@\${ARG1}>"])
          (pbxLib.app "Return" [])
        ];
      };
    })

    (mkIf (cfg.outbound != null) {
      services.asterisk.dialplan.contexts.pbx-outbound = {
        comment = mkDefault "from pbx.outbound";
        extensions."_${prefix}X." =
          setCallerId cfg.outbound.callerId
          ++ dialTrunk (["PJSIP/${numberAfterPrefix}@${cfg.outbound.trunk}"] ++ callerIdArguments cfg.outbound.callerId cfg.outbound.trunk);
      };

      assertions = [
        {
          assertion = dialOut == [];
          message = "pbx: calls from the trunk(s) ${concatMapStringsSep ", " (trunk: "${trunk} (${endpointContexts.${trunk}})") dialOut} start in a context that reaches pbx-outbound, so anyone who can call in through them can dial out, emergency numbers included. Give such a trunk a context without that, such as the pbx-inbound-<trunk> pbx gives it, or list it in pbx.tieLines if it connects another PBX whose callers may dial out.";
        }
      ];
    })

    (mkIf (cfg.emergency != null) {
      # without numbers there is nothing to dial, and without a trunk the
      # assertion below says so
      services.asterisk.dialplan.contexts = mkIf (cfg.emergency.numbers != [] && emergencyTrunk != null) {
        pbx-emergency = {
          comment = mkDefault "from pbx.emergency";
          extensions =
            genAttrs cfg.emergency.numbers (emergencySteps cfg.emergency)
            // optionalAttrs (cfg.emergency.notify != []) {
              # calls extension ARG1, unless it is the caller's own, as a page
              # leaves out the pager
              notify = [
                (pbxLib.app "GotoIf" [''$["''${CUT(CHANNEL,-,1)}" = "PJSIP/''${ARG1}"]?done''])
                # Originate() calls one channel, so a Local channel into
                # pbx-devices rings every device, for Originate()'s 30 s
                (pbxLib.app "Originate" [
                  "Local/\${ARG1}@pbx-devices"
                  "app"
                  "SayDigits"
                  "\${CALLERID(num)}"
                  ""
                  30
                  "acn"
                ])
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
          assertion = unknownNotify == [];
          message = "pbx.emergency.notify: ${concatStringsSep ", " unknownNotify} are not extensions of pbx.extensions.";
        }
        {
          assertion = cfg.emergency.numbers == [] || emergencyTrunk != null;
          message = "pbx.emergency: emergency calls need a trunk; set pbx.emergency.trunk, or pbx.outbound, whose trunk they then go out through.";
        }
      ];

      warnings = optional (cfg.emergency.numbers != [] && emergencyCallerId == null) "pbx.emergency: neither pbx.emergency.callerId nor pbx.outbound.callerId is set, so the provider decides which number emergency calls present. Set pbx.emergency.callerId to the number the site's address is registered with.";
    })
  ]);
}
