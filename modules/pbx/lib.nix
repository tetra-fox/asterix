# Helpers the pbx modules share: the destination type, the dialplan steps
# a destination turns into, prompts, and the network of an extension or
# trunk.
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
        description = "Mailbox of voicemail.conf as `box` or `box@context`, such as an extension's or one of {option}`services.asterix.voicemail.mailboxes`. VoiceMail() files the message under the box as written here, so spell it as in voicemail.conf, not as an alias.";
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
  # a setting of a device that services.asterix.phones provisions
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

  # what a voice menu or an announcement plays
  prompt = types.attrTag {
    sound = mkOption {
      type = types.str;
      example = "custom/main-menu";
      description = "Sound file, as Playback() names it: without extension, relative to the sounds directory.";
    };
    text = mkOption {
      type = types.str;
      example = "For sales, press 1. For support, press 2.";
      description = ''
        English text spoken by flite when the system is built. Characters
        outside ASCII are skipped, and a text with no ASCII letter or digit
        fails evaluation.
      '';
    };
  };

  # the sound the prompt of object `name` of `kind` plays, for a text the
  # file promptSounds speaks it into
  promptSound = kind: name: prompt:
    if prompt ? text
    then "pbx/${kind}-${name}"
    else prompt.sound;

  # the text prompts of `objects`, by name, spoken by flite into a package
  # for services.asterisk.sounds.packages, in a list that is empty without
  # text prompts
  promptSounds = pkgs: kind: objects: let
    spoken = lib.filterAttrs (_: object: object.prompt ? text) objects;
  in
    lib.optional (spoken != {}) (pkgs.runCommand "pbx-${kind}-prompts" {nativeBuildInputs = [pkgs.flite];} ''
      mkdir -p $out/sounds/pbx
      ${lib.concatStrings (lib.mapAttrsToList (name: object: ''
          flite -voice slt -o $out/sounds/${promptSound kind name object.prompt}.wav16 -t ${lib.escapeShellArg object.prompt.text}
        '')
        spoken)}
    '');

  # flite speaks a text with no ASCII letter or digit as 0.185 s of silence
  silentPrompt = prompt: prompt ? text && !(builtins.any (c: builtins.match "[A-Za-z0-9]" c != null) (lib.stringToCharacters prompt.text));

  # the assertions on the names and prompts of services.asterix.<option>,
  # given as `objects`: a text prompt's file is named after its object
  promptAssertions = option: objects: let
    badNames = builtins.filter (name: builtins.match "[A-Za-z0-9_-]+" name == null) (builtins.attrNames objects);
    silent = builtins.filter (name: silentPrompt objects.${name}.prompt) (builtins.attrNames objects);
  in [
    {
      assertion = badNames == [];
      message = "services.asterix.${option}: names may only contain letters, digits, _ and -: ${lib.concatMapStringsSep ", " (name: lib.showOption ["services" "asterix" option name]) badNames}.";
    }
    {
      assertion = silent == [];
      message = ''services.asterix.${option}: flite speaks these prompt texts as silence, since they hold no ASCII letter or digit: ${lib.concatMapStringsSep ", " (name: lib.showOption ["services" "asterix" option name "prompt" "text"]) silent}. Write the text in English, or for no prompt use prompt.sound = "silence/1".'';
    }
  ];

  destination = types.attrTag {
    extension = mkOption {
      type = types.str;
      example = "201";
      description = "Extension of {option}`services.asterix.extensions`: its phone rings, then its own busy or no-answer destination.";
    };
    ringGroup = mkOption {
      type = types.str;
      description = "Ring group of {option}`services.asterix.ringGroups`.";
    };
    queue = mkOption {
      type = types.str;
      description = "Queue of {option}`services.asterix.queues`.";
    };
    conference = mkOption {
      type = types.str;
      description = "Conference of {option}`services.asterix.conferences`.";
    };
    ivr = mkOption {
      type = types.str;
      description = "Voice menu of {option}`services.asterix.ivrs`.";
    };
    announcement = mkOption {
      type = types.str;
      description = "Announcement of {option}`services.asterix.announcements`.";
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
        End the call. An unanswered caller gets the reason the last phone or
        trunk it rang gave, such as busy, or else 480 Temporarily
        Unavailable.
      '';
    };
  };

  # the network of services.asterix.networks an extension or trunk is on, or
  # null when it names none and there are several
  networkOf = networks: object: let
    names = builtins.attrNames networks;
  in
    if object.network != null
    then object.network
    else if builtins.length names == 1
    then builtins.head names
    else null;

  # the transport the extensions and trunks of network `name` send over
  pinned = name: network:
    if builtins.elem "udp" network.protocols
    then name
    else if builtins.elem "tcp" network.protocols
    then "${name}-tcp"
    else "${name}-tls";

  # a number of digits, * and #, with an optional leading +, or a pattern of
  # such numbers: X, Z and N, sets in brackets, and . and ! at the end
  # (main/pbx.c ext_cmp_pattern_pos)
  numberOrPattern = "[+]?[0-9*#]+|_([0-9*#+XZNxzn.!]|\\[[0-9*#+-]+])+";

  # whether services.asterix.blocklist turns away any caller, and so
  # pbx-blocklist exists
  blocksCallers = blocklist: blocklist.numbers != [] || blocklist.anonymous;

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
    else if dest ? announcement
    then [(goto (objectContext "announcement" dest.announcement))]
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
  labelled = label: dest: labelFirst label (steps dest);

  labelFirst = label: all: [(builtins.head all // {inherit label;})] ++ builtins.tail all;

  # the forwards of services.asterix.featureCodes.forward, each with the
  # sound that names it
  forwardSounds = {
    always = "call-fwd-unconditional";
    busy = "call-fwd-on-busy";
    noAnswer = "call-fwd-no-ans";
  };

  # the astdb key, as DB() takes it, of the target of forward `kind` of an
  # extension
  forwardKey = extension: kind: "pbx-forward/${extension}/${kind}";

  # the slot numbers of services.asterix.parking, which follow its number
  parkingSlots = parking: let
    first = lib.toInt parking.number + 1;
  in
    map toString (lib.range first (first + parking.slots - 1));

  # the custom device state of an extension's do not disturb
  dndDevice = extension: "Custom:pbx-dnd-${extension}";

  # whether any `record` of services.asterix is on, so the layer records
  # calls without the code (recordings.nix)
  recordsCalls = cfg: builtins.any (option: builtins.any (object: object.record) (builtins.attrValues cfg.${option})) ["extensions" "inbound" "ringGroups" "queues"];

  # whether one of the extensions `members` records its calls; one that is
  # not an extension is an assertion of the ring group or queue
  recordingMember = cfg: builtins.any (member: cfg.extensions.${member}.record or false);

  # the step that runs pbx-record's `call` on the caller's channel before it
  # rings anything, for an object that records every call (`records`) or
  # rings a phone that records its own (`members`), with `to` naming what
  # was called in file names
  recordCall = cfg: records: members: to: let
    flag = b:
      if b
      then "1"
      else "0";
  in
    lib.optional (recordsCalls cfg || cfg.featureCodes.record != null) (app "Gosub" ["pbx-record" "call" "1(${flag records},${flag members},${to})"]);

  # a name as part of a file name, without / and characters a Gosub argument
  # would misread
  fileNamePart = name: lib.concatStrings (builtins.filter (c: builtins.match "[A-Za-z0-9_+*#-]" c != null) (lib.stringToCharacters name));

  # Dial's options for recording: U() starts a recording when the called
  # channel answers (`answered`, which Queue() lacks), after the notice of
  # PBX_NOTICE (recordings.noticeToRecorder) plays to both sides, and with
  # services.asterix.featureCodes.record, on a call nothing records, x lets
  # the called phone (`called`) and X a calling phone (`calling`) record with
  # the code (features.conf automixmon), as in Queue()
  recordOptions = cfg: {
    answered ? true,
    called,
    calling,
  }: let
    onDemand = ''"''${PBX_RECORD}''${PBX_RECORDING}" = ""'';
    code = cfg.featureCodes.record != null;
  in
    lib.optionalString (answered && recordsCalls cfg) "U(pbx-record)\${PBX_NOTICE}"
    + lib.optionalString (code && called) "\${IF($[${onDemand}]?x)}"
    + lib.optionalString (code && calling) "\${IF($[${onDemand} & \"\${PBX_PHONE}\" = \"1\"]?X)}";

  # an expression that is true when the number in variable `var` is one a
  # forward may go to: a number of pbx-forward that pbx-forward-refused does
  # not hold
  forwardable = var: let
    v = "\${${var}}";
  in ''"${v}" != "" & ''${DIALPLAN_EXISTS(pbx-forward,${v},1)} & !''${DIALPLAN_EXISTS(pbx-forward-refused,${v},1)}'';

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
