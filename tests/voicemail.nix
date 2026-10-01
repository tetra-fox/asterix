# Typed mailboxes through the probe (tests/campaign/probe.nix): VM_INFO, as
# AMI's Getvar reads it, gives the e-mail address of a mailbox that has one
# and an empty one for a mailbox without, and Asterisk keeps running.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  addresses = {
    "200" = null;
    "201" = "bob@example.org";
  };

  result = probe {
    name = "voicemail";
    modules = [
      ({config, ...}: {
        services.asterisk = {
          enable = true;
          voicemail = {
            mailboxes =
              lib.mapAttrs (box: email: {
                pin = config.lib.asterisk.secret "/run/secrets/vm-${box}";
                inherit email;
              })
              addresses;
            email.command = "${pkgs.coreutils}/bin/true";
          };
        };
      })
    ];
    commands = lib.mapAttrsToList (box: _: "dialplan eval function VM_INFO(${box}@default,email)") addresses;
  };

  expected = lib.mapAttrsToList (_: email: "Return Value: Success (0)\nResult: ${toString email}\n") addresses;
in
  pkgs.runCommand "asterisk-voicemail-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    if ! diff -u <(jq . "$expectedPath") <(jq '[.commands[].output]' ${result}/probe.json); then
      echo "VM_INFO read something else, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
