# Numbers that overlap without clashing, dialled through the probe
# (tests/campaign/probe.nix): the outbound pattern _9X. also matches the ring
# group on 9000 and the emergency numbers 911 and 9911, a pattern added to
# pbx-internal also matches extension 201, and in a menu with direct dial, key
# 2 starts 201. Asterisk takes a number before a pattern of the same context
# and before the contexts it includes, and a key that starts a longer number
# counts on its own once no digit follows within 5 s. From a trunk, a number
# of pbx.inbound goes before its patterns, of which the more specific one
# takes a number both match, and s takes a call that names no number.
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
        "pbx-ringgroup-big,s,2,Hangup(19)"
      ];
    }
    {
      extension = "9123";
      steps = [
        "pbx-internal,9123,1,Dial(PJSIP/123@provider)"
        "pbx-internal,9123,2,GotoIf(0?busy)"
        "pbx-internal,9123,3,Congestion()"
      ];
    }
    {
      extension = "911";
      steps = [
        "pbx-internal,911,1,Goto(pbx-emergency,911,1)"
        "pbx-emergency,911,1,Dial(PJSIP/911@provider)"
        "pbx-emergency,911,2,GotoIf(0?busy)"
        "pbx-emergency,911,3,Congestion()"
      ];
    }
    {
      extension = "9911";
      steps = [
        "pbx-internal,9911,1,Goto(pbx-emergency,911,1)"
        "pbx-emergency,911,1,Dial(PJSIP/911@provider)"
        "pbx-emergency,911,2,GotoIf(0?busy)"
        "pbx-emergency,911,3,Congestion()"
      ];
    }
    {
      extension = "201";
      steps = ["pbx-internal,201,1,Goto(pbx-extension-201,s,1)"] ++ extension201 "19";
    }
    {
      extension = "250";
      steps = ["pbx-internal,250,1,Hangup()"];
    }
    {
      extension = "700";
      keys = "201";
      steps = menu ++ ["pbx-ivr-menu,201,1,Goto(pbx-extension-201,s,1)"] ++ extension201 "";
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
  # calls from the trunk, and the context of the route each takes
  fromTrunk =
    map (call: {
      context = "pbx-inbound-provider";
      inherit (call) extension;
      steps = [
        "pbx-inbound-provider,${call.extension},1,Goto(${call.route},s,1)"
        "${call.route},s,1,Hangup()"
      ];
    }) [
      {
        extension = "5551000";
        route = "number";
      }
      {
        extension = "5559999";
        route = "pattern";
      }
      {
        extension = "4441000";
        route = "wide-pattern";
      }
      {
        extension = "s";
        route = "no-number";
      }
    ];
  # 201 has no phone and hangs up, with no answer (19) on a call not answered
  # yet and with no cause after the menu answered
  extension201 = cause: [
    "pbx-extension-201,s,1,Dial(,20)"
    "pbx-extension-201,s,2,GotoIf(0?busy)"
    "pbx-extension-201,s,3,Hangup(${cause})"
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
          inbound =
            builtins.mapAttrs (_: route: {
              trunk = "provider";
              destination.context.context = route;
            }) {
              "5551000" = "number";
              "_555XXXX" = "pattern";
              "_X." = "wide-pattern";
              s = "no-number";
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
          dialplan.contexts =
            {
              pbx-internal.extensions."_2XX" = ["Hangup()"];
            }
            // pkgs.lib.genAttrs ["two" "number" "pattern" "wide-pattern" "no-number"] (_: {extensions.s = ["Hangup()"];});
        };
      })
    ];
    calls = map (sample: {context = "pbx-internal";} // removeAttrs sample ["steps"]) (samples ++ fromTrunk);
  };
in
  pkgs.runCommand "asterisk-pbx-numbering-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON (map (sample: sample.steps) (samples ++ fromTrunk));
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
