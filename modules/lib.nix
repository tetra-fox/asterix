# Helpers the modules share. Unlike ../lib, they are not part of the flake's
# lib or config.lib.asterisk.
{lib}: let
  format = import ../lib/format.nix {inherit lib;};

  # `200` or `200@sales` as the mailbox and its voicemail context
  splitMailbox = mailbox: let
    parts = lib.splitString "@" mailbox;
  in {
    box = builtins.head parts;
    context =
      if builtins.length parts > 1
      then builtins.elemAt parts 1
      else "default";
  };

  # the lines of a voicemail.conf text after its first section header, each
  # with its section
  voicemailLines = text:
    (lib.foldl' (
        acc: line: let
          header = builtins.match "[[:space:]]*[[]([^]]*)[]].*" line;
        in
          if header != null
          then acc // {section = builtins.head header;}
          else if acc.section != null
          then
            acc
            // {
              lines =
                acc.lines
                ++ [
                  {
                    inherit (acc) section;
                    inherit line;
                  }
                ];
            }
          else acc
      ) {
        section = null;
        lines = [];
      }
      (lib.splitString "\n" text))
    .lines;

  # what Asterisk reads of a line: up to a `;` that is not `\;`, split at the
  # first `=` or `=>`
  entryOf = line: let
    parts = builtins.match "([^=]*)=>?(.*)" (builtins.head (builtins.match "((\\\\;|[^;])*).*" line));
  in
    if parts == null
    then null
    else {
      key = lib.trim (builtins.head parts);
      value = lib.trim (builtins.elemAt parts 1);
    };

  # what app_voicemail takes a section of voicemail.conf for, by its name in
  # any case: `general`, `zonemessages`, `aliases` for the one aliasescontext
  # of `lines` names, or else `context` (apps/app_voicemail.c load_users)
  voicemailSectionKind = lines: let
    # the last aliasescontext of [general], the one app_voicemail reads
    aliases = lib.toLower (lib.foldl' (
        value: line: let
          entry = entryOf line.line;
        in
          if lib.toLower line.section == "general" && entry != null && lib.toLower entry.key == "aliasescontext"
          then entry.value
          else value
      ) ""
      lines);
  in
    name: let
      lower = lib.toLower name;
    in
      if builtins.elem lower ["general" "zonemessages"]
      then lower
      else if aliases != "" && lower == aliases
      then "aliases"
      else "context";
in {
  inherit splitMailbox voicemailLines entryOf voicemailSectionKind;

  # the mailboxes of voicemail.conf, as { contexts.<context>.<box> = true;
  # aliases."<box>@<context>" = true; }, raw text included, or null when the
  # file includes others, which can hold any mailbox
  voicemailMailboxes = core: let
    lines = voicemailLines (core.renderedFiles."voicemail.conf" or "");
    kindOf = voicemailSectionKind lines;
    entries =
      lib.concatMap (
        line: let
          entry = entryOf line.line;
        in
          lib.optional (entry != null) {
            inherit (line) section;
            inherit (entry) key;
            kind = kindOf line.section;
          }
      )
      lines;
    ofKind = kind: builtins.filter (e: e.kind == kind) entries;
  in
    if
      format.includesFiles {
        includes = core.includes."voicemail.conf" or [];
        extraConfig = core.extraConfig."voicemail.conf" or "";
      }
    then null
    else {
      contexts = lib.mapAttrs (_: boxes: lib.genAttrs (map (e: e.key) boxes) (_: true)) (builtins.groupBy (e: e.section) (ofKind "context"));
      aliases = lib.genAttrs (map (e: let
        ref = splitMailbox e.key;
      in "${ref.box}@${ref.context}") (ofKind "aliases")) (_: true);
    };

  # typed option values as section keys: scalars become defaults, so settings
  # replace them, lists stay definitions, so settings extend them, and nulls
  # are dropped
  toSection = attrs:
    lib.mapAttrs (_: v:
      if lib.isList v
      then v
      else lib.mkDefault v) (lib.filterAttrs (_: v: v != null) attrs);

  settingsOption = what:
    lib.mkOption {
      type = lib.types.attrsOf format.types.value;
      default = {};
      description = ''
        Additional keys for the generated ${what} section. They take
        precedence over single values generated from the typed options and
        extend generated lists.
      '';
    };

  # networking.firewall settings opening `ports` on `interfaces`, or on every
  # interface when the list is empty
  firewallOn = interfaces: ports:
    if interfaces == []
    then ports
    else {interfaces = lib.genAttrs interfaces (_: ports);};

  # the names in `interfaces` that Linux refuses for an interface: it takes 1
  # to 15 bytes without /, : or whitespace, other than . and .. (net/core/dev.c
  # dev_valid_name)
  invalidInterfaces = builtins.filter (name: builtins.match "[^/:[:space:]]{1,15}" name == null || name == "." || name == "..");
}
