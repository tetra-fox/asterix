# The probe (tests/campaign/probe.nix) on a small dialplan: how it reports
# each way a call ends, and that the caller ID, the time and the keys of a
# call reach the dialplan.
{
  pkgs,
  self,
}: let
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  whenOpen = "GotoIfTime(09:00-17:00,mon-fri,*,*,${pkgs.tzdata}/share/zoneinfo/America/Los_Angeles?open)";

  result = probe {
    name = "probe";
    modules = [
      {
        services.asterisk = {
          enable = true;
          dialplan.contexts.test.extensions = {
            callerid = [
              "NoOp(\${CALLERID(name)}|\${CALLERID(num)})"
              "Hangup()"
            ];
            hours = [
              whenOpen
              "NoOp(closed)"
              "Hangup()"
              {
                app = "NoOp";
                args = ["open"];
                label = "open";
              }
              "Hangup()"
            ];
            # as pbx.ivrs reads a key
            menu = [
              "Answer()"
              "Background(silence/5)"
              "WaitExten(10)"
            ];
            "1" = [
              "NoOp(one)"
              "Hangup()"
            ];
            # no device to dial
            unavailable = ["Dial(&)"];
            dangling = ["Goto(nowhere,s,1)"];
            forever = [
              "Answer()"
              "Wait(30)"
            ];
          };
        };
      }
    ];
    commands = ["dialplan show 1@test"];
    calls = [
      {
        extension = "callerid";
        context = "test";
        callerId = ''"Boss" <203>'';
      }
      # 10:00 and 17:30 on a Wednesday in Los Angeles, the second a Thursday in UTC
      {
        extension = "hours";
        context = "test";
        time = "2026-12-02T10:00:00-08:00";
      }
      {
        extension = "hours";
        context = "test";
        time = "2026-12-02T17:30:00-08:00";
      }
      {
        extension = "menu";
        context = "test";
        keys = "1";
      }
      {
        extension = "unavailable";
        context = "test";
      }
      {
        extension = "dangling";
        context = "test";
      }
      {
        extension = "forever";
        context = "test";
        limit = 1;
      }
    ];
  };

  expected = {
    # the output starts with it, whatever the CLI client printed first
    commands = ["[ Context 'test' created by 'pbx_config' ]"];
    calls = [
      {
        answered = false;
        limitReached = false;
        steps = [
          "test,callerid,1,NoOp(Boss|203)"
          "test,callerid,2,Hangup()"
        ];
        ended = [
          {
            application = "Hangup";
            how = "hangup";
          }
        ];
      }
      {
        answered = false;
        limitReached = false;
        steps = [
          "test,hours,1,${whenOpen}"
          "test,hours,4,NoOp(open)"
          "test,hours,5,Hangup()"
        ];
        ended = [
          {
            application = "Hangup";
            how = "hangup";
          }
        ];
      }
      {
        answered = false;
        limitReached = false;
        steps = [
          "test,hours,1,${whenOpen}"
          "test,hours,2,NoOp(closed)"
          "test,hours,3,Hangup()"
        ];
        ended = [
          {
            application = "Hangup";
            how = "hangup";
          }
        ];
      }
      {
        answered = true;
        limitReached = false;
        steps = [
          "test,menu,1,Answer()"
          "test,menu,2,BackGround(silence/5)"
          "test,1,1,NoOp(one)"
          "test,1,2,Hangup()"
        ];
        ended = [
          {
            application = "Hangup";
            how = "hangup";
          }
        ];
      }
      {
        answered = false;
        limitReached = false;
        steps = ["test,unavailable,1,Dial(&)"];
        ended = [
          {
            application = "Dial";
            how = "fallthrough";
            status = "CHANUNAVAIL";
          }
        ];
      }
      {
        answered = false;
        limitReached = false;
        steps = ["test,dangling,1,Goto(nowhere,s,1)"];
        ended = [
          {
            application = "Goto";
            how = "invalid";
          }
        ];
      }
      {
        answered = true;
        limitReached = true;
        steps = [
          "test,forever,1,Answer()"
          "test,forever,2,Wait(30)"
        ];
        ended = [
          {
            application = "Wait";
            how = "hangup";
          }
        ];
      }
    ];
  };
in
  pkgs.runCommand "asterisk-probe-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # the first line of each output, and each call as the expectation writes it
    jq -S '{
      commands: [.commands[].output | split("\n")[0]],
      calls: [.calls[] | {
        answered,
        limitReached,
        steps: [.steps[] | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"],
        ended: [.ended[] | {application, how} + (if .status then {status} else {} end)]
      }]
    }' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the probe reported something else, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
