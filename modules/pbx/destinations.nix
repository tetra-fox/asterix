# every destination the pbx objects name must exist
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
    filter
    mapAttrsToList
    mkIf
    optional
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};

  mailboxes = map (box: "${box.mailbox}@${box.context}") (builtins.attrValues config.services.asterisk.voicemail.mailboxes);
  knownContexts = config.services.asterisk.dialplan.knownContexts;

  use = where: dest: optional (dest != null) {inherit where dest;};
  uses = concatLists [
    (concatLists (mapAttrsToList (number: e: use ''pbx.extensions."${number}".noAnswer'' e.noAnswer ++ use ''pbx.extensions."${number}".busy'' e.busy) cfg.extensions))
    (concatLists (mapAttrsToList (name: group: use "pbx.ringGroups.${name}.noAnswer" group.noAnswer) cfg.ringGroups))
    (concatLists (mapAttrsToList (name: queue: use "pbx.queues.${name}.noAnswer" queue.noAnswer) cfg.queues))
    (concatLists (mapAttrsToList (number: route: concatMap (field: use ''pbx.inbound."${number}".${field}'' route.${field}) ["destination" "open" "closed"]) cfg.inbound))
    (concatLists (mapAttrsToList (name: ivr:
      concatLists (mapAttrsToList (key: use ''pbx.ivrs.${name}.options."${key}"'') ivr.options)
      ++ use "pbx.ivrs.${name}.noInput" ivr.noInput
      ++ use "pbx.ivrs.${name}.invalid" ivr.invalid)
    cfg.ivrs))
  ];

  exists = dest:
    if dest ? extension
    then cfg.extensions ? ${dest.extension}
    else if dest ? ringGroup
    then cfg.ringGroups ? ${dest.ringGroup}
    else if dest ? queue
    then cfg.queues ? ${dest.queue}
    else if dest ? conference
    then cfg.conferences ? ${dest.conference}
    else if dest ? ivr
    then cfg.ivrs ? ${dest.ivr}
    else if dest ? voicemail
    then let
      box = pbxLib.splitMailbox dest.voicemail.mailbox;
    in
      builtins.elem "${box.box}@${box.context}" mailboxes
    else if dest ? context
    then knownContexts == null || builtins.elem dest.context.context knownContexts
    else true;

  missing = filter (u: !(exists u.dest)) uses;
in {
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [];
        message = ''
          pbx: destinations that do not exist:
            ${concatMapStringsSep "\n  " (u: "${u.where}: ${pbxLib.describe u.dest}") missing}
        '';
      }
    ];
  };
}
