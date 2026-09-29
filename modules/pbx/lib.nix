# Helpers the pbx modules share: the destination type and the dialplan steps
# a destination turns into.
{lib}: let
  inherit (lib) mkOption types;

  mailboxType = types.submodule {
    options = {
      mailbox = mkOption {
        type = types.str;
        example = "200@sales";
        description = "Mailbox of {option}`services.asterisk.voicemail.mailboxes`: `box` or `box@context`.";
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
in rec {
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
      description = "End the call.";
    };
  };

  # the generated context of a pbx object
  objectContext = kind: name: "pbx-${kind}-${name}";

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
    else [(app "Hangup" [])];

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
