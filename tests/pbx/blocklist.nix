# Callers of services.asterix.blocklist calling in from a trunk, through the
# probe (tests/campaign/probe.nix): a number matches only in the form it is
# written in, a pattern matches as a dialled number does, and anonymous turns
# away callers with no number, with anonymous, restricted or unavailable for
# one in any case, or with a withheld presentation. A number of
# services.asterix.inbound with `blocklist = false` lets them all through.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  # what pbx-blocklist's s runs for a caller listed by number (s/<number>),
  # one with a withheld presentation or no number, one whose number is
  # anonymous, restricted or unavailable, and one it lets through
  listed = ["pbx-blocklist,s,1,Return(blocked)"];
  withheld = ["pbx-blocklist,s,1,GotoIf(1?withheld)" "pbx-blocklist,s,4,Return(blocked)"];
  anonymous = ["pbx-blocklist,s,1,GotoIf(0?withheld)" "pbx-blocklist,s,2,GotoIf(1?withheld)" "pbx-blocklist,s,4,Return(blocked)"];
  passes = ["pbx-blocklist,s,1,GotoIf(0?withheld)" "pbx-blocklist,s,2,GotoIf(0?withheld)" "pbx-blocklist,s,3,Return()"];

  # a call to 5551000 that pbx-blocklist turns away after `checks`, and one
  # it lets through
  turnedAway = checks:
    ["pbx-inbound-loop,5551000,1,Gosub(pbx-blocklist,s,1)"]
    ++ checks
    ++ [
      "pbx-inbound-loop,5551000,2,GotoIf(1?pbx-blocklist,blocked,1)"
      "pbx-blocklist,blocked,1,Hangup(19)"
    ];
  letThrough =
    ["pbx-inbound-loop,5551000,1,Gosub(pbx-blocklist,s,1)"]
    ++ passes
    ++ [
      "pbx-inbound-loop,5551000,2,GotoIf(0?pbx-blocklist,blocked,1)"
      "pbx-inbound-loop,5551000,3,Goto(allowed,s,1)"
      "allowed,s,1,Hangup()"
    ];
  unchecked = ["pbx-inbound-loop,5552000,1,Goto(allowed,s,1)" "allowed,s,1,Hangup()"];

  samples = [
    {
      callerId = "+15551234567";
      steps = turnedAway listed;
    }
    {
      callerId = "15551234567";
      steps = turnedAway listed;
    }
    {
      callerId = ''"Someone" <5551234567>'';
      steps = turnedAway listed;
    }
    # _1800XXXXXXX: eleven digits that start with 1800
    {
      callerId = "18005550199";
      steps = turnedAway listed;
    }
    {
      callerId = "1800555019";
      steps = letThrough;
    }
    # a listed number inside a longer one
    {
      callerId = "25551234567";
      steps = letThrough;
    }
    {
      callerId = ''"Anonymous" <anonymous>'';
      steps = turnedAway anonymous;
    }
    {
      callerId = "<RESTRICTED>";
      steps = turnedAway anonymous;
    }
    {
      callerId = "<Unavailable>";
      steps = turnedAway anonymous;
    }
    {
      callerId = "<anonymous2>";
      steps = letThrough;
    }
    # no number at all
    {
      steps = turnedAway withheld;
    }
    # a number with a withheld presentation, as a trunk that trusts
    # P-Asserted-Identity sets it for Privacy: id
    {
      context = "withheld";
      extension = "s";
      callerId = "5559876543";
      steps =
        [
          "withheld,s,1,Set(CALLERID(pres)=prohib_not_screened)"
          "withheld,s,2,Goto(pbx-inbound-loop,5551000,1)"
        ]
        ++ turnedAway withheld;
    }
    {
      callerId = "5559876543";
      steps = letThrough;
    }
    # blocklist = false
    {
      extension = "5552000";
      callerId = "5551234567";
      steps = unchecked;
    }
    {
      extension = "5552000";
      steps = unchecked;
    }
  ];

  result = probe {
    name = "pbx-blocklist";
    modules = [
      self.nixosModules.default
      ({config, ...}: {
        services.asterix = {
          enable = true;
          blocklist = {
            numbers = ["+15551234567" "15551234567" "5551234567" "_1800XXXXXXX"];
            anonymous = true;
          };
          inbound = {
            "5551000" = {
              trunk = "loop";
              destination.context.context = "allowed";
            };
            "5552000" = {
              trunk = "loop";
              destination.context.context = "allowed";
              blocklist = false;
            };
          };
          trunks.loop = {
            host = "127.0.0.1";
            username = "5551000";
            password = config.lib.asterisk.secret "/run/secrets/trunk";
            register = false;
          };
        };
        services.asterisk.dialplan.contexts = {
          allowed.extensions.s = ["Hangup()"];
          withheld.extensions.s = [
            "Set(CALLERID(pres)=prohib_not_screened)"
            "Goto(pbx-inbound-loop,5551000,1)"
          ];
        };
      })
    ];
    calls = map (sample:
      {
        context = "pbx-inbound-loop";
        extension = "5551000";
      }
      // removeAttrs sample ["steps"])
    samples;
  };
in
  pkgs.runCommand "asterisk-pbx-blocklist-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON (map (sample: sample.steps) samples);
    passAsFile = ["expected"];
  } ''
    jq '[.calls[] | .channel as $channel | [.steps[] | select(.channel == $channel) | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"]]' \
      ${result}/probe.json > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the callers were not turned away or let through as listed, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
