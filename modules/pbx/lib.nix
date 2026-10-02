# Helpers the pbx modules share: the destination type and the dialplan steps
# a destination turns into.
{lib}: let
  inherit (lib) mkOption types;
  inherit (import ../lib.nix {inherit lib;}) splitMailbox;
  inherit (import ../../lib {inherit lib;}) format secrets;
  inherit (format) hostPort;

  mailboxType = types.submodule {
    options = {
      mailbox = mkOption {
        type = types.str;
        example = "200@sales";
        description = "Mailbox of voicemail.conf, from {option}`services.asterisk.voicemail.mailboxes`, `settings`, `extraConfig` or an included file: `box` or `box@context`. VoiceMail() finds the context in any case, or takes the box from any context with voicemail.conf's `searchcontexts`, but files the message under the box as written here, so the box is spelled as in voicemail.conf, and it reaches no mailbox through an alias.";
      };
      greeting = mkOption {
        type = types.enum [
          "unavailable"
          "busy"
        ];
        default = "unavailable";
        description = "Greeting played before the caller leaves a message.";
      };
    };
  };

  # Hangup() without a cause ends with normal clearing (16), which a caller
  # not answered yet gets as 603 Decline (channels/chan_pjsip.c hangup_cause2sip)
  unansweredCause = ''''${IF($["''${CHANNEL(state)}" != "Up" & (''${HANGUPCAUSE} = 0 | ''${HANGUPCAUSE} = 16)]?19)}'';
in rec {
  # a setting of a device that pbx.phones provisions
  phoneValue =
    types.oneOf [
      types.str
      types.int
      format.types.secret
    ]
    // {
      description = "string, integer or secret reference";
    };

  escapeXml = lib.replaceStrings ["&" "<" ">" "\"" "'"] ["&amp;" "&lt;" "&gt;" "&quot;" "&apos;"];

  # a setting as the text of a provisioning file: a secret becomes its
  # placeholder, which the provisioning service substitutes and escapes as the
  # file's `escape` says, and other text is escaped with `escapeText`
  phoneValueText = escapeText: v:
    if secrets.isSecret v
    then secrets.placeholderOf v
    else if builtins.isInt v
    then toString v
    else escapeText v;

  # sipServer and sipPort as one value, `host` or `host:port`, the port left
  # out when it is SIP's default, which also leaves an IPv6 address bare
  sipServerText = phones:
    if phones.sipPort == 5060
    then phones.sipServer
    else hostPort phones.sipServer phones.sipPort;

  # a control character in a setting, which XML holds none of but tab and
  # line breaks, and which a one-line value cannot hold; render-secrets
  # refuses them in secrets
  hasControlCharacter = v: builtins.isString v && builtins.match ".*[[:cntrl:]].*" v != null;

  # whether a server setting sends a device to 0.0.0.0 or ::, where a socket
  # listens on every address of the host but no device can connect: the host
  # of a URL, of `host:port`, in brackets, or the whole value
  sendsToWildcard = value: let
    afterScheme = let
      m = builtins.match "[a-z]+://(.*)" value;
    in
      if m == null
      then value
      else builtins.head m;
    bracketed = builtins.match "[[]([^]]*)[]].*" afterScheme;
    withPort = builtins.match "([^:/]*)(:[0-9]*)?(/.*)?" afterScheme;
    host =
      if bracketed != null
      then builtins.head bracketed
      else if withPort != null
      then builtins.head withPort
      else afterScheme;
  in
    builtins.isString value && (host == "0.0.0.0" || (lib.hasInfix ":" host && builtins.match "[0:.]*" host != null));

  destination = types.attrTag {
    extension = mkOption {
      type = types.str;
      example = "201";
      description = "Extension of {option}`pbx.extensions`: its phone rings, then its own busy or no-answer destination.";
    };
    ringGroup = mkOption {
      type = types.str;
      description = "Ring group of {option}`pbx.ringGroups`.";
    };
    queue = mkOption {
      type = types.str;
      description = "Queue of {option}`pbx.queues`.";
    };
    conference = mkOption {
      type = types.str;
      description = "Conference of {option}`pbx.conferences`.";
    };
    ivr = mkOption {
      type = types.str;
      description = "Voice menu of {option}`pbx.ivrs`.";
    };
    voicemail = mkOption {
      type = types.coercedTo types.str (mailbox: {inherit mailbox;}) mailboxType;
      example = "200";
      description = "Leave a message in a mailbox, with the unavailable greeting unless `greeting` says otherwise.";
    };
    context = mkOption {
      type = types.submodule {
        options = {
          context = mkOption {
            type = types.str;
            description = "Context of {option}`services.asterisk.dialplan.contexts` or other hand-written dialplan.";
          };
          extension = mkOption {
            type = types.str;
            default = "s";
            description = "Extension in the context.";
          };
          priority = mkOption {
            type = types.either types.ints.positive types.str;
            default = 1;
            description = "Priority or label.";
          };
        };
      };
      description = "Hand-written dialplan. The context must exist.";
    };
    hangup = mkOption {
      type = types.enum [true];
      description = ''
        End the call. A caller who was not answered gets the reason the last
        phone or trunk it rang gave, such as busy, or that nobody answered
        (480 Temporarily Unavailable in SIP) where none gave one.
      '';
    };
  };

  # the generated context of a pbx object
  objectContext = kind: name: "pbx-${kind}-${name}";

  # Goto and Gosub end a context at a comma (main/pbx.c pbx_parseable_goto),
  # ${ and $[ are substituted, and ; [ ] end a section header
  breaksContext = name: builtins.match ".*([],;[]|[$][{[]).*" name != null;

  # Asterisk's argument parser drops quotes and backslashes, and an unclosed
  # ( takes in the arguments after it (main/app.c __ast_app_separate_args)
  breaksArgument = name:
    builtins.match ".*[\"\\\\].*" name
    != null
    || builtins.foldl' (open: c:
      if c == "("
      then open + 1
      else if c == ")" && open > 0
      then open - 1
      else open)
    0 (lib.stringToCharacters name)
    != 0;

  # a trunk in Dial(PJSIP/<number>@<trunk>): Dial splits at & (apps/app_dial.c
  # dial_exec_full) and chan_pjsip at / (channels/chan_pjsip.c request)
  breaksDialString = name: breaksContext name || breaksArgument name || builtins.match ".*[&/].*" name != null;

  # dial string that calls every contact of an extension; PJSIP/<number>
  # calls only the first reachable one
  devices = number: "\${PJSIP_DIAL_CONTACTS(${number})}";

  # Dial's option that has pbx-caller-id put the caller ID pbx set in the
  # P-Asserted-Identity of the call to `trunk`, whose From names its account
  callerIdOption = trunk: let
    domain =
      if trunk.fromDomain != null
      then trunk.fromDomain
      else trunk.host;
  in "b(pbx-caller-id^s^1(${hostPort domain null}))";

  # dialplan steps a destination turns into; the call never comes back
  steps = dest:
    if dest ? extension
    then [(goto (objectContext "extension" dest.extension))]
    else if dest ? ringGroup
    then [(goto (objectContext "ringgroup" dest.ringGroup))]
    else if dest ? queue
    then [(goto (objectContext "queue" dest.queue))]
    else if dest ? conference
    then [(goto (objectContext "conference" dest.conference))]
    else if dest ? ivr
    then [(goto (objectContext "ivr" dest.ivr))]
    else if dest ? voicemail
    then let
      box = splitMailbox dest.voicemail.mailbox;
    in [
      {
        app = "VoiceMail";
        args = [
          "${box.box}@${box.context}"
          (
            if dest.voicemail.greeting == "busy"
            then "b"
            else "u"
          )
        ];
      }
      (app "Hangup" [])
    ]
    else if dest ? context
    then [
      (app "Goto" [
        dest.context.context
        dest.context.extension
        (toString dest.context.priority)
      ])
    ]
    # hangup: its value is read, so its type, which takes only true, is
    # checked
    else builtins.seq dest.hangup [(app "Hangup" [unansweredCause])];

  # `steps`, the first one labelled
  labelled = label: dest: let
    all = steps dest;
  in
    [(builtins.head all // {inherit label;})] ++ builtins.tail all;

  app = name: args: {
    app = name;
    inherit args;
  };

  goto = context:
    app "Goto" [
      context
      "s"
      "1"
    ];

  # what a destination is, for messages
  describe = dest: let
    tag = builtins.head (builtins.attrNames dest);
    value = dest.${tag};
  in
    if tag == "voicemail"
    then "voicemail ${value.mailbox}"
    else if tag == "context"
    then "context ${value.context}"
    else if tag == "hangup"
    then "hangup"
    else "${tag} ${value}";
}
