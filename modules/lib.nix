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
in {
  inherit splitMailbox voicemailLines entryOf;

  # the mailboxes of voicemail.conf, as { context = { box = true; }; }: the
  # keys of each context in the rendered file, raw text included, or null
  # when the file includes others, which can hold any mailbox
  voicemailMailboxes = core: let
    entries = lib.concatMap (
      line: let
        entry = entryOf line.line;
      in
        lib.optional (entry != null) {
          inherit (line) section;
          inherit (entry) key;
        }
    ) (voicemailLines (core.renderedFiles."voicemail.conf" or ""));
  in
    if
      format.includesFiles {
        includes = core.includes."voicemail.conf" or [];
        extraConfig = core.extraConfig."voicemail.conf" or "";
      }
    then null
    else lib.mapAttrs (_: boxes: lib.genAttrs (map (e: e.key) boxes) (_: true)) (builtins.groupBy (e: e.section) entries);

  # whether `mailbox`, `200` or `200@sales`, is one of `mailboxes`, as
  # voicemailMailboxes makes them
  hasMailbox = mailboxes: mailbox: let
    ref = splitMailbox mailbox;
  in
    mailboxes == null || (mailboxes.${ref.context} or {}) ? ${ref.box};

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
