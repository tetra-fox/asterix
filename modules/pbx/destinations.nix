# every destination the pbx objects name must exist, and none may lead back
# to its own object without a key press
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
  inherit (import ../lib.nix {inherit lib;}) splitMailbox voicemailMailboxes;

  knownMailboxes = voicemailMailboxes config.services.asterisk;
  # VoiceMail() takes the context in any case, or any context with
  # searchcontexts, but files the message under the mailbox as dialed
  # (apps/app_voicemail.c find_user and leave_voicemail), and reaches no
  # mailbox through an alias: find_user swaps the alias's mailbox and context
  reachesMailbox = mailbox: let
    ref = splitMailbox mailbox;
    contexts = builtins.filter (context: knownMailboxes.search || lib.toLower context == lib.toLower ref.context) (builtins.attrNames knownMailboxes.contexts);
  in
    knownMailboxes == null || builtins.any (context: knownMailboxes.contexts.${context} ? ${ref.box}) contexts;
  knownContexts = config.services.asterisk.dialplan.knownContexts;

  # `from` names the object a call leaves through the slot without a key
  # press, as pbxLib.describe names a destination, or is null
  use = where: from: dest: optional (dest != null) {inherit where from dest;};
  uses = concatLists [
    (concatLists (mapAttrsToList (number: e: use ''pbx.extensions."${number}".noAnswer'' "extension ${number}" e.noAnswer ++ use ''pbx.extensions."${number}".busy'' "extension ${number}" e.busy) cfg.extensions))
    (concatLists (mapAttrsToList (name: group: use "pbx.ringGroups.${name}.noAnswer" "ringGroup ${name}" group.noAnswer) cfg.ringGroups))
    (concatLists (mapAttrsToList (name: queue: use "pbx.queues.${name}.noAnswer" "queue ${name}" queue.noAnswer) cfg.queues))
    (concatLists (mapAttrsToList (number: route: concatMap (field: use ''pbx.inbound."${number}".${field}'' null route.${field}) ["destination" "open" "closed"]) cfg.inbound))
    (concatLists (mapAttrsToList (name: ivr:
      concatLists (mapAttrsToList (key: use ''pbx.ivrs.${name}.options."${key}"'' null) ivr.options)
      ++ use "pbx.ivrs.${name}.noInput" "ivr ${name}" ivr.noInput
      ++ use "pbx.ivrs.${name}.invalid" null ivr.invalid)
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
    then reachesMailbox dest.voicemail.mailbox
    else if dest ? context
    then knownContexts == null || builtins.elem dest.context.context knownContexts
    else true;

  missing = filter (u: !(exists u.dest)) uses;

  # the objects a call goes on to without a key press; a slot that leads back
  # to its own object sends the call round until the caller hangs up
  onward = lib.groupBy (u: u.from) (filter (u: u.from != null) uses);
  reached = object:
    map (o: o.key) (builtins.genericClosure {
      startSet = [{key = object;}];
      operator = o: map (u: {key = pbxLib.describe u.dest;}) (onward.${o.key} or []);
    });
  loops = filter (u: u.from != null && builtins.elem u.from (reached (pbxLib.describe u.dest))) uses;
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
      {
        assertion = loops == [];
        message = ''
          pbx: destinations that lead back to their own object without a key press, so a call goes round until the caller hangs up:
            ${concatMapStringsSep "\n  " (u: "${u.where}: ${pbxLib.describe u.dest}") loops}
          Send one of them elsewhere, such as to voicemail; a voice menu's options and invalid key may lead back, since the caller presses a key for those.
        '';
      }
    ];
  };
}
