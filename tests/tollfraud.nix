# Every way from a trunk to a trunk's Dial, walked through the dialplan
# Asterisk loads (tests/campaign/tollfraud.nix): small-office, the example
# with a trunk, has none, and the walk finds each way out built in here, the
# outside member of a ring group, which the configuration names, among them.
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
    imports = [self.nixosModules.default];
    services.asterix = {
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
      trunks.provider = {
        host = "sip.provider.example";
        username = "5551000";
        password = secret "trunk";
      };
    };
  };

  # 201 takes the calls to 5551000 and forwards them to the number its phone
  # stored, and the calls from trunk other start in `codes`
  forwarding = codes: {config, ...}: {
    services.asterix = {
      featureCodes.forward.always = {
        on = "*72";
        off = "*73";
      };
      inbound."5551000" = {
        trunk = "provider";
        destination.extension = "201";
      };
      trunks.other = {
        host = "sip.other.example";
        username = "5552000";
        password = config.lib.asterisk.secret "/run/secrets/other";
        context = "codes";
      };
    };
    services.asterisk.dialplan.contexts.codes.extensions."_X." = codes;
  };

  # each configuration and the ways out its walk finds: the trunk the call
  # comes from, the trunk it goes out through, the number and why it is a
  # finding, or null for a named one
  cases = {
    # the forward code keys the number by the endpoint that dials it, so a
    # trunk that reaches it stores a number for itself and not for 201
    forward = {
      modules = [
        office
        (forwarding [
          "Set(PBX_TARGET=\${EXTEN})"
          "Goto(pbx-features,always-on,1)"
        ])
      ];
      paths = [
        ["provider" "provider" "<stored>" null]
      ];
    };
    # a context of its own that stores the caller's number as 201's forward,
    # which leaves 202's, where 201's may lead, to its phone
    forwardFromTrunk = {
      modules = [
        office
        (forwarding [
          "Set(DB(pbx-forward/201/always)=\${EXTEN})"
          "Hangup()"
        ])
      ];
      paths = [
        ["provider" "provider" "<caller>" "the caller chooses the number"]
        ["provider" "provider" "<stored>" null]
      ];
    };
    # calls from the trunk start where the phones dial from, which takes 9
    # and any number, and 911; pbx takes that only from a tie line
    trunkInPhoneContext = {
      modules = [
        office
        {
          services.asterix = {
            tieLines = ["provider"];
            trunks.provider.context = "pbx-internal";
          };
        }
      ];
      paths = [
        ["provider" "provider" "911" "a number the configuration does not name"]
        ["provider" "provider" "<caller>" "the caller chooses the number"]
      ];
    };
    # a menu whose key 1 rings a group with an outside member, whose name has
    # a /, an @ and a {, which its Local channels and Dial's arguments carry,
    # and key 2 a context of its own that reads the number it dials
    menu = {
      modules = [
        office
        {
          services.asterix = {
            ringGroups."a/b@c{d" = {
              members = ["202"];
              external = ["5559000"];
            };
            extensions."201".noAnswer.ringGroup = "a/b@c{d";
            ivrs.main = {
              prompt.sound = "beep";
              directDial = true;
              options = {
                "1".ringGroup = "a/b@c{d";
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
  };

  walks =
    {
      small-office = {
        report = tollfraud {
          name = "small-office";
          config = examples.small-office;
        };
        paths = [];
      };
    }
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
