# P7: a string written through the options reads back from Asterisk
# unchanged, through the CLI and, in the dialplan, as the data of a step.
# The value has every character that means something in a configuration
# file, the dialplan or an argument list.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  value = ''a;b "c" 'd' \e (f) [g] {h} <i> |j =k =>l &m ^n %o #p !q ?r *s ,t ü @u /v ~w'';
  # a mailbox line splits at commas, which the option rejects
  noComma = lib.replaceStrings [","] [""] value;

  result = probe {
    name = "roundtrip";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        # the name goes into the endpoint's caller ID, "name" <number>
        pbx = {
          enable = true;
          extensions."202" = {
            name = value;
            password = secret "202";
          };
        };
        services.asterisk = {
          enable = true;
          pjsip = {
            transports.udp = {};
            endpoints."101" = {
              context = "roundtrip";
              auth.password = secret "101";
              settings.accountcode = value;
            };
          };
          dialplan = {
            globals.ROUNDTRIP = value;
            contexts.roundtrip.extensions."1" = ["NoOp(${value})"];
          };
          queues.queues.roundtrip.members = [
            {
              interface = "PJSIP/101";
              name = value;
            }
          ];
          voicemail.mailboxes."101" = {
            fullName = noComma;
            pin = secret "vm-101";
          };
        };
      })
    ];
    commands = [
      "dialplan show globals"
      "dialplan show roundtrip"
      "pjsip show endpoint 101"
      "pjsip show endpoint 202"
      "queue show roundtrip"
      "voicemail show users"
    ];
    calls = [
      {
        extension = "1";
        context = "roundtrip";
      }
    ];
  };

  # where each command shows the value, with what surrounds it there
  shown = [
    {
      command = "dialplan show globals";
      text = "   ROUNDTRIP=${value}\n";
    }
    {
      command = "dialplan show roundtrip";
      text = "1. NoOp(${value}) ";
    }
    # the name column is as wide as the longest parameter name
    {
      command = "pjsip show endpoint 101";
      text = ": ${value}\n";
    }
    # a caller ID shows its name with \ and " escaped, as it is written
    {
      command = "pjsip show endpoint 202";
      text = ": \"${lib.escape ["\\" "\""] value}\" <202>\n";
    }
    {
      command = "queue show roundtrip";
      text = "      ${value} (PJSIP/101) ";
    }
    {
      command = "voicemail show users";
      text = "default    101   ${noComma} ";
    }
  ];
in
  pkgs.runCommand "asterisk-roundtrip-tests" {
    nativeBuildInputs = [pkgs.jq];
    shown = builtins.toJSON shown;
    inherit value;
    passAsFile = ["shown"];
  } ''
    jq -r --slurpfile shown "$shownPath" '
      .commands as $commands
      | $shown[0][]
      | . as $expected
      | select(any($commands[]; .command == $expected.command and (.output | contains($expected.text))) | not)
      | "`\(.command)` does not show \(.text | tojson), but:\n\($commands[] | select(.command == $expected.command) | .output)"
    ' ${result}/probe.json > missing
    jq -r --arg value "$value" '
      [.calls[0].steps[] | {application, data}]
      | select(. != [{application: "NoOp", data: $value}])
      | "the call ran \(tojson) instead of NoOp(\($value))"
    ' ${result}/probe.json >> missing
    if [ -s missing ]; then
      cat missing >&2
      exit 1
    fi
    touch $out
  ''
