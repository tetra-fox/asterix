# Voice menus through the probe (tests/campaign/probe.nix), for what the
# generated configurations' probe runs leave out (PBX-08): a menu with five
# attempts, which plays its prompt five times before its no-input
# destination, also after a key without a destination, and keys pressed in
# the menu the first one leads to, a nested one or the menu itself. `w` in
# the keys waits half a second, so a key reaches the next menu.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  # each call, the contexts its channel passes through, the prompts it
  # hears and where its dialplan ends
  samples = [
    {
      call = {
        extension = "702";
        context = "pbx-internal";
      };
      contexts = [
        "pbx-internal"
        "pbx-ivr-five"
        "done"
      ];
      prompts = ["beep" "beep" "beep" "beep" "beep"];
      ended = "five";
    }
    # a key without a destination on the first attempt, none after it
    {
      call = {
        extension = "702";
        context = "pbx-internal";
        keys = "3";
      };
      contexts = [
        "pbx-internal"
        "pbx-ivr-five"
        "done"
      ];
      prompts = ["beep" "beep" "beep" "beep" "beep"];
      ended = "five";
    }
    {
      call = {
        extension = "703";
        context = "pbx-internal";
        keys = "1ww2";
      };
      contexts = [
        "pbx-internal"
        "pbx-ivr-top"
        "pbx-ivr-sub"
        "done"
      ];
      prompts = ["beep" "silence/1"];
      ended = "sub";
    }
    {
      call = {
        extension = "703";
        context = "pbx-internal";
        keys = "9ww1ww2";
      };
      contexts = [
        "pbx-internal"
        "pbx-ivr-top"
        "pbx-ivr-sub"
        "done"
      ];
      prompts = ["beep" "beep" "silence/1"];
      ended = "sub";
    }
  ];

  result = probe {
    name = "pbx-menus";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: {
        pbx = {
          enable = true;
          extensions."201".password = config.lib.asterisk.secret "/run/secrets/sip-201";
          ivrs = {
            five = {
              number = "702";
              prompt.sound = "beep";
              attempts = 5;
              timeout = 1;
              noInput.context = {
                context = "done";
                extension = "five";
              };
              invalid.hangup = true;
            };
            top = {
              number = "703";
              prompt.sound = "beep";
              options = {
                "1".ivr = "sub";
                "9".ivr = "top";
              };
            };
            sub = {
              prompt.sound = "silence/1";
              attempts = 1;
              options."2".context = {
                context = "done";
                extension = "sub";
              };
            };
          };
        };
        services.asterisk = {
          pjsip.transports.udp = {};
          dialplan.contexts.done.extensions = {
            five = ["Hangup()"];
            sub = ["Hangup()"];
          };
        };
      })
    ];
    calls = map (sample: sample.call) samples;
  };

  expected =
    map (sample: {
      inherit (sample) contexts prompts;
      ended = [
        {
          context = "done";
          extension = sample.ended;
          application = "Hangup";
          how = "hangup";
        }
      ];
      answered = true;
    })
    samples;
in
  pkgs.runCommand "asterisk-pbx-menus-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # each call's own channel, not the phone it calls
    jq -S '[.calls[] | .channel as $channel | [.steps[] | select(.channel == $channel)] as $steps | {
      contexts: reduce ($steps[] | .context) as $context ([]; if last == $context then . else . + [$context] end),
      prompts: [$steps[] | select(.application == "BackGround") | .data],
      ended: [.ended[] | select(.channel == $channel) | {context, extension, application, how}],
      answered
    }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
