# An outside member of a ring group through the probe
# (tests/campaign/probe.nix): the trunk leads back to the same Asterisk on
# 127.0.0.1, where the outside number answers and hangs up a second later,
# during the prompt to press 1. Only 1 takes the call, so the group rings on
# for its ring time and then goes to its no-answer destination, and the
# caller is never answered.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  result = probe {
    name = "pbx-external";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        pbx = {
          enable = true;
          extensions."201".password = secret "sip-201";
          ringGroups.sales = {
            number = "600";
            members = ["201"];
            external = ["5551234"];
            trunk = "loop";
            ringTime = 4;
            noAnswer.context.context = "done";
          };
          inbound."5551234" = {
            trunk = "loop";
            destination.context.context = "answer-hangup";
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            trunks.loop = {
              host = "127.0.0.1";
              username = "5551000";
              password = secret "trunk";
              register = false;
            };
          };
          dialplan.contexts = {
            answer-hangup.extensions.s = ["Answer()" "Wait(1)" "Hangup()"];
            done.extensions.s = ["NoOp(done)" "Hangup()"];
          };
        };
      })
    ];
    calls = [
      {
        extension = "600";
        context = "pbx-internal";
      }
    ];
  };

  expected = {
    answered = false;
    steps = [
      "pbx-internal,600,1,Goto(pbx-ringgroup-sales,s,1)"
      "pbx-ringgroup-sales,s,1,Dial(&Local/5551234@pbx-ringgroup-sales/n,4,b(pbx-confirm^leg^1))"
      "pbx-ringgroup-sales,s,2,Goto(done,s,1)"
      "done,s,1,NoOp(done)"
      "done,s,2,Hangup()"
    ];
  };
in
  pkgs.runCommand "asterisk-pbx-external-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    jq '.calls[0] | .channel as $channel
      | {answered, steps: [.steps[] | select(.channel == $channel) | "\(.context),\(.extension),\(.priority),\(.application)(\(.data))"]}' \
      ${result}/probe.json > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the caller did not reach the no-answer destination, see ${result}" >&2
      exit 1
    fi
    touch $out
  ''
