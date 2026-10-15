# Do not disturb and call forwarding through the probe
# (tests/campaign/probe.nix). Phone 201 dials the codes: a call of the probe
# goes out to this Asterisk itself as endpoint `as201`, which answers the
# challenge of extension 201 with its password, so the call comes in as 201.
# The calls to extensions after each show where the state sends them. Nobody
# registers, so an extension that rings has no answer. Other state is put
# into astdb before the calls: forwards that lead back to each other, one to
# an emergency number, and one on no answer.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  phone = extension: keys: {
    inherit extension keys;
    context = "phone";
  };
  call = extension: {
    inherit extension;
    context = "pbx-internal";
  };

  # each call, and on its own channel, or 201's for a code, the contexts it
  # passed through, the data of its Set, Dial and Playback steps, and the
  # step it ended in
  samples = [
    {
      call = phone "*76" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_EXTENSION=201" "DEVICE_STATE(Custom:pbx-dnd-201)=INUSE"];
      played = ["do-not-disturb&activated"];
    }
    {
      # do not disturb goes to the busy destination without ringing
      call = call "201";
      contexts = ["pbx-internal" "pbx-extension-201"];
      set = ["PBX_FORWARD=" "PBX_FORWARD="];
      ended = "Hangup(19)";
    }
    {
      call = phone "*90203" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_TARGET=203" "PBX_EXTENSION=201" "DB(pbx-forward/201/busy)=203"];
      played = ["call-fwd-on-busy&is-set-to" "203"];
    }
    {
      call = call "201";
      contexts = ["pbx-internal" "pbx-extension-201" "pbx-forward" "pbx-extension-203"];
      set = ["PBX_FORWARD=" "PBX_FORWARD=203" "HASH(pbx-forwarded,201)=1" "PBX_FORWARD=" "PBX_FORWARD="];
      dialled = [",20"];
      ended = "Hangup(19)";
    }
    {
      call = phone "*76" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_EXTENSION=201" "DEVICE_STATE(Custom:pbx-dnd-201)=NOT_INUSE"];
      played = ["do-not-disturb&de-activated"];
    }
    {
      # the code alone asks for the number
      call = phone "*72" "ww9555#";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_EXTENSION=201" "DB(pbx-forward/201/always)=9555"];
      played = ["call-fwd-unconditional&is-set-to" "9555"];
    }
    {
      # out through services.asterix.outbound, with its caller ID
      call = call "201";
      contexts = ["pbx-internal" "pbx-extension-201" "pbx-forward"];
      set = ["PBX_FORWARD=9555" "HASH(pbx-forwarded,201)=1" "CALLERID(num)=5551000"];
      dialled = ["PJSIP/555@provider,,b(pbx-caller-id^s^1(sip.provider.example))"];
      ended = "Congestion()";
    }
    {
      call = phone "*72911" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_TARGET=911" "PBX_EXTENSION=201"];
      played = ["invalid"];
    }
    {
      call = phone "*729911" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_TARGET=9911" "PBX_EXTENSION=201"];
      played = ["invalid"];
    }
    {
      call = phone "*73" "";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_EXTENSION=201" "PBX_TARGET=9555"];
      played = ["call-fwd-unconditional&de-activated"];
    }
    {
      call = call "201";
      contexts = ["pbx-internal" "pbx-extension-201"];
      set = ["PBX_FORWARD=" "PBX_FORWARD="];
      dialled = [",20"];
      ended = "Hangup(19)";
    }
    {
      # 206 and 207 forward to each other, so the call rings 206 once it is
      # back there
      call = call "206";
      contexts = ["pbx-internal" "pbx-extension-206" "pbx-forward" "pbx-extension-207" "pbx-forward" "pbx-extension-206"];
      set = [
        "PBX_FORWARD=207"
        "HASH(pbx-forwarded,206)=1"
        "PBX_FORWARD=206"
        "HASH(pbx-forwarded,207)=1"
        "PBX_FORWARD=207"
        "PBX_FORWARD="
      ];
      dialled = [",20"];
      ended = "Hangup(19)";
    }
    {
      # a forward to an emergency number, put into astdb by hand, is ignored
      call = call "205";
      contexts = ["pbx-internal" "pbx-extension-205"];
      set = ["PBX_FORWARD=9911" "PBX_FORWARD="];
      dialled = [",20"];
      ended = "Hangup(19)";
    }
    {
      call = call "208";
      contexts = ["pbx-internal" "pbx-extension-208" "pbx-forward" "pbx-extension-209"];
      set = ["PBX_FORWARD=" "PBX_FORWARD=209" "HASH(pbx-forwarded,208)=1" "PBX_FORWARD=" "PBX_FORWARD="];
      dialled = [",20" ",20"];
      ended = "Hangup(19)";
    }
    {
      # a caller that is not an extension changes nothing
      call = call "*76";
      contexts = ["pbx-internal" "pbx-features"];
      set = ["PBX_EXTENSION="];
      played = ["invalid"];
    }
  ];

  result = probe {
    name = "pbx-forwarding";
    modules = [
      self.nixosModules.default
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        services.asterix = {
          enable = true;
          extensions = lib.genAttrs ["201" "203" "205" "206" "207" "208" "209"] (number: {password = secret "sip-${number}";});
          featureCodes = {
            dnd = "*76";
            forward = {
              always = {
                on = "*72";
                off = "*73";
              };
              busy = {
                on = "*90";
                off = "*91";
              };
              noAnswer = {
                on = "*52";
                off = "*53";
              };
            };
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };
          emergency.numbers = ["911"];
          trunks.provider = {
            host = "sip.provider.example";
            username = "5551000";
            password = secret "trunk";
          };
        };
        services.asterisk = {
          # 201's phone: Asterisk calls itself with 201's user name and
          # password, which every secret shares in the build-time check
          pjsip.endpoints.as201 = {
            context = "phone";
            auth.password = secret "as201";
            outboundAuth = {
              username = "201";
              password = secret "sip-201";
            };
            aor = {
              contacts = ["sip:127.0.0.1:5060"];
              qualifyFrequency = 0;
            };
            settings.from_user = "201";
          };
          dialplan.contexts.phone.extensions."_*." = ["Dial(PJSIP/\${EXTEN}@as201)"];
        };
      })
    ];
    commands = [
      "database put pbx-forward 206/always 207"
      "database put pbx-forward 207/always 206"
      "database put pbx-forward 205/always 9911"
      "database put pbx-forward 208/noAnswer 209"
    ];
    calls = map (sample: lib.filterAttrs (_: v: v != "") sample.call) samples;
  };

  expected =
    map (sample: {
      inherit (sample) contexts set;
      played = sample.played or [];
      dialled = sample.dialled or [];
      ended = sample.ended or "Hangup()";
    })
    samples;
in
  pkgs.runCommand "asterisk-pbx-forwarding-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    jq -S '[.calls[] | (if .context == "phone" then [.steps[] | select(.channel | startswith("PJSIP/201-"))][0].channel else .channel end) as $channel
      | [.steps[] | select(.channel == $channel)] as $steps | {
        contexts: reduce ($steps[] | .context) as $context ([]; if last == $context then . else . + [$context] end),
        set: [$steps[] | select(.application == "Set") | .data],
        played: [$steps[] | select(.application == "Playback" or .application == "SayDigits") | .data],
        dialled: [$steps[] | select(.application == "Dial") | .data],
        ended: (.ended[] | select(.channel == $channel) | "\(.application)(\(.data))")
      }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
