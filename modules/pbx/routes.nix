# services.asterix.inbound, services.asterix.outbound and
# services.asterix.emergency: calls between the phones and trunks. Calls from
# a trunk start in pbx-inbound-<trunk>, which holds its numbers of
# services.asterix.inbound.
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

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;

  inboundType = types.submodule {
    options = {
      trunk = mkOption {
        type = types.coercedTo types.str lib.toList (types.nonEmptyListOf types.str);
        example = "provider";
        description = ''
          Trunk of {option}`services.asterix.trunks` the number's calls
          arrive on, or a list of them.
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
        description = "Opening hours of {option}`services.asterix.hours` that choose between `open` and `closed`.";
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
      blocklist = mkOption {
        type = types.bool;
        default = true;
        description = "Whether {option}`services.asterix.blocklist` turns away callers to this number.";
      };
      record = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to record calls to this number from when they are answered, wherever they go. See {option}`services.asterix.recordings`.";
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
          leaves. The number outside has two digits or more. When empty, every
          such number that no number of the PBX takes goes out, mistyped
          extensions included. A number of the PBX or a call pickup code
          (`pickupexten` of features.conf) that starts with the prefix wins:
          with `9`, a ring group on 900 means 00 outside cannot be dialled, and
          a pickup code of `981` means 81 cannot.
        '';
      };
      trunk = mkOption {
        type = types.str;
        description = "Trunk of {option}`services.asterix.trunks` calls go out through.";
      };
      callerId = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "5551000";
        description = ''
          Number presented to the called party, on calls out and to the
          external numbers of ring groups. It is sent in P-Asserted-Identity,
          since the From header keeps naming the trunk's account. A provider
          that ignores that header shows the account's number. When null, the
          trunk decides.
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
          Emergency numbers where the PBX is, dialled with or without the
          outbound prefix. An empty list says the PBX makes no emergency calls.
          An emergency number then goes out as a number outside, or reaches
          nothing.
        '';
      };
      trunk = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = lib.literalExpression "config.services.asterix.outbound.trunk";
        description = "Trunk of {option}`services.asterix.trunks` emergency calls go out through.";
      };
      callerId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Number presented to the emergency service, usually the one the
          site's address is registered with. When null, emergency calls present
          {option}`services.asterix.outbound.callerId`.
        '';
      };
      notify = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["201"];
        description = ''
          Extensions called at the same time, which hear the caller's
          number, for example the front desk. The caller's own extension is
          left out, with all of its devices.
        '';
      };
    };
  };

  hasHours = route: route.hours != null || route.open != null || route.closed != null;
  complete = route:
    if route.destination != null
    then !(hasHours route)
    else route.hours != null && route.open != null && route.closed != null;

  inherit (cfg) trunks;
  inboundTrunks = unique (concatMap (route: route.trunk) (builtins.attrValues cfg.inbound));
  # trunks whose calls start in pbx-inbound-<trunk>
  pbxTrunks = builtins.attrNames (filterAttrs (name: trunk: trunk.context == pbxLib.objectContext "inbound" name) trunks);

  # pbx-blocklist (blocklist.nix) returns `blocked` for a caller the
  # blocklist turns away
  blocklistSteps = route:
    lib.optionals (route.blocklist && pbxLib.blocksCallers cfg.blocklist) [
      (pbxLib.app "Gosub" ["pbx-blocklist" "s" "1"])
      (pbxLib.app "GotoIf" [''$["''${GOSUB_RETVAL}" = "blocked"]?pbx-blocklist,blocked,1''])
    ];

  # the number the trunk sent, for file names
  dialled = "\${FILTER(0-9*#+,\${EXTEN})}";

  inboundSteps = route:
    blocklistSteps route
    ++ lib.optionals route.record (pbxLib.recordCall cfg true false dialled)
    ++ (
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
        ++ pbxLib.labelled "open" route.open
    );

  setCallerId = callerId: optional (callerId != null) (pbxLib.app "Set" ["CALLERID(num)=${callerId}"]);

  # an emergency call presents the site's number, not the caller's extension
  emergencyCallerId =
    if cfg.emergency.callerId != null
    then cfg.emergency.callerId
    else if cfg.outbound != null
    then cfg.outbound.callerId
    else null;

  # Dial's option for a call that presents `callerId`; an assertion below
  # reports a trunk that does not exist
  callerIdOption = callerId: trunk: lib.optionalString (callerId != null && trunks ? ${trunk}) (pbxLib.callerIdOption trunks.${trunk});

  # a call the trunk does not put through, as to a provider that does not
  # answer, ends with congestion (503), which phones play as a fast busy; a
  # busy one keeps the busy cause Dial left on the channel (486)
  dialTrunk = channel: options: [
    (pbxLib.app "Dial" ([channel] ++ lib.optionals (options != "") ["" options]))
    (pbxLib.app "GotoIf" [''$["''${DIALSTATUS}" = "BUSY"]?busy''])
    (pbxLib.app "Congestion" [])
    {
      app = "Hangup";
      args = [];
      label = "busy";
    }
  ];

  # with recordings.emergency, recorded from the answer with no notice to
  # hold the call up, under the caller's number rather than the site's
  emergencySteps = e: number:
    map (extension: pbxLib.app "Gosub" ["notify" "1(${extension})"]) e.notify
    ++ lib.optionals cfg.recordings.emergency ([(pbxLib.app "Set" ["__PBX_RECORD=1"])] ++ pbxLib.recordCall cfg false false number)
    ++ setCallerId emergencyCallerId
    ++ dialTrunk "PJSIP/${number}@${emergencyTrunk}" (
      callerIdOption emergencyCallerId emergencyTrunk
      + lib.optionalString cfg.recordings.emergency (pbxLib.recordOptions cfg {
        called = false;
        calling = false;
      })
    );

  # emergency calls without a trunk of their own go out through
  # services.asterix.outbound's
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
      where = "services.asterix.outbound.trunk";
      inherit (cfg.outbound) trunk;
    }
    ++ optional (cfg.emergency != null && cfg.emergency.trunk != null) {
      where = "services.asterix.emergency.trunk";
      inherit (cfg.emergency) trunk;
    };
  trunkUses =
    concatLists (mapAttrsToList (number: route:
      map (trunk: {
        where = ''services.asterix.inbound."${number}".trunk'';
        inherit trunk;
      })
      route.trunk)
    cfg.inbound)
    ++ outboundTrunkUses
    ++ map (trunk: {
      where = "services.asterix.tieLines";
      inherit trunk;
    })
    cfg.tieLines;
  unknownTrunks = builtins.filter (use: !(trunks ? ${use.trunk})) trunkUses;
  # trunks pbx dials as PJSIP/<number>@<trunk>; a ring group without a trunk
  # of its own uses services.asterix.outbound's
  badTrunkNames = builtins.filter (use: pbxLib.breaksDialString use.trunk) (
    outboundTrunkUses
    ++ mapAttrsToList (name: group: {
      where = "services.asterix.ringGroups.${name}.trunk";
      inherit (group) trunk;
    }) (filterAttrs (_: group: group.external != [] && group.trunk != null) cfg.ringGroups)
  );

  badKeys = builtins.filter (key: builtins.match "${pbxLib.numberOrPattern}|s" key == null) (builtins.attrNames cfg.inbound);
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
  # trunks of the core, the layer's among them, whose callers can dial out
  # through services.asterix.outbound with no menu in between, as from
  # pbx-internal, which includes pbx-outbound
  dialOut = builtins.filter (trunk: !(builtins.elem trunk cfg.tieLines) && endpointContexts ? ${trunk} && endpointContexts.${trunk} != null && reachesOutbound endpointContexts.${trunk}) (builtins.attrNames config.services.asterisk.pjsip.trunks);
in {
  options.services.asterix = {
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
        Numbers calls arrive at from trunks, and where their calls go:
        `destination`, or `hours` with `open` and `closed`. Other numbers are
        rejected.

        A key is the user part of the Request-URI (not the To header). It is a
        number of digits, `*` and `#` with an optional leading `+`, a pattern
        such as `_X.` for any number, or `s`. `s` takes the calls that name no
        number: those to the address a trunk registered, unless its
        `registration.contactUser` gives that a number, and those whose
        Request-URI has no user part. A call to the call pickup code
        (`pickupexten` of features.conf) is taken as a pickup even when a
        pattern matches it.
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
        call the trunk does not put through ends with congestion, a fast busy,
        and a busy answer stays busy. A provider that does not answer fails a
        call when its INVITE times out after 32 s, and at once after the
        trunk's next qualify (`qualifyFrequency`).

        Requires {option}`services.asterix.emergency`, with no numbers if the
        PBX makes no emergency calls. Otherwise 911 would go out as 11 with
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
        Emergency calls, required by {option}`services.asterix.outbound`.
        There are no defaults, since the numbers and who must be told depend
        on where the PBX is. A call waits for the trunk as long as it takes,
        and one the trunk does not put through ends with congestion.
      '';
    };

    tieLines = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Trunks of {option}`services.asterix.trunks` that connect another
        PBX, whose callers may dial out through
        {option}`services.asterix.outbound`. Any other trunk whose calls start
        in a context that reaches `pbx-outbound`, as `pbx-internal` does,
        fails evaluation, since anyone calling in through it could dial out.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.asterisk.dialplan.contexts = lib.listToAttrs (map (trunk:
        lib.nameValuePair (pbxLib.objectContext "inbound" trunk) {
          comment = mkDefault "from services.asterix.inbound: calls from trunk ${trunk}";
          # an incomplete number has no steps, the assertion below names it
          extensions = mapAttrs (_: inboundSteps) (filterAttrs (_: route: builtins.elem trunk route.trunk && complete route) cfg.inbound);
        })
      pbxTrunks);

      assertions = [
        {
          assertion = builtins.all complete (builtins.attrValues cfg.inbound);
          message = "services.asterix.inbound: ${
            concatStringsSep ", " (builtins.attrNames (filterAttrs (_: route: !(complete route)) cfg.inbound))
          } need either `destination`, or `hours` with `open` and `closed`.";
        }
        {
          assertion = badKeys == [];
          message = "services.asterix.inbound: keys must be a number of digits, * and #, with an optional leading +; s, which takes the calls that name no number; or a pattern of such numbers that starts with _, such as _X.: ${concatMapStringsSep ", " (key: lib.showOption ["services" "asterix" "inbound" key]) badKeys}.";
        }
        {
          assertion = unknownHours == [];
          message = "services.asterix.inbound: ${concatStringsSep ", " unknownHours} use hours that are not defined in services.asterix.hours.";
        }
        {
          assertion = unknownTrunks == [];
          message = ''
            services.asterix: trunks that are not defined in services.asterix.trunks:
              ${concatMapStringsSep "\n  " (use: "${use.where}: ${use.trunk}") unknownTrunks}
          '';
        }
        {
          assertion = badTrunkNames == [];
          message = ''
            services.asterix: trunk names that Asterisk would misread in a dial string (they may not contain , ; [ ] " \ ''${ $[ & / or an unclosed parenthesis):
              ${concatMapStringsSep "\n  " (use: "${use.where}: ${use.trunk}") badTrunkNames}
          '';
        }
        {
          assertion = foreignContexts == [];
          message = "services.asterix.inbound: the trunk(s) ${concatStringsSep ", " foreignContexts} have a context of their own, so their calls do not reach services.asterix.inbound; remove it.";
        }
        {
          assertion = cfg.outbound == null || cfg.emergency != null;
          message = ''
            services.asterix.outbound is set but services.asterix.emergency is not, so an emergency number dialled from a phone goes out as a number outside, or nowhere: with the prefix 9, 911 reaches the trunk as 11. Add the emergency numbers where the PBX is, such as
              services.asterix.emergency.numbers = [ "911" ];
            which go out through services.asterix.outbound.trunk unless services.asterix.emergency.trunk names another, or, if this PBX makes no emergency calls,
              services.asterix.emergency.numbers = [ ];
          '';
        }
      ];
    }

    # Dial's b() option runs it on the call to the trunk before the INVITE
    # goes out, where the connected line is the caller ID Dial was given
    (mkIf (cfg.outbound != null && cfg.outbound.callerId != null || cfg.emergency != null && emergencyCallerId != null) {
      services.asterisk.dialplan.contexts.pbx-caller-id = {
        comment = mkDefault "from services.asterix.outbound and services.asterix.emergency: their caller ID in P-Asserted-Identity";
        extensions.s = [
          (pbxLib.app "Set" ["PJSIP_HEADER(add,P-Asserted-Identity)=<sip:\${CONNECTEDLINE(num)}@\${ARG1}>"])
          (pbxLib.app "Return" [])
        ];
      };
    })

    (mkIf (cfg.outbound != null) {
      services.asterisk.dialplan.contexts.pbx-outbound = {
        comment = mkDefault "from services.asterix.outbound";
        extensions."_${prefix}X." =
          # before the caller ID changes, which names the caller in file names
          pbxLib.recordCall cfg false false "\${FILTER(0-9*#+,${numberAfterPrefix})}"
          ++ setCallerId cfg.outbound.callerId
          ++ dialTrunk "PJSIP/${numberAfterPrefix}@${cfg.outbound.trunk}" (callerIdOption cfg.outbound.callerId cfg.outbound.trunk
            + pbxLib.recordOptions cfg {
              called = false;
              calling = true;
            });
      };

      assertions = [
        {
          assertion = dialOut == [];
          message = "services.asterix: calls from the trunk(s) ${concatMapStringsSep ", " (trunk: "${trunk} (${endpointContexts.${trunk}})") dialOut} start in a context that reaches pbx-outbound, so anyone who can call in through them can dial out, emergency numbers included. Give such a trunk a context without that, such as the pbx-inbound-<trunk> the layer gives it, or list it in services.asterix.tieLines if it connects another PBX whose callers may dial out.";
        }
      ];
    })

    (mkIf (cfg.emergency != null) {
      # without numbers there is nothing to dial, and without a trunk the
      # assertion below says so
      services.asterisk.dialplan.contexts = mkIf (cfg.emergency.numbers != [] && emergencyTrunk != null) {
        pbx-emergency = {
          comment = mkDefault "from services.asterix.emergency";
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
          message = "services.asterix.emergency.notify: ${concatStringsSep ", " unknownNotify} are not extensions of services.asterix.extensions.";
        }
        {
          assertion = cfg.emergency.numbers == [] || emergencyTrunk != null;
          message = "services.asterix.emergency: emergency calls need a trunk; set services.asterix.emergency.trunk, or services.asterix.outbound, whose trunk they then go out through.";
        }
      ];

      warnings = optional (cfg.emergency.numbers != [] && emergencyCallerId == null) "services.asterix.emergency: neither services.asterix.emergency.callerId nor services.asterix.outbound.callerId is set, so the provider decides which number emergency calls present. Set services.asterix.emergency.callerId to the number the site's address is registered with.";
    })
  ]);
}
