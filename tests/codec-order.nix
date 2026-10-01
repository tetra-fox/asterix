# codecs an endpoint allows, defined in several modules,
# come in module order, and lib.mkBefore and lib.mkAfter move theirs to the
# front and the end, for a typed endpoint, for the section it writes and for
# a layer-1 endpoint. `pjsip show endpoint` lists them in that order.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  result = probe {
    name = "codec-order";
    modules = [
      ({config, ...}: {
        services.asterisk = {
          enable = true;
          pjsip = {
            transports.udp = {};
            endpoints."101" = {
              context = "phones";
              auth.password = config.lib.asterisk.secret "/run/secrets/101";
              allow = [
                "g722"
                "ulaw"
              ];
            };
          };
          settings."pjsip.conf".layer-one = {
            name = "102";
            type = "endpoint";
            context = "phones";
            disallow = "all";
            allow = [
              "g722"
              "ulaw"
            ];
          };
          dialplan.contexts.phones.extensions."_1XX" = ["Dial(PJSIP/\${EXTEN})"];
        };
      })
      {services.asterisk.pjsip.endpoints."101".allow = ["alaw"];}
      {services.asterisk.pjsip.endpoints."101".allow = lib.mkAfter ["g726"];}
      {services.asterisk.pjsip.endpoints."101".allow = lib.mkBefore ["gsm"];}
      {services.asterisk.settings."pjsip.conf"."endpoint:101".allow = lib.mkBefore ["opus"];}
      {services.asterisk.settings."pjsip.conf".layer-one.allow = ["alaw"];}
      {services.asterisk.settings."pjsip.conf".layer-one.allow = lib.mkAfter ["g726"];}
      {services.asterisk.settings."pjsip.conf".layer-one.allow = lib.mkBefore ["gsm"];}
    ];
    commands = [
      "pjsip show endpoint 101"
      "pjsip show endpoint 102"
    ];
  };

  # `allow` of each endpoint, the codecs in the order Asterisk prefers them
  expected = {
    "pjsip show endpoint 101" = "(opus|gsm|g722|ulaw|alaw|g726)";
    "pjsip show endpoint 102" = "(gsm|g722|ulaw|alaw|g726)";
  };
in
  pkgs.runCommand "asterisk-codec-order-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    jq -r --slurpfile expected "$expectedPath" '
      .commands[]
      | {command, allow: [.output | split("\n")[] | select(startswith(" allow ")) | sub("^ allow +: "; "")]}
      | select(.allow != [$expected[0][.command]])
      | "`\(.command)` lists \(.allow | tojson) as allow, not \($expected[0][.command])"
    ' ${result}/probe.json > wrong
    if [ -s wrong ]; then
      cat wrong >&2
      exit 1
    fi
    touch $out
  ''
