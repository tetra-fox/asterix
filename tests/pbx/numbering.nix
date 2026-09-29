# Numbers that overlap without clashing, dialled through the probe
# (tests/campaign/probe.nix): the outbound pattern _9X. also matches the ring
# group on 9000 and the emergency numbers 911 and 9911, a pattern added to
# pbx-internal also matches extension 201, and in a menu with direct dial, key
# 2 starts 201. Asterisk takes a number before a pattern of the same context
# and before the contexts it includes, and a key that starts a longer number
# counts on its own once no digit follows within 5 s.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  # a phone dialling `extension`, and the steps of its call
  samples = [
    {
      extension = "9000";
      steps = [
        "pbx-internal,9000,1,Goto(pbx-ringgroup-big,s,1)"
        "pbx-ringgroup-big,s,1,Dial(,20)"
        "pbx-ringgroup-big,s,2,Hangup()"
      ];
    }
    {
      extension = "9123";
      steps = [
        "pbx-internal,9123,1,Dial(PJSIP/123@provider)"
        "pbx-internal,9123,2,Hangup()"
      ];
    }
    {
      extension = "911";
      steps = [
        "pbx-internal,911,1,Goto(pbx-emergency,911,1)"
        "pbx-emergency,911,1,Dial(PJSIP/911@provider)"
        "pbx-emergency,911,2,Hangup()"
      ];
    }
    {
      extension = "9911";
      steps = [
        "pbx-internal,9911,1,Goto(pbx-emergency,911,1)"
        "pbx-emergency,911,1,Dial(PJSIP/911@provider)"
        "pbx-emergency,911,2,Hangup()"
      ];
    }
    {
      extension = "201";
      steps = ["pbx-internal,201,1,Goto(pbx-extension-201,s,1)"] ++ extension201;
    }
    {
      extension = "250";
      steps = ["pbx-internal,250,1,Hangup()"];
    }
    {
      extension = "700";
      keys = "201";
      steps = menu ++ ["pbx-ivr-menu,201,1,Goto(pbx-extension-201,s,1)"] ++ extension201;
    }
    {
      extension = "700";
      keys = "2";
      steps =
        menu
        ++ [
          "pbx-ivr-menu,2,1,Goto(two,s,1)"
          "two,s,1,Hangup()"
        ];
    }
  ];
  extension201 = [
    "pbx-extension-201,s,1,Dial(,20)"
    "pbx-extension-201,s,2,GotoIf(0?busy)"
    "pbx-extension-201,s,3,Hangup()"
  ];
  menu = [
    "pbx-internal,700,1,Goto(pbx-ivr-menu,s,1)"
    "pbx-ivr-menu,s,1,Answer()"
    "pbx-ivr-menu,s,2,Set(PBX_ATTEMPT=0)"
    "pbx-ivr-menu,s,3,Set(PBX_ATTEMPT=1)"
    "pbx-ivr-menu,s,4,BackGround(beep)"
  ];

  result = probe {
    name = "pbx-numbering";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        pbx = {
          enable = true;
          extensions."201".password = secret "sip-201";
          ringGroups.big = {
            number = "9000";
            members = ["201"];
          };
          ivrs.menu = {
            number = "700";
            prompt.sound = "beep";
            directDial = true;
            options."2".context.context = "two";
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
          };
          emergency = {
            numbers = ["911"];
            trunk = "provider";
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
          };
          dialplan.contexts = {
            pbx-internal.extensions."_2XX" = ["Hangup()"];
            two.extensions.s = ["Hangup()"];
          };
        };
      })
    ];
    calls = map (sample: removeAttrs sample ["steps"] // {context = "pbx-internal";}) samples;
  };
in
  pkgs.runCommand "asterisk-pbx-numbering-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON (map (sample: sample.steps) samples);
    passAsFile = ["expected"];
  } ''
    jq '[.calls[] | .channel as $channel | [.steps[] | select(.channel == $channel) | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"]]' \
      ${result}/probe.json > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
