# Call parking through the probe (tests/campaign/probe.nix). Phone 201 parks
# its own call by dialling the park number: a call of the probe goes out to
# this Asterisk itself as endpoint `as201`, which answers the challenge of
# extension 201 with its password, so the call comes in as 201. When the
# parked call times out it rings 201 for 201's ringTime, which nobody
# answers, and goes on to 201's noAnswer destination. A call parked by
# something other than an extension ends at the timeout, and an empty slot
# turns its caller away. The hints of the slots reach the phones through
# pbx-internal and the DND busy lamp contexts.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  samples = [
    {
      call = {
        extension = "700";
        context = "phone";
      };
      steps = [
        "pbx-internal,700,1,Park()"
        "pbx-parking-timeout,PJSIP_201,1,Dial(,7)"
        "pbx-parking-timeout,PJSIP_201,2,Goto(pbx-extension-201,s,noanswer)"
        # 201's no-answer forward, then its noAnswer destination
        "pbx-extension-201,s,4,Set(PBX_FORWARD=)"
        "pbx-extension-201,s,5,GotoIf(0?forward)"
        "pbx-extension-201,s,6,Goto(pbx-extension-202,s,1)"
        "pbx-extension-202,s,1,GotoIf(0?busy)"
        "pbx-extension-202,s,2,Dial(,20)"
        "pbx-extension-202,s,3,GotoIf(0?busy)"
        "pbx-extension-202,s,4,Set(PBX_FORWARD=)"
        "pbx-extension-202,s,5,GotoIf(0?forward)"
        "pbx-extension-202,s,6,Hangup()"
      ];
    }
    {
      # the probe's own Local channel parks itself
      call = {
        extension = "700";
        context = "pbx-internal";
      };
      steps = [
        "pbx-internal,700,1,Park()"
        "pbx-parking-timeout,s,1,Hangup()"
      ];
    }
    {
      call = {
        extension = "702";
        context = "pbx-internal";
      };
      steps = ["pbx-internal,702,1,ParkedCall(default,702)"];
    }
  ];

  result = probe {
    name = "pbx-parking";
    modules = [
      self.nixosModules.default
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        services.asterix = {
          enable = true;
          extensions = {
            "201" = {
              password = secret "sip-201";
              ringTime = 7;
              noAnswer.extension = "202";
            };
            "202".password = secret "sip-202";
          };
          parking = {
            number = "700";
            slots = 3;
            timeout = 1;
          };
          featureCodes = {
            dnd = "*76";
            forward.noAnswer = {
              on = "*52";
              off = "*53";
            };
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
          dialplan.contexts.phone.extensions."_X." = ["Dial(PJSIP/\${EXTEN}@as201)"];
        };
      })
    ];
    commands = [
      "core show hints"
      "dialplan show 703@pbx-hints-201"
    ];
    calls = map (sample: sample.call) samples;
  };
in
  pkgs.runCommand "asterisk-pbx-parking-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON (map (sample: sample.steps) samples);
    passAsFile = ["expected"];
  } ''
    jq '[.calls[] | (if .context == "phone" then [.steps[] | select(.channel | startswith("PJSIP/201-"))][0].channel else .channel end) as $channel
      | [.steps[] | select(.channel == $channel) | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"]]' \
      ${result}/probe.json > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    hints=$(jq -r '.commands[0].output' ${result}/probe.json)
    for slot in 701 702 703; do
      if ! grep -q "^ *$slot@pbx-parking *: park:$slot@pbx-parking " <<<"$hints"; then
        echo "no hint for slot $slot:" >&2
        echo "$hints" >&2
        exit 1
      fi
    done
    if ! jq -r '.commands[1].output' ${result}/probe.json | grep -q "'703' =>  *hint: *park:703@pbx-parking"; then
      echo "pbx-hints-201 does not reach the hint of slot 703, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
