# Helpers the modules share. Unlike ../lib, they are not part of the flake's
# lib or config.lib.asterisk.
{lib}: let
  format = import ../lib/format.nix {inherit lib;};
  secrets = import ../lib/secrets.nix {inherit lib;};

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

  # the value app_voicemail reads of `key`, in lower case, from the [general]
  # of voicemail.conf's `lines`: the last one of the sections called general
  # in any case, or null
  voicemailGeneral = lines: key:
    lib.foldl' (
      value: line: let
        entry = entryOf line.line;
      in
        if lib.toLower line.section == "general" && entry != null && lib.toLower entry.key == key
        then entry.value
        else value
    )
    null
    lines;

  # what app_voicemail takes a section of voicemail.conf for, by its name in
  # any case: `general`, `zonemessages`, `aliases` for the one aliasescontext
  # of `lines` names, or else `context` (apps/app_voicemail.c load_users)
  voicemailSectionKind = lines: let
    aliases = lib.toLower (toString (voicemailGeneral lines "aliasescontext"));
  in
    name: let
      lower = lib.toLower name;
    in
      if builtins.elem lower ["general" "zonemessages"]
      then lower
      else if aliases != "" && lower == aliases
      then "aliases"
      else "context";

  # whether extconfig.conf of `core` can map the realtime family `family`,
  # whose objects a database then holds: a key of that name, in any case, in
  # any section, or included files or raw text, which can hold one
  mapsRealtime = core: family:
    (core.includes."extconfig.conf" or [])
    != []
    || (core.extraConfig."extconfig.conf" or "") != ""
    || builtins.any (section: builtins.any (key: lib.toLower key == family) (builtins.attrNames section)) (builtins.attrValues (core.settings."extconfig.conf" or {}));

  # the host of a `bind` or `tlsbindaddr` value: `host`, `host:port` or
  # `[host]:port`
  bindHost = bind: let
    bracketed = builtins.match "[[]([^]]+)[]](:[0-9]+)?" bind;
    ipv4 = builtins.match "([0-9.]+)(:[0-9]+)?" bind;
  in
    if bracketed != null
    then builtins.head bracketed
    else if ipv4 != null
    then builtins.head ipv4
    else bind;

  # the port of such a value, or `default` when it names none
  parseBindPort = bind: default: let
    bracketed = builtins.match "[[].*[]]:([0-9]+)" bind;
    plain = builtins.match "[^:]*:([0-9]+)" bind;
  in
    if bracketed != null
    then lib.toInt (builtins.head bracketed)
    else if plain != null
    then lib.toInt (builtins.head plain)
    else default;
in {
  inherit splitMailbox voicemailLines entryOf voicemailSectionKind mapsRealtime bindHost parseBindPort;

  # the mailboxes of voicemail.conf, as { contexts.<context>.<box> = true;
  # aliases."<box>@<context>" = true; search; }, raw text included, or null
  # when the file includes others or realtime can map the voicemail family,
  # which app_voicemail looks in for a mailbox voicemail.conf lacks
  # (apps/app_voicemail.c:2018-2020); `search` is searchcontexts, with which
  # app_voicemail finds a mailbox in any context
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
      || mapsRealtime core "voicemail"
    then null
    else {
      contexts = lib.mapAttrs (_: boxes: lib.genAttrs (map (e: e.key) boxes) (_: true)) (builtins.groupBy (e: e.section) (ofKind "context"));
      aliases = lib.genAttrs (map (e: let
        ref = splitMailbox e.key;
      in "${ref.box}@${ref.context}") (ofKind "aliases")) (_: true);
      search = format.isTrue (voicemailGeneral lines "searchcontexts");
    };

  # whether the final modules.conf of `core` loads `module`: listed in load or
  # preload, or found by autoload, and not listed in noload
  moduleLoaded = core: module: let
    modules = core.settings."modules.conf".modules or {};
    listed = key: builtins.elem module (lib.toList (modules.${key} or []));
  in
    !(listed "noload") && (format.isTrue (modules.autoload or false) || listed "load" || listed "preload");

  # the modules a conference needs: app_confbridge mixes every conference in
  # bridge_softmix but does not declare it (apps/app_confbridge.c:1863,
  # 4726-4733), and each call fails without it
  # TODO: drop bridge_softmix once app_confbridge requires it
  confbridgeModules = [
    "app_confbridge.so"
    "bridge_softmix.so"
  ];

  # a rendered value Asterisk takes `bytes` of; `room` is what the secrets in
  # it may add to its other bytes, where `\;` is one byte
  limited = what: bytes: text: {
    inherit what bytes;
    refs = secrets.fromText text;
    room = bytes - builtins.stringLength (lib.replaceStrings ["\\;"] [";"] (lib.concatStrings (builtins.filter builtins.isString (builtins.split secrets.placeholderPattern text))));
  };

  # services.asterisk.secretMaxLengths for the secrets of `limited` values
  # that fit without them
  secretMaxLengths = values:
    lib.mkMerge (lib.concatMap (value: map (ref: {${secrets.placeholderOf ref} = value.room;}) value.refs) (builtins.filter (value: value.room >= 0) values));

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

  # the name of a transport section of the final pjsip.conf, its protocol and
  # the host and port it binds
  transportListener = section: let
    # Asterisk reads the protocol in any case (res_pjsip/config_transport.c)
    protocol = lib.toLower (section.protocol or "udp");
    bind = toString (section.bind or "0.0.0.0");
  in {
    inherit (section) name;
    inherit protocol;
    host = bindHost bind;
    port = parseBindPort bind (
      if protocol == "tls"
      then 5061
      else 5060
    );
  };

  # the names in `interfaces` that Linux refuses for an interface: it takes 1
  # to 15 bytes without /, : or whitespace, other than . and .. (net/core/dev.c
  # dev_valid_name)
  invalidInterfaces = builtins.filter (name: builtins.match "[^/:[:space:]]{1,15}" name == null || name == "." || name == "..");
}
