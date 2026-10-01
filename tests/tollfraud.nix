# Every way from a trunk to a trunk's Dial (SEC-03), walked through the
# dialplan Asterisk loads (tests/campaign/tollfraud.nix): the examples have
# none, and the walk finds each way out built in here, the outside member of
# a ring group, which the configuration names, among them.
{
  pkgs,
  self,
  # the examples' configurations
  examples,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig;
  tollfraud = import ./campaign/tollfraud.nix {inherit pkgs self;};

  office = {config, ...}: let
    secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
  in {
    imports = [self.nixosModules.pbx];
    pbx = {
      enable = true;
      extensions = {
        "201".password = secret "sip-201";
        "202".password = secret "sip-202";
      };
      outbound = {
        prefix = "9";
        trunk = "provider";
      };
      emergency = {
        numbers = ["911"];
        trunk = "provider";
      };
    };
    services.asterisk.pjsip = {
      transports.udp = {};
      trunks.provider = {
        host = "sip.provider.example";
        username = "5551000";
        password = secret "trunk";
      };
    };
  };

  # each configuration and the ways out its walk finds: the trunk the call
  # comes from, the trunk it goes out through, the number and why it is a
  # finding, or null for a named one
  cases = {
    # calls from the trunk start where the phones dial from, which takes 9
    # and any number, and 911; pbx takes that only from a tie line
    trunkInPhoneContext = {
      modules = [
        office
        {
          pbx.tieLines = ["provider"];
          services.asterisk.pjsip.trunks.provider.context = "pbx-internal";
        }
      ];
      paths = [
        ["provider" "provider" "911" "a number the configuration does not name"]
        ["provider" "provider" "<caller>" "the caller chooses the number"]
      ];
    };
    # a menu whose key 1 rings a group with an outside member, and key 2 a
    # context of its own that reads the number it dials
    menu = {
      modules = [
        office
        {
          pbx = {
            ringGroups.cell = {
              members = ["202"];
              external = ["5559000"];
            };
            extensions."201".noAnswer.ringGroup = "cell";
            ivrs.main = {
              prompt.sound = "beep";
              directDial = true;
              options = {
                "1".ringGroup = "cell";
                "2".context.context = "callback";
              };
            };
            inbound."5551000" = {
              trunk = "provider";
              destination.ivr = "main";
            };
          };
          services.asterisk.dialplan.contexts.callback.extensions.s = [
            "Read(NUMBER,beep,10)"
            "Dial(PJSIP/\${NUMBER}@provider)"
          ];
        }
      ];
      paths = [
        ["provider" "provider" "5559000" null]
        ["provider" "provider" "<caller>" "the caller chooses the number"]
      ];
    };
    # a ring group whose name has a /, an @ and a {, which its Local channels
    # and Dial's arguments carry
    groupNamedOddly = {
      modules = [
        office
        {
          pbx = {
            ringGroups."a/b@c{d" = {
              members = ["202"];
              external = ["5559001"];
            };
            inbound."5551000" = {
              trunk = "provider";
              destination.ringGroup = "a/b@c{d";
            };
          };
        }
      ];
      paths = [
        ["provider" "provider" "5559001" null]
      ];
    };
    # the core alone: the trunk's context includes the phones', which dials
    # out
    inboundIncludesPhones = {
      modules = [
        ({config, ...}: {
          services.asterisk = {
            enable = true;
            pjsip = {
              transports.udp = {};
              trunks.provider = {
                host = "sip.provider.example";
                username = "5551000";
                password = config.lib.asterisk.secret "/run/secrets/trunk";
                context = "from-provider";
              };
            };
            dialplan.contexts = {
              from-provider = {
                includes = ["phones"];
                extensions."5551000" = ["Dial(PJSIP/201,20)"];
              };
              phones.extensions = {
                "_2XX" = ["Dial(PJSIP/\${EXTEN},20)"];
                "_9X." = ["Dial(PJSIP/\${EXTEN:1}@provider,60)"];
              };
            };
          };
        })
      ];
      paths = [
        ["provider" "provider" "<caller>" "the caller chooses the number"]
      ];
    };
  };

  walks =
    lib.mapAttrs (name: config: {
      report = tollfraud {inherit name config;};
      paths = [];
    })
    examples
    // lib.mapAttrs (name: case: {
      report = tollfraud {
        inherit name;
        config = evalConfig case.modules;
      };
      inherit (case) paths;
    })
    cases;
in
  pkgs.runCommand "asterisk-tollfraud-tests" {nativeBuildInputs = [pkgs.jq];} ''
    ${lib.concatStrings (lib.mapAttrsToList (name: walk: ''
        jq -c '[.paths[] | [.from, .via, .number, .finding]], .unresolved' ${walk.report}/report.json > actual
        printf '%s\n%s\n' ${lib.escapeShellArg (builtins.toJSON walk.paths)} '[]' | jq -c . > expected
        if ! diff -u expected actual; then
          echo "${name}: the walk found other ways out, see ${walk.report}" >&2
          exit 1
        fi
      '')
      walks)}
    touch $out
  ''
