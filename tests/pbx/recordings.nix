# Call recording through the probe (tests/campaign/probe.nix): which calls
# are recorded, each once, on which channel and under which name, and who
# hears the notice before the recording starts. The phones are this Asterisk
# itself, at static contacts that answer, answer and press the record code,
# or ring without answering. A call from a phone that records comes from
# `from201`, which sets the variables 201's endpoint gives its channels, and
# one from a channel that records from `recording`.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  call = extension: {
    inherit extension;
    context = "pbx-internal";
    callerId = ''"Desk" <210>'';
  };

  # each call, and on its channels, in order: the notice, Dial and Queue,
  # and MixMonitor with its file, by the caller's channel or the phone's;
  # and how many recordings began
  samples = [
    {
      # an inbound number, a ring group and, after it, an extension, all of
      # which record: one notice, one recording. The caller's number keeps
      # only digits and + in the name.
      call = {
        extension = "5551000";
        context = "pbx-inbound-provider";
        callerId = ''"Outside" <+1555/98.76x>'';
      };
      events = [
        "caller notice"
        "caller Dial"
        "caller Dial"
        "PJSIP/201 MixMonitor <time>-+15559876-201-<id>.wav,b"
      ];
      recordings = 1;
    }
    {
      # nothing records
      call = call "202";
      events = ["caller Dial"];
      recordings = 0;
    }
    {
      # an extension that records: the caller hears the notice before it
      # rings
      call = call "201";
      events = [
        "caller notice"
        "caller Dial"
        "PJSIP/201 MixMonitor <time>-210-201-<id>.wav,b"
      ];
      recordings = 1;
    }
    {
      # a phone that records calls one that does not: whoever answers hears
      # the notice
      call = {
        extension = "202";
        context = "from201";
      };
      events = [
        "caller Dial"
        "PJSIP/202 notice"
        "PJSIP/202 MixMonitor <time>-201-202-<id>.wav,b"
      ];
      recordings = 1;
    }
    {
      # a ring group with a member that records, which another member
      # answers: the notice, but no recording
      call = call "601";
      events = [
        "caller notice"
        "caller Dial"
      ];
      recordings = 0;
    }
    {
      # the phone that answers presses the code on a call nothing records
      call = call "203";
      events = ["caller Dial"];
      recordings = 1;
    }
    {
      # and on a call that records, where it is not enabled
      call = call "204";
      events = [
        "caller notice"
        "caller Dial"
        "PJSIP/204 MixMonitor <time>-210-204-<id>.wav,b"
      ];
      recordings = 1;
    }
    {
      # a channel that records, such as one the other side transferred,
      # goes on to an extension that records: no second recording
      call = {
        extension = "201";
        context = "recording";
      };
      events = ["caller Dial"];
      recordings = 0;
    }
    {
      # a queue whose member records
      call = call "610";
      events = [
        "caller notice"
        "caller Queue"
        "Local/201@pbx-devices Dial"
        "PJSIP/201 MixMonitor <time>-210-support-<id>.wav,b"
      ];
      recordings = 1;
    }
  ];

  # with noticeToRecorder, the phone that records hears the notice too, from
  # Dial's A() at the same time as whoever answers
  toRecorder = [
    {
      call = {
        extension = "202";
        context = "from201";
      };
      events = [
        "caller Dial with the notice"
        "PJSIP/202 MixMonitor <time>-201-202-<id>.wav,b"
      ];
      recordings = 1;
    }
  ];

  run = name: noticeToRecorder: samples:
    probe {
      inherit name;
      modules = [
        self.nixosModules.default
        ({config, ...}: let
          secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
          contacts = {
            "201" = "answer";
            "202" = "answer";
            "203" = "press";
            "204" = "press";
            "205" = "ring";
            "206" = "ring";
          };
        in {
          services.asterix = {
            enable = true;
            extensions =
              lib.mapAttrs (number: _: {
                password = secret "sip-${number}";
                record = builtins.elem number ["201" "204" "206"];
              })
              contacts;
            ringGroups = {
              sales = {
                members = ["205"];
                ringTime = 1;
                record = true;
                noAnswer.extension = "201";
              };
              mixed = {
                number = "601";
                members = ["206" "202"];
                ringTime = 5;
              };
            };
            queues.support = {
              number = "610";
              members = ["201"];
            };
            inbound."5551000" = {
              trunk = "provider";
              destination.ringGroup = "sales";
              record = true;
            };
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "trunk";
            };
            featureCodes.record = "*1";
            recordings = {
              notice.sound = "beep";
              inherit noticeToRecorder;
            };
          };
          services.asterisk = {
            pjsip.endpoints =
              lib.mapAttrs (_: contact: {
                aor = {
                  contacts = ["sip:${contact}@127.0.0.1:5060"];
                  qualifyFrequency = 0;
                };
              })
              contacts
              // {
                # the phones' side of those calls
                line = {
                  context = "line";
                  identify.match = ["127.0.0.1"];
                  aor = null;
                };
              };
            dialplan.contexts = {
              line.extensions = {
                answer = ["Answer()" "Wait(2)" "Hangup()"];
                press = ["Answer()" "Wait(1)" "SendDTMF(*1)" "Wait(2)" "Hangup()"];
                ring = ["Ringing()" "Wait(30)"];
              };
              # what 201's endpoint gives the channels of its calls
              from201.extensions."_X." = [
                "Set(PBX_RECORDS=1)"
                "Set(PBX_PHONE=1)"
                "Set(CALLERID(num)=201)"
                "Goto(pbx-internal,\${EXTEN},1)"
              ];
              # what the channel that records a call carries
              recording.extensions."_X." = [
                "Set(__PBX_RECORDING=earlier.wav)"
                "Goto(pbx-internal,\${EXTEN},1)"
              ];
            };
          };
        })
      ];
      calls = map (sample: sample.call) samples;
    };

  expectedOf = map (sample: {
    inherit (sample) events recordings;
    errors = [];
  });
in
  pkgs.runCommand "asterisk-pbx-recordings-tests" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    check() {
      jq -S '[.calls[] | .channel as $channel | {
        events: [.steps[] | select(.context != "line" and (.application | IN("Playback", "Dial", "Queue", "MixMonitor")))
          | (if .channel == $channel then "caller" else .channel | sub("-[0-9a-f]{8}(;[12])?$"; "") end) as $who
          | if .application == "Playback" then "\($who) notice"
            elif .application == "MixMonitor" then "\($who) MixMonitor \(.data | sub("^[0-9]{8}-[0-9]{6}-"; "<time>-") | sub("-[0-9]+[.][0-9]+[.]wav"; "-<id>.wav"))"
            elif .application == "Dial" and (.data | test("aA[(]beep:beep[)]")) then "\($who) Dial with the notice"
            else "\($who) \(.application)" end],
        recordings: [.log[] | select(.message | startswith("Begin MixMonitor Recording"))] | length,
        errors: [.log[] | select(.level == "ERROR") | .message]
      }]' "$1/probe.json" > actual
      if ! diff -u <(echo "$2" | jq -S .) actual; then
        echo "the calls were recorded otherwise, see $1/probe.json" >&2
        exit 1
      fi
    }
    check ${run "pbx-recordings" false samples} ${lib.escapeShellArg (builtins.toJSON (expectedOf samples))}
    check ${run "pbx-recordings-to-recorder" true toRecorder} ${lib.escapeShellArg (builtins.toJSON (expectedOf toRecorder))}
    touch $out
  ''
