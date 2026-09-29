# Numbers outside dialled through the probe (tests/campaign/probe.nix), with
# each kind of pbx.outbound.prefix: none, a digit, a star code and #, and
# with and without pbx.outbound.callerId. The trunk gets the number without
# the prefix, after the caller ID is set where one is configured; a number
# too short for the pattern reaches nothing; a pbx number that starts with
# the prefix reaches the pbx; and the emergency number works with and without
# the prefix.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  # "context,extension,priority,application(data)" for the steps of one extension
  numbered = context: extension: lib.imap1 (priority: step: "${context},${extension},${toString priority},${step}");

  extensionSteps = number:
    numbered "pbx-internal" number ["Goto(pbx-extension-${number},s,1)"]
    ++ numbered "pbx-extension-${number}" "s" [
      "Dial(,20)"
      "GotoIf(0?busy)"
      "Hangup()"
    ];

  # each prefix, with a pbx number that starts with it where one makes sense
  cases = [
    {
      name = "none";
      prefix = "";
      callerId = "5551000";
      extensions = ["201"];
      overlap = [
        {
          extension = "201";
          steps = extensionSteps "201";
        }
      ];
    }
    {
      name = "digit";
      prefix = "9";
      callerId = null;
      extensions = ["201" "901"];
      overlap = [
        {
          extension = "901";
          steps = extensionSteps "901";
        }
      ];
    }
    {
      name = "star";
      prefix = "*9";
      callerId = "5551000";
      extensions = ["201"];
      # the menu needs a mailbox, or nothing loads app_voicemail
      mailbox = "201";
      voicemailMenu = "*97";
      overlap = [
        {
          extension = "*97";
          callerId = ''"Reception" <201>'';
          limit = 1;
          steps = numbered "pbx-internal" "*97" [
            "Answer()"
            "VoiceMailMain(201@default)"
          ];
        }
      ];
    }
    {
      name = "hash";
      prefix = "#";
      callerId = null;
      extensions = ["201"];
      overlap = [];
    }
  ];

  # calls to pbx-internal and the steps of each call's own channel, or
  # "no such extension" for a number pbx-internal lacks
  samples = c: let
    outside = "${c.prefix}5559999";
    emergency = dialled: {
      extension = dialled;
      steps =
        numbered "pbx-internal" dialled ["Goto(pbx-emergency,911,1)"]
        ++ numbered "pbx-emergency" "911" [
          "Dial(PJSIP/911@provider)"
          "Hangup()"
        ];
    };
  in
    [
      {
        extension = outside;
        steps = numbered "pbx-internal" outside (
          lib.optional (c.callerId != null) "Set(CALLERID(num)=${c.callerId})"
          ++ [
            "Dial(PJSIP/5559999@provider)"
            "Hangup()"
          ]
        );
      }
      # the pattern wants two characters after the prefix
      {
        extension = "${c.prefix}5";
        steps = ["no such extension"];
      }
      (emergency "911")
    ]
    ++ lib.optional (c.prefix != "") (emergency "${c.prefix}911")
    ++ c.overlap;

  results = map (c:
    probe {
      name = "pbx-outbound-${c.name}";
      modules = [
        self.nixosModules.pbx
        ({config, ...}: let
          secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
        in {
          pbx = {
            enable = true;
            extensions = lib.genAttrs c.extensions (number: {
              password = secret "sip-${number}";
              voicemail = lib.mkIf (number == c.mailbox or null) {pin = secret "vm-${number}";};
            });
            voicemailMenu = c.voicemailMenu or null;
            outbound = {
              inherit (c) prefix callerId;
              trunk = "provider";
            };
            emergency = {
              numbers = ["911"];
              trunk = "provider";
            };
          };
          services.asterisk.pjsip = {
            transports.udp = {};
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "trunk";
            };
          };
        })
      ];
      calls = map (sample: removeAttrs sample ["steps"] // {context = "pbx-internal";}) (samples c);
    })
  cases;
in
  pkgs.runCommand "asterisk-pbx-outbound-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON (map (c: map (sample: sample.steps) (samples c)) cases);
    passAsFile = ["expected"];
  } ''
    for result in ${lib.escapeShellArgs results}; do
      jq '[.calls[] | . as $call | .channel as $channel | [.steps[] | select(.channel == $channel) | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"]
        | if . == [] and any($call.log[]; .message | startswith("No such extension/context")) then ["no such extension"] else . end]' \
        "$result/probe.json"
    done | jq -s . > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${lib.concatStringsSep " " results}" >&2
      exit 1
    fi
    touch $out
  ''
