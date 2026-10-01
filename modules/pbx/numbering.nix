# pbx-internal, the context the phones of pbx.extensions dial from: every
# number the pbx objects have, each with exactly one owner, and busy lamp
# hints.
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

  cfg = config.pbx;
  core = config.services.asterisk;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;

  gotoAt = context: extension: pbxLib.app "Goto" [context extension "1"];

  numbered = option: kind:
    concatLists (mapAttrsToList (name: object:
      optional (object.number != null) {
        inherit (object) number;
        owner = "pbx.${option}.${name}";
        steps = [(pbxLib.goto (pbxLib.objectContext kind name))];
      })
    cfg.${option});

  prefixed = number: optional (cfg.outbound != null && cfg.outbound.prefix != "") (cfg.outbound.prefix + number);

  numbers =
    mapAttrsToList (number: _: {
      inherit number;
      owner = ''pbx.extensions."${number}"'';
      steps = [(pbxLib.goto (pbxLib.objectContext "extension" number))];
    })
    cfg.extensions
    ++ numbered "ringGroups" "ringgroup"
    ++ numbered "queues" "queue"
    ++ numbered "conferences" "conference"
    ++ numbered "ivrs" "ivr"
    ++ numbered "paging" "paging"
    ++ optional (cfg.voicemailMenu != null) {
      number = cfg.voicemailMenu;
      owner = "pbx.voicemailMenu";
      steps = [
        (pbxLib.app "Answer" [])
        (pbxLib.app "VoiceMailMain" ["\${CALLERID(num)}@default"])
        (pbxLib.app "Hangup" [])
      ];
    }
    ++ concatLists (mapAttrsToList (name: hours:
      optional (hours.closeEarly != null) {
        number = hours.closeEarly;
        owner = "pbx.hours.${name}.closeEarly";
        steps = [(gotoAt (pbxLib.objectContext "hours" name) "toggle")];
      })
    cfg.hours)
    ++ optionals (cfg.emergency != null) (concatMap (
        number:
          map (dialled: {
            number = dialled;
            owner =
              if dialled == number
              then "pbx.emergency.numbers"
              else "pbx.emergency.numbers (${number} after pbx.outbound.prefix)";
            steps = [(gotoAt "pbx-emergency" number)];
          }) ([number] ++ prefixed number)
      )
      cfg.emergency.numbers);

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
      owner = ''pbx.inbound."${number}"'';
    })
    cfg.inbound
  ));

  generated = listToAttrs (map (n: nameValuePair n.number n.steps) numbers);
in {
  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts.pbx-internal = {
      comment = mkDefault "from pbx: what the phones of pbx.extensions dial";
      includes = optional (cfg.outbound != null) "pbx-outbound";
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
          pbx: numbers with more than one owner:
            ${concatStringsSep "\n  " (mapAttrsToList (number: owners: "${number}: ${concatMapStringsSep ", " (n: n.owner) owners}") clashes)}
        '';
      }
      {
        assertion = malformed == [];
        message = "pbx: numbers may only contain digits, * and #: ${concatMapStringsSep ", " (n: "${n.number} (${n.owner})") malformed}.";
      }
      {
        assertion = pickedUp == [];
        message = "pbx: chan_pjsip takes a call to ${pickupExten}, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches ${concatStringsSep ", " pickedUp}. Use another number, or change services.asterisk.features.general.pickupexten.";
      }
    ];
  };
}
