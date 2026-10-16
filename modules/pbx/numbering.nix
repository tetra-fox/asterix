# pbx-internal, the context the phones of services.asterix.extensions dial
# from: every number the pbx objects have, each with exactly one owner, and
# busy lamp hints. Also pbx-forward, the numbers a call forward of
# services.asterix.featureCodes may go to, and pbx-forward-refused, the
# numbers of pbx-forward that phones dialling them reach another way.
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
    filter
    filterAttrs
    length
    listToAttrs
    mapAttrsToList
    mkDefault
    mkIf
    nameValuePair
    optional
    optionals
    ;

  cfg = config.services.asterix;
  core = config.services.asterisk;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;

  gotoAt = context: extension: pbxLib.app "Goto" [context extension "1"];

  numbered = option: kind:
    concatLists (mapAttrsToList (name: object:
      optional (object.number != null) {
        inherit (object) number;
        owner = "services.asterix.${option}.${name}";
        steps = [(pbxLib.goto (pbxLib.objectContext kind name))];
      })
    cfg.${option});

  codes = cfg.featureCodes;
  kinds = builtins.attrNames pbxLib.forwardSounds;
  # the forwards whose codes are set, with the code that sets them
  forwardOn = lib.filterAttrs (_: code: code != null) (lib.genAttrs kinds (kind: codes.forward.${kind}.on));
  # a phone dials the number to forward to right after the code
  forwardPatterns = lib.mapAttrs' (kind: code:
    nameValuePair "_${code}." [
      (pbxLib.app "Set" ["PBX_TARGET=\${EXTEN:${toString (builtins.stringLength code)}}"])
      (gotoAt "pbx-features" "${kind}-on")
    ])
  forwardOn;

  prefixed = number: optional (cfg.outbound != null && cfg.outbound.prefix != "") (cfg.outbound.prefix + number);

  numbers =
    mapAttrsToList (number: _: {
      inherit number;
      owner = ''services.asterix.extensions."${number}"'';
      steps = [(pbxLib.goto (pbxLib.objectContext "extension" number))];
    })
    cfg.extensions
    ++ numbered "ringGroups" "ringgroup"
    ++ numbered "queues" "queue"
    ++ numbered "conferences" "conference"
    ++ numbered "announcements" "announcement"
    ++ numbered "ivrs" "ivr"
    ++ numbered "paging" "paging"
    ++ optional (cfg.voicemailMenu != null) {
      number = cfg.voicemailMenu;
      owner = "services.asterix.voicemailMenu";
      steps = [
        (pbxLib.app "Answer" [])
        (pbxLib.app "VoiceMailMain" ["\${CALLERID(num)}@default"])
        (pbxLib.app "Hangup" [])
      ];
    }
    ++ concatLists (mapAttrsToList (name: hours:
      optional (hours.closeEarly != null) {
        number = hours.closeEarly;
        owner = "services.asterix.hours.${name}.closeEarly";
        steps = [(gotoAt (pbxLib.objectContext "hours" name) "toggle")];
      })
    cfg.hours)
    ++ optional (codes.dnd != null) {
      number = codes.dnd;
      owner = "services.asterix.featureCodes.dnd";
      steps = [(gotoAt "pbx-features" "dnd")];
    }
    ++ concatMap (kind:
      concatMap (state:
        optional (codes.forward.${kind}.${state} != null) {
          number = codes.forward.${kind}.${state};
          owner = "services.asterix.featureCodes.forward.${kind}.${state}";
          steps = [(gotoAt "pbx-features" "${kind}-${state}")];
        }) ["on" "off"])
    kinds
    ++ optionals (cfg.emergency != null) (concatMap (
        number:
          map (dialled: {
            number = dialled;
            owner =
              if dialled == number
              then "services.asterix.emergency.numbers"
              else "services.asterix.emergency.numbers (${number} after services.asterix.outbound.prefix)";
            steps = [(gotoAt "pbx-emergency" number)];
          }) ([number] ++ prefixed number)
      )
      cfg.emergency.numbers)
    # res_parking adds these to pbx-parking, so they have no steps here
    ++ optionals (cfg.parking != null) (
      [
        {
          inherit (cfg.parking) number;
          owner = "services.asterix.parking.number";
        }
      ]
      ++ map (slot: {
        number = slot;
        owner = "services.asterix.parking.slots (${slot})";
      }) (pbxLib.parkingSlots cfg.parking)
    );

  clashes = filterAttrs (_: owners: length owners > 1) (builtins.groupBy (n: n.number) numbers);
  malformed = filter (n: builtins.match "[0-9*#]+" n.number == null) numbers;

  # chan_pjsip takes a call to pickupexten, *8 unless set, as a call pickup
  # before the dialplan runs; null when features.conf has includes or raw text
  pickupExten = let
    general = filter (s: s.name == "general") (format.resolveInheritance (core.settings."features.conf" or {})).sections;
    values = concatMap (s: lib.toList (s.pickupexten or [])) general;
  in
    if core.includes."features.conf" or [] != [] || core.extraConfig."features.conf" or "" != ""
    then null
    else if values == []
    then "*8"
    else toString (lib.last values);
  pickedUp = map (n: n.owner) (filter (n: n.number == pickupExten) (
    numbers
    ++ mapAttrsToList (number: _: {
      inherit number;
      owner = ''services.asterix.inbound."${number}"'';
    })
    cfg.inbound
  ));

  # a number that starts with a forward code reaches its owner, so a phone
  # cannot forward to what follows the code
  afterCode = filter (n: builtins.any (code: n.number != code && lib.hasPrefix code n.number) (builtins.attrValues forwardOn)) (
    numbers
    ++ optional (pickupExten != null) {
      number = pickupExten;
      owner = "the pickupexten of features.conf";
    }
  );

  generated = listToAttrs (map (n: nameValuePair n.number n.steps) (filter (n: n ? steps) numbers)) // forwardPatterns;
in {
  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts.pbx-forward = mkIf (forwardOn != {}) {
      comment = mkDefault "from services.asterix.featureCodes: the numbers a call forward may go to";
      includes = optional (cfg.outbound != null) "pbx-outbound";
      extensions = lib.mapAttrs (number: _: [(pbxLib.goto (pbxLib.objectContext "extension" number))]) cfg.extensions;
    };

    # the other numbers phones dial, which pbx-outbound may also take. A
    # forward's number is checked against it, no call enters it.
    services.asterisk.dialplan.contexts.pbx-forward-refused = mkIf (forwardOn != {}) {
      comment = mkDefault "from services.asterix.featureCodes: the numbers a call forward may not go to";
      extensions = lib.genAttrs (
        map (n: n.number) (filter (n: !(cfg.extensions ? ${n.number})) numbers)
        ++ optional (pickupExten != null) pickupExten
        ++ builtins.attrNames forwardPatterns
      ) (_: [(pbxLib.app "Hangup" [])]);
    };

    services.asterisk.dialplan.contexts.pbx-internal = {
      comment = mkDefault "from services.asterix: what the phones of services.asterix.extensions dial";
      # pbx-parking before the patterns of pbx-outbound, which could match
      # its numbers
      includes = optional (cfg.parking != null) "pbx-parking" ++ optional (cfg.outbound != null) "pbx-outbound";
      extensions = generated;
      hints = lib.mapAttrs (_: mkDefault) (
        lib.mapAttrs (number: _: "PJSIP/${number}") cfg.extensions
        // listToAttrs (concatLists (mapAttrsToList (name: hours:
          optional (hours.closeEarly != null) (nameValuePair hours.closeEarly "Custom:${pbxLib.objectContext "hours" name}"))
        cfg.hours))
      );
    };

    assertions = [
      {
        assertion = clashes == {};
        message = ''
          services.asterix: numbers with more than one owner:
            ${concatStringsSep "\n  " (mapAttrsToList (number: owners: "${number}: ${concatMapStringsSep ", " (n: n.owner) owners}") clashes)}
        '';
      }
      {
        assertion = malformed == [];
        message = "services.asterix: numbers may only contain digits, * and #: ${concatMapStringsSep ", " (n: "${n.number} (${n.owner})") malformed}.";
      }
      {
        assertion = afterCode == [];
        message = "services.asterix: numbers that start with a code of services.asterix.featureCodes.forward, after which phones dial the number to forward to, so a phone cannot forward to the rest of them: ${concatMapStringsSep ", " (n: "${n.number} (${n.owner})") afterCode}.";
      }
      {
        assertion = pickedUp == [];
        message = "services.asterix: chan_pjsip takes a call to ${pickupExten}, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches ${concatStringsSep ", " pickedUp}. Use another number, or change services.asterisk.features.general.pickupexten.";
      }
    ];
  };
}
