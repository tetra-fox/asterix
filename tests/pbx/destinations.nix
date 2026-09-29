# Destinations followed through the dialplan, call by call (the probe,
# tests/campaign/probe.nix): a menu key goes to a ring group, whose no-answer
# destination is a queue, whose timeout goes to a mailbox; and every slot that
# takes a destination, in a configuration with each kind of destination in
# each slot (./slots.nix), which Asterisk has to load. Nobody is registered,
# so ring groups and extensions have no phone to ring and queues no member to
# take the call, except for one phone that is busy.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  slots = import ./slots.nix {inherit lib;} {
    conference.conference = "board";
    context = {context.context = "done";};
    extension.extension = "201";
    hangup.hangup = true;
    ivr.ivr = "lobby";
    queue.queue = "desk";
    ringGroup.ringGroup = "front";
    voicemail.voicemail = "200";
  };

  # with the conference for no answer, and the context when busy
  busyPhone = slots.extensionTo.conference;

  # the last step of a call that hangs up, or goes to the mailbox
  hangup = [
    {
      application = "Hangup";
      data = "";
      how = "hangup";
    }
  ];
  voicemail = [
    {
      application = "VoiceMail";
      data = "200@default,u";
      how = "hangup";
    }
  ];

  # each call, the contexts its channel passes through, and where its
  # dialplan ends; the mailbox hangs up once the caller stays silent
  samples = [
    {
      call = {
        extension = "700";
        context = "pbx-internal";
        keys = "1";
      };
      contexts = [
        "pbx-internal"
        "pbx-ivr-menu"
        "pbx-ringgroup-sales"
        "pbx-queue-support"
      ];
      ended = voicemail;
      answered = true;
    }
    {
      call = {
        extension = "600";
        context = "pbx-internal";
      };
      contexts = [
        "pbx-internal"
        "pbx-ringgroup-sales"
        "pbx-queue-support"
      ];
      ended = voicemail;
      answered = true;
    }
    {
      call = {
        extension = "610";
        context = "pbx-internal";
      };
      contexts = [
        "pbx-internal"
        "pbx-queue-support"
      ];
      ended = voicemail;
      answered = true;
    }
    {
      call = {
        extension = slots.extensionTo.extension;
        context = "pbx-internal";
      };
      contexts = [
        "pbx-internal"
        "pbx-extension-${slots.extensionTo.extension}"
        "pbx-extension-201"
      ];
      ended = hangup;
    }
    {
      call = {
        extension = busyPhone;
        context = "pbx-internal";
      };
      contexts = [
        "pbx-internal"
        "pbx-extension-${busyPhone}"
        "done"
      ];
      ended = hangup;
    }
    {
      call = {
        extension = "s";
        context = "pbx-ringgroup-to-queue";
      };
      contexts = [
        "pbx-ringgroup-to-queue"
        "pbx-queue-desk"
      ];
      ended = hangup;
      answered = true;
    }
    {
      call = {
        extension = "s";
        context = "pbx-queue-to-ringGroup";
      };
      contexts = [
        "pbx-queue-to-ringGroup"
        "pbx-ringgroup-front"
      ];
      ended = hangup;
      answered = true;
    }
    # a conference and a mailbox go on until the probe hangs up
    {
      call = {
        extension = slots.inboundTo.conference;
        context = "pbx-inbound-provider";
        limit = 2;
      };
      contexts = [
        "pbx-inbound-provider"
        "pbx-conference-board"
      ];
      ended = [
        {
          application = "ConfBridge";
          data = "board";
          how = "hangup";
        }
      ];
      answered = true;
      limitReached = true;
    }
    # open on a Wednesday at 10:00, closed at 20:00
    {
      call = {
        extension = slots.inboundByHoursTo.voicemail;
        context = "pbx-inbound-provider";
        time = "2026-12-02T10:00:00Z";
        limit = 2;
      };
      contexts = [
        "pbx-inbound-provider"
        "pbx-hours-office"
        "pbx-inbound-provider"
      ];
      ended = voicemail;
      answered = true;
      limitReached = true;
    }
    {
      call = {
        extension = slots.inboundByHoursTo.conference;
        context = "pbx-inbound-provider";
        time = "2026-12-02T20:00:00Z";
      };
      contexts = [
        "pbx-inbound-provider"
        "pbx-hours-office"
        "pbx-inbound-provider"
        "done"
      ];
      ended = hangup;
    }
    # a key with a destination, no key, and a key without one
    {
      call = {
        extension = "s";
        context = "pbx-ivr-to-hangup";
        keys = "1";
      };
      contexts = ["pbx-ivr-to-hangup"];
      ended = hangup;
      answered = true;
    }
    {
      call = {
        extension = "s";
        context = "pbx-ivr-to-hangup";
      };
      contexts = [
        "pbx-ivr-to-hangup"
        "pbx-ivr-lobby"
      ];
      ended = hangup;
      answered = true;
    }
    {
      call = {
        extension = "s";
        context = "pbx-ivr-to-hangup";
        keys = "9";
      };
      contexts = [
        "pbx-ivr-to-hangup"
        "pbx-queue-desk"
      ];
      ended = hangup;
      answered = true;
    }
  ];

  result = probe {
    name = "pbx-destinations";
    modules = [
      self.nixosModules.pbx
      slots.module
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        pbx = {
          enable = true;
          extensions = {
            "201".password = secret "sip-201";
            "202".password = secret "sip-202";
          };
          ivrs = {
            menu = {
              number = "700";
              prompt.text = "For sales, press 1.";
              options."1".ringGroup = "sales";
            };
            lobby = {
              prompt.sound = "beep";
              timeout = 1;
              attempts = 1;
            };
          };
          ringGroups = {
            sales = {
              number = "600";
              members = [
                "201"
                "202"
              ];
              noAnswer.queue = "support";
            };
            front.members = ["201"];
          };
          queues = {
            support = {
              number = "610";
              timeout = 1;
              noAnswer.voicemail = "200";
            };
            desk.timeout = 1;
          };
          conferences.board = {};
          hours.office = {
            timezone = "UTC";
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "trunk";
            };
            # the phone of busyPhone is this Asterisk, which answers busy
            endpoints = {
              ${busyPhone}.aor = {
                contacts = ["sip:busy@127.0.0.1:5060"];
                qualifyFrequency = 0;
              };
              busy-line = {
                context = "busy-line";
                identify.match = ["127.0.0.1"];
                aor = null;
              };
            };
          };
          queues.queues = {
            support.members = [
              "PJSIP/201"
              "PJSIP/202"
            ];
            desk.members = ["PJSIP/201"];
          };
          voicemail.mailboxes."200".pin = secret "vm-200";
          dialplan.contexts = {
            busy-line.extensions.busy = ["Busy()"];
            done.extensions.s = ["Hangup()"];
          };
        };
      })
    ];
    calls = map (sample: sample.call) samples;
  };

  expected =
    map (sample: {
      inherit (sample) contexts ended;
      answered = sample.answered or false;
      limitReached = sample.limitReached or false;
    })
    samples;
in
  pkgs.runCommand "asterisk-pbx-destinations-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # each call's own channel, not the phone it calls
    jq -S '[.calls[] | .channel as $channel | {
      contexts: reduce (.steps[] | select(.channel == $channel) | .context) as $context ([]; if last == $context then . else . + [$context] end),
      ended: [.ended[] | select(.channel == $channel) | {application, data, how}],
      answered,
      limitReached
    }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
