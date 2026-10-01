# Queues of pbx.queues with extensions as members, through the probe
# (tests/campaign/probe.nix): a call to the queue rings every device of each
# member, and app_queue takes each member's state from its extension's
# endpoint. The phones are this Asterisk itself, at static contacts that ring
# without answering.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  # the devices of each member, as the user parts of their contacts
  devices = {
    "201" = ["2011" "2012"];
    "202" = ["2021"];
  };

  result = probe {
    name = "pbx-queues";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: {
        pbx = {
          enable = true;
          extensions = lib.mapAttrs (number: _: {password = config.lib.asterisk.secret "/run/secrets/sip-${number}";}) devices;
          queues.desk = {
            number = "600";
            members = builtins.attrNames devices;
            timeout = 2;
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            endpoints =
              lib.mapAttrs (_: users: {
                aor = {
                  contacts = map (user: "sip:${user}@127.0.0.1:5060") users;
                  qualifyFrequency = 0;
                };
              })
              devices
              // {
                # the devices' side of those calls
                line = {
                  context = "line";
                  identify.match = ["127.0.0.1"];
                  aor = null;
                };
              };
          };
          dialplan.contexts.line.extensions."_20XX" = [
            "NoOp(device \${EXTEN})"
            "Ringing()"
            "Wait(30)"
          ];
        };
      })
    ];
    commands = ["queue show desk"];
    calls = [
      {
        extension = "600";
        context = "pbx-internal";
      }
    ];
  };

  expected = {
    members = [
      "201 (Local/201@pbx-devices/n from PJSIP/201)"
      "202 (Local/202@pbx-devices/n from PJSIP/202)"
    ];
    rang = map (user: "device ${user}") (lib.concatLists (builtins.attrValues devices));
  };
in
  pkgs.runCommand "asterisk-pbx-queues-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # the members `queue show` lists, and the devices that rang
    jq -S '{
      members: [.commands[0].output | split("\n")[] | select(startswith("      ")) | capture("^ +(?<m>[^ ]+ [(][^)]*[)])").m] | sort,
      rang: [.calls[0].steps[] | select(.context == "line" and .application == "NoOp") | .data] | unique
    }' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the queue rang other devices, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
