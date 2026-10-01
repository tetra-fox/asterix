# Pages through the probe (tests/campaign/probe.nix): a page to ten members
# of twelve devices each rings all 120 devices, more than fit in the 4,095
# bytes Asterisk keeps of a variable as their dial strings. The phones are
# this Asterisk itself, at static contacts that ring without answering.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  members = map toString (lib.range 201 210);
  # the user parts of a member's contacts: 1201001 to 1201012 for 201
  devicesOf = member: map (i: "1${member}${lib.fixedWidthNumber 3 i}") (lib.range 1 12);

  result = probe {
    name = "pbx-paging";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: {
        pbx = {
          enable = true;
          extensions = lib.genAttrs members (number: {password = config.lib.asterisk.secret "/run/secrets/sip-${number}";});
          paging.all = {
            number = "650";
            inherit members;
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            endpoints =
              lib.genAttrs members (member: {
                aor = {
                  contacts = map (user: "sip:${user}@127.0.0.1:5060") (devicesOf member);
                  qualifyFrequency = 0;
                };
              })
              // {
                # the devices' side of the page
                line = {
                  context = "line";
                  identify.match = ["127.0.0.1"];
                  aor = null;
                };
              };
          };
          dialplan.contexts.line.extensions."_1XXXXXX" = [
            "NoOp(device \${EXTEN})"
            "Ringing()"
            "Wait(30)"
          ];
        };
      })
    ];
    calls = [
      {
        extension = "650";
        context = "pbx-internal";
        limit = 5;
      }
    ];
  };

  expected = map (user: "device ${user}") (lib.concatMap devicesOf members);
in
  pkgs.runCommand "asterisk-pbx-paging-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # the devices that rang
    jq '[.calls[0].steps[] | select(.context == "line" and .application == "NoOp") | .data] | unique' \
      ${result}/probe.json > actual
    if ! diff -u <(jq . "$expectedPath") actual; then
      echo "the page left out devices, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
