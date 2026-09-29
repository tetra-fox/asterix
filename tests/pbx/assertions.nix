# Invalid pbx configurations must fail evaluation with a clear message. The
# result is the list of cases that did not behave as expected (see
# checkCases in ../eval-lib.nix).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) checkCases;
  slots = import ./slots.nix {inherit lib;};

  # A valid baseline with every kind of object, which each case breaks in
  # one place.
  base = {config, ...}: let
    inherit (config.lib.asterisk) secret;
  in {
    imports = [self.nixosModules.pbx];
    pbx = {
      enable = true;
      extensions = {
        "201" = {
          password = secret "/run/secrets/201";
          voicemail.pin = secret "/run/secrets/vm-201";
        };
        "202".password = secret "/run/secrets/202";
      };
      ringGroups.front = {
        number = "600";
        members = [
          "201"
          "202"
        ];
      };
      queues.support.number = "610";
      conferences.board.number = "800";
      ivrs.main = {
        number = "700";
        prompt.sound = "custom/main-menu";
        options."1".ringGroup = "front";
      };
      paging.all = {
        number = "650";
        members = [
          "201"
          "202"
        ];
      };
      hours.office = {
        timezone = "America/Los_Angeles";
        open = [
          {
            days = "mon-fri";
            time = "09:00-17:00";
          }
        ];
      };
      inbound."5551000" = {
        trunk = "provider";
        hours = "office";
        open.ringGroup = "front";
        closed.voicemail = "201";
      };
      outbound = {
        prefix = "9";
        trunk = "provider";
      };
      emergency = {
        numbers = ["911"];
        trunk = "provider";
        notify = ["201"];
      };
    };
    services.asterisk = {
      pjsip = {
        transports.udp = {};
        trunks.provider = {
          host = "sip.provider.example";
          username = "5551000";
          password = secret "/run/secrets/trunk";
        };
      };
      queues.queues.support.members = ["PJSIP/201"];
    };
  };

  # the phones' network, which the provisioning cases add adapters and files to
  phones.pbx.phones = {
    listenAddress = "10.0.20.10";
    allowedNetworks = lib.mkDefault ["10.0.20.0/24"];
  };

  cases = {
    baselineIsValid = {
      module = {};
      assertions = [];
      warnings = [];
    };

    numberWithTwoOwners = {
      module.pbx.conferences.board.number = lib.mkForce "600";
      assertion = "600: pbx.ringGroups.front, pbx.conferences.board";
    };

    # also with the outbound prefix
    extensionOnEmergencyNumber = {
      module = {config, ...}: {
        pbx.extensions."9911".password = config.lib.asterisk.secret "/run/secrets/9911";
      };
      assertion = ''9911: pbx.extensions."9911", pbx.emergency.numbers (911 after pbx.outbound.prefix)'';
    };

    # every kind of number on 9911, which is also 911 after the prefix, and
    # two of each named kind on a number of their own; a call pickup on 9911
    # takes it from all of them
    everyKindOfNumberClashes = let
      owners = [
        ''pbx.extensions."9911"''
        "pbx.ringGroups.clash"
        "pbx.queues.clash"
        "pbx.conferences.clash"
        "pbx.ivrs.clash"
        "pbx.paging.clash"
        "pbx.voicemailMenu"
        "pbx.hours.clash.closeEarly"
        "pbx.emergency.numbers (911 after pbx.outbound.prefix)"
        "pbx.emergency.numbers"
      ];
      # the object named clash on 9911, and one and two on `twins`
      named = twins: object: {
        clash = object "9911";
        one = object twins;
        two = object twins;
      };
    in {
      module = {config, ...}: {
        pbx = {
          extensions."9911".password = config.lib.asterisk.secret "/run/secrets/9911";
          ringGroups = named "601" (number: {
            inherit number;
            members = ["201"];
          });
          queues = named "602" (number: {inherit number;});
          conferences = named "603" (number: {inherit number;});
          ivrs = named "604" (number: {
            inherit number;
            prompt.sound = "beep";
          });
          paging = named "605" (number: {
            inherit number;
            members = ["201"];
          });
          voicemailMenu = "9911";
          hours = named "606" (closeEarly: {
            inherit closeEarly;
            timezone = "UTC";
            open = [
              {
                days = "*";
                time = "00:00-23:59";
              }
            ];
          });
          emergency.numbers = lib.mkForce [
            "911"
            "9911"
          ];
          inbound."9911" = {
            trunk = "provider";
            destination.hangup = true;
          };
        };
        services.asterisk = {
          queues.queues = lib.genAttrs ["clash" "one" "two"] (_: {members = ["PJSIP/201"];});
          features.general.pickupexten = "9911";
        };
      };
      assertions = [
        ''
          pbx: numbers with more than one owner:
            601: pbx.ringGroups.one, pbx.ringGroups.two
            602: pbx.queues.one, pbx.queues.two
            603: pbx.conferences.one, pbx.conferences.two
            604: pbx.ivrs.one, pbx.ivrs.two
            605: pbx.paging.one, pbx.paging.two
            606: pbx.hours.one.closeEarly, pbx.hours.two.closeEarly
            9911: ${lib.concatStringsSep ", " owners}
        ''
        ''pbx: chan_pjsip takes a call to 9911, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches ${lib.concatStringsSep ", " owners}, pbx.inbound."9911". Use another number, or change services.asterisk.features.general.pickupexten.''
      ];
    };

    malformedNumber = {
      module.pbx.queues.support.number = lib.mkForce "61O";
      assertion = "numbers may only contain digits, * and #: 61O (pbx.queues.support)";
    };

    # *8 unless features.conf says otherwise
    numberIsCallPickup = {
      module.pbx.hours.office.closeEarly = "*8";
      assertion = "takes a call to *8, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches pbx.hours.office.closeEarly.";
    };

    callPickupMoved = {
      module = {
        pbx.hours.office.closeEarly = "*8";
        services.asterisk.features.general.pickupexten = "*9";
      };
      assertions = [];
    };

    # calls from trunks are picked up too
    callPickupOnInboundNumber = {
      module.services.asterisk.features.general.pickupexten = "5551000";
      assertion = ''takes a call to 5551000, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches pbx.inbound."5551000".'';
    };

    # list definitions concatenate, so these steps would follow the pbx's
    stepsAddedToPbxNumber = {
      module.services.asterisk.dialplan.contexts.pbx-internal.extensions."201" = ["NoOp(extra)"];
      assertion = "steps were added to pbx-internal/201 from elsewhere";
    };

    stepsReplacedWithMkForce = {
      module.services.asterisk.dialplan.contexts.pbx-internal.extensions."201" = lib.mkForce ["Dial(PJSIP/201)"];
      assertions = [];
    };

    # numbers the pbx does not own can be added to pbx-internal
    numberAddedToPbxInternal = {
      module.services.asterisk.dialplan.contexts.pbx-internal.extensions."*72" = ["Playback(beep)"];
      assertions = [];
    };

    missingDestinations = {
      module.pbx = {
        ringGroups.front.noAnswer.voicemail = "999";
        extensions."202" = {
          noAnswer.voicemail = "201@sales";
          busy.context.context = "nowhere";
        };
        inbound."5551000".closed = lib.mkForce {extension = "299";};
      };
      assertion = ''
        pbx: destinations that do not exist:
          pbx.extensions."202".noAnswer: voicemail 201@sales
          pbx.extensions."202".busy: context nowhere
          pbx.ringGroups.front.noAnswer: voicemail 999
          pbx.inbound."5551000".closed: extension 299
      '';
    };

    # every kind of destination, with nothing it names, in every slot
    missingDestinationInEverySlot = let
      missing = slots {
        conference.conference = "nope";
        context = {context.context = "nowhere";};
        extension.extension = "299";
        ivr.ivr = "nope";
        queue.queue = "nope";
        ringGroup.ringGroup = "nope";
        voicemail.voicemail = "299";
      };
      described = {
        conference = "conference nope";
        context = "context nowhere";
        extension = "extension 299";
        ivr = "ivr nope";
        queue = "queue nope";
        ringGroup = "ringGroup nope";
        voicemail = "voicemail 299";
      };
    in {
      inherit (missing) module;
      assertions = [
        ''
          pbx: destinations that do not exist:
            ${lib.concatMapStringsSep "\n  " (slot: "${slot.where}: ${described.${slot.kind}}") missing.slots}
        ''
      ];
    };

    contextDestinationFromCore = {
      module = {
        pbx.extensions."202".busy.context.context = "custom";
        services.asterisk.dialplan.contexts.custom.extensions.s = ["Hangup()"];
      };
      assertions = [];
    };

    # a mailbox of voicemail.conf is one, whichever option wrote it
    voicemailDestinationFromSettings = {
      module = {config, ...}: {
        pbx.extensions."202".noAnswer.voicemail = "300@sales";
        services.asterisk.settings."voicemail.conf".sales."300" = "${config.lib.asterisk.secret "/run/secrets/vm-300"},Sales";
      };
      assertions = [];
    };

    memberIsNoExtension = {
      module.pbx.ringGroups.front.members = lib.mkForce [
        "201"
        "299"
      ];
      assertion = "pbx.ringGroups.front: 299";
    };

    emptyRingGroup = {
      module.pbx.ringGroups.empty = {};
      assertion = "a ring group needs members or external numbers";
    };

    externalNumbersWithoutTrunk = {
      module.pbx = {
        outbound = lib.mkForce null;
        ringGroups.front.external = ["5559000"];
      };
      assertion = "front call external numbers, but name no trunk and pbx.outbound is not set";
    };

    unknownTrunks = {
      module.pbx = {
        inbound."5551000".trunk = lib.mkForce "provder";
        outbound.trunk = lib.mkForce "provder";
        emergency.trunk = lib.mkForce "provder";
      };
      assertion = ''
        pbx: trunks that are not defined in services.asterisk.pjsip.trunks:
          pbx.inbound."5551000".trunk: provder
          pbx.outbound.trunk: provder
          pbx.emergency.trunk: provder
      '';
    };

    unknownRingGroupTrunk = {
      module.pbx.ringGroups.front = {
        external = ["5559000"];
        trunk = "provder";
      };
      assertion = "pbx.ringGroups.front.trunk: provder";
    };

    # pbx dials PJSIP/<number>@<trunk>, which Dial splits at & and chan_pjsip
    # at /; a trunk calls only arrive on is never dialled
    dialledTrunkNames = {
      module = {config, ...}: let
        trunk = {
          host = "sip.provider.example";
          username = "5551000";
          password = config.lib.asterisk.secret "/run/secrets/trunk";
        };
      in {
        services.asterisk.pjsip.trunks = {
          "a&b" = trunk;
          "c/d" = trunk;
          "e\${f}" = trunk;
          "in&only" = trunk;
        };
        pbx = {
          outbound.trunk = lib.mkForce "a&b";
          emergency.trunk = lib.mkForce "e\${f}";
          ringGroups.front = {
            external = ["5559000"];
            trunk = "c/d";
          };
          inbound."5552000" = {
            trunk = "in&only";
            destination.ringGroup = "front";
          };
        };
      };
      assertion = ''
        pbx: trunk names that Asterisk would misread in a dial string (they may not contain , ; [ ] " \ ''${ $[ & / or an unclosed parenthesis):
          pbx.outbound.trunk: a&b
          pbx.emergency.trunk: e''${f}
          pbx.ringGroups.front.trunk: c/d
      '';
    };

    queueOnlyInPbx = {
      module.pbx.queues.sales.number = "620";
      assertion = "sales are not queues of services.asterisk.queues.queues";
    };

    # default_bridge and default_user exist without configuration
    conferenceProfiles = {
      module.pbx.conferences.board = {
        bridgeProfile = "default_bridge";
        userProfile = "quiet";
      };
      assertion = ''
        pbx.conferences: profiles that are not defined:
          pbx.conferences.board.userProfile: quiet
      '';
    };

    inboundWithDestinationAndHours = {
      module.pbx.inbound."5551000".destination.ringGroup = "front";
      assertion = "5551000 need either `destination`, or `hours` with `open` and `closed`";
    };

    inboundWithoutClosed = {
      module.pbx.inbound."5551000".closed = lib.mkForce null;
      assertion = "5551000 need either `destination`, or `hours` with `open` and `closed`";
    };

    unknownHours = {
      module.pbx.inbound."5551000".hours = lib.mkForce "shop";
      assertion = "5551000 use hours that are not defined in pbx.hours";
    };

    trunkWithContextOfItsOwn = {
      module.services.asterisk.pjsip.trunks.provider.context = "from-provider";
      assertion = "the trunk(s) provider have a context of their own";
    };

    notifyIsNoExtension = {
      module.pbx.emergency.notify = lib.mkForce ["299"];
      assertion = "pbx.emergency.notify: 299 are not extensions of pbx.extensions";
    };

    objectsWithoutEnable = {
      module.pbx.enable = lib.mkForce false;
      warning = "pbx objects are defined, but pbx.enable is not set";
    };

    timezoneWithSpaceThrows = {
      module.pbx.hours.office.timezone = lib.mkForce "America/Los Angeles";
      throws = true;
    };

    weekdayNameThrows = {
      module.pbx.hours.office.open = lib.mkForce [
        {
          days = "monday";
          time = "09:00-17:00";
        }
      ];
      throws = true;
    };

    holidayDayFirstThrows = {
      module.pbx.hours.office.holidays = ["25 dec"];
      throws = true;
    };

    # GotoIfTime skips a time past 23:59, so these hours would never open
    openUntil24Throws = {
      module.pbx.hours.office.open = lib.mkForce [
        {
          days = "mon-fri";
          time = "09:00-24:00";
        }
      ];
      throws = true;
    };

    # GotoIfTime skips day 0, so the holiday would never close
    holidayDayZeroThrows = {
      module.pbx.hours.office.holidays = ["apr 0"];
      throws = true;
    };

    # feb 30 never comes, and GotoIfTime reads dec 30-2 as dec 1, 2, 30 and
    # 31; feb 29 comes in leap years, apr 30-31 closes on apr 30
    holidaysThatNeverCome = {
      module.pbx.hours.office.holidays = [
        "feb 30"
        "dec 30-2"
        "feb 29"
        "apr 30-31"
      ];
      assertions = [
        ''
          pbx.hours: holidays on a day their month does not have, or that end before they start:
            pbx.hours.office.holidays: feb 30
            pbx.hours.office.holidays: dec 30-2
        ''
      ];
    };

    ht801PlainAdminPasswordWarns = {
      module.pbx.phones = {
        listenAddress = "10.0.20.10";
        allowedNetworks = ["10.0.20.0/24"];
        grandstream.ht801 = {
          enable = true;
          adminPassword = "admin";
          devices."201".mac = "c0:74:ad:00:02:01";
        };
      };
      assertions = [];
      warning = "ht801.adminPassword is not a secret reference";
    };

    # an integer lands in the store just like a string
    ht801IntegerAdminPasswordWarns = {
      module = {
        imports = [phones];
        pbx.phones.grandstream.ht801 = {
          enable = true;
          adminPassword = 1234;
          devices."201".mac = "c0:74:ad:00:02:01";
        };
      };
      assertions = [];
      warning = "ht801.adminPassword is not a secret reference";
    };

    # systemd drops every connection with no IPAddressAllow= entry
    phonesWithoutNetworks = {
      module = {
        imports = [phones];
        pbx.phones = {
          enable = true;
          allowedNetworks = [];
        };
      };
      assertions = ["pbx.phones.allowedNetworks is empty, so systemd would drop every connection; list the phones' networks."];
    };

    # what `systemd-analyze verify` takes and refuses in IPAddressAllow= (it
    # ignores a refused entry with a warning in its own journal, and an empty
    # one resets the list)
    phonesNetworksSystemdRefuses = {
      module = {
        imports = [phones];
        pbx.phones = {
          enable = true;
          allowedNetworks = [
            "10.0.20.0/24 10.0.21.0/24"
            "fd00:20::/64"
            "::ffff:10.0.20.0/120"
            "10.0.20.0/024"
            "10.0.20.5"
            "localhost"
            "10.0.20.0/33"
            "phones"
            "10.0.20.021"
            "[fd00::21]"
            "10.0.20.0/24 phones"
            ""
          ];
        };
      };
      assertions = ["pbx.phones.allowedNetworks: entries must be addresses, networks such as 10.0.20.0/24, or any, localhost, link-local or multicast, which is what systemd takes: `10.0.20.0/33`, `phones`, `10.0.20.021`, `[fd00::21]`, `10.0.20.0/24 phones`, ``."];
    };

    # what Rust's IpAddr parses, which the server compares the client's
    # address with; it does not start with anything else
    phonesAllowedAddressNotAnAddress = {
      module = {
        imports = [phones];
        pbx.phones = {
          grandstream.ht801 = {
            enable = true;
            devices."201" = {
              mac = "c0:74:ad:00:02:01";
              allowedAddress = "10.0.20.021";
            };
          };
          files =
            lib.mapAttrs (_: allowedAddress: {
              text = "x";
              inherit allowedAddress;
            }) {
              "v4.cfg" = "10.0.20.21";
              "v6.cfg" = "FD00::21";
              "mapped.cfg" = "::ffff:10.0.20.21";
              "name.cfg" = "kitchen.lan";
              "network.cfg" = "10.0.20.21/32";
              "zone.cfg" = "fe80::21%voip";
              "brackets.cfg" = "[fd00::21]";
            };
        };
      };
      assertions = ["pbx.phones.files: allowedAddress must be one IPv4 or IPv6 address: brackets.cfg has `[fd00::21]`, cfgc074ad000201.xml has `10.0.20.021`, name.cfg has `kitchen.lan`, network.cfg has `10.0.20.21/32`, zone.cfg has `fe80::21%voip`."];
    };

    # the adapter sends one user name, for the endpoint and its aor
    ht801EndpointWithRenamedAor = {
      module = {
        services.asterisk.pjsip.endpoints."201".aor.name = "kitchen";
        pbx.phones = {
          listenAddress = "10.0.20.10";
          allowedNetworks = ["10.0.20.0/24"];
          grandstream.ht801 = {
            enable = true;
            devices."201".mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertion = "an `aor` named like the endpoint";
    };

    ivrDestinations = {
      module.pbx = {
        ivrs.main = {
          options = {
            "2".queue = "sales";
            "3".context.context = "nowhere";
          };
          noInput.ivr = "night";
        };
        ringGroups.front.noAnswer.ivr = "main";
      };
      assertion = ''
        pbx: destinations that do not exist:
          pbx.ivrs.main.options."2": queue sales
          pbx.ivrs.main.options."3": context nowhere
          pbx.ivrs.main.noInput: ivr night
      '';
    };

    ivrKeys = {
      module.pbx.ivrs.main.options = {
        "12".hangup = true;
        "a".hangup = true;
        "#".hangup = true;
      };
      assertion = "keys must be one digit, * or #: pbx.ivrs.main.options.12, pbx.ivrs.main.options.a.";
    };

    ivrKeyIsExtensionWithDirectDial = {
      module.pbx = {
        extensions."2".password = "x";
        ivrs.main = {
          directDial = true;
          options."2".hangup = true;
        };
      };
      assertion = "which directDial makes dialable: pbx.ivrs.main.options.2.";
    };

    # only the menu with the bad name, not the baseline's `main`
    ivrName = {
      module.pbx.ivrs."main menu".prompt.sound = "custom/main-menu";
      assertion = ''menu names may only contain letters, digits, _ and -: pbx.ivrs."main menu".'';
    };

    # Goto and Gosub end a context at the first comma, and Dial splits its
    # channels at &, one of which is the Local channel of an external number
    ringGroupNames = {
      module.pbx.ringGroups = {
        "a,b".members = ["201"];
        "x&y" = {
          members = ["201"];
          external = ["5559000"];
        };
        "sales & support".members = ["201"];
        "sales (east)".members = ["201"];
      };
      assertion = ''
        pbx.ringGroups: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis, nor & with external numbers):
          pbx.ringGroups."a,b"
          pbx.ringGroups."x&y"
      '';
    };

    # Gosub ends its target at the first (; with closeEarly the name is also
    # in Set(), which ends the variable at =, and in a hint, which splits at &
    hoursNames = {
      module.pbx.hours = let
        hours = {
          timezone = "UTC";
          open = [
            {
              days = "mon-fri";
              time = "09:00-17:00";
            }
          ];
        };
      in {
        "a,b" = hours;
        "office (east)" = hours;
        "a=b" = hours // {closeEarly = "*29";};
        "c&d" = hours // {closeEarly = "*30";};
        "e&f" = hours;
      };
      assertion = ''
        pbx.hours: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] ''${ $[ or (, nor & or = or more than 62 bytes with closeEarly):
          pbx.hours."a,b"
          pbx.hours."a=b"
          pbx.hours."c&d"
          pbx.hours."office (east)"
      '';
    };

    # Page turns ^ into a comma in its pre-dial routine, whose target Gosub
    # ends at the first (
    pagingNames = {
      module.pbx.paging = {
        "a,b" = {
          number = "651";
          members = ["201"];
        };
        "a^b" = {
          number = "652";
          members = ["201"];
        };
        "all (east)" = {
          number = "653";
          members = ["201"];
        };
      };
      assertion = ''
        pbx.paging: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ ( ) or ^):
          pbx.paging."a,b"
          pbx.paging."a^b"
          pbx.paging."all (east)"
      '';
    };

    # ConfBridge needs a name, and its argument parser drops quotes
    conferenceNames = {
      module.pbx.conferences = {
        "a,b" = {};
        "" = {};
        "a\"b" = {};
        "board (east)" = {};
      };
      assertion = ''
        pbx.conferences: names that Asterisk would misread in the dialplan (they may not be empty, or contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
          pbx.conferences.""
          pbx.conferences."a\"b"
          pbx.conferences."a,b"
      '';
    };

    # Queue's argument parser drops backslashes, and an unclosed parenthesis
    # takes the timeout into the name
    queueNames = {
      module = {
        pbx.queues = {
          "a,b" = {};
          "a\\b" = {};
          "c(d".timeout = 60;
          "support (east)" = {};
        };
        services.asterisk.queues.queues = lib.genAttrs ["a,b" "a\\b" "c(d" "support (east)"] (_: {
          members = ["PJSIP/201"];
        });
      };
      assertion = ''
        pbx.queues: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
          pbx.queues."a,b"
          pbx.queues."a\\b"
          pbx.queues."c(d"
      '';
    };

    ivrNumberClash = {
      module.pbx.ivrs.main.number = lib.mkForce "201";
      assertion = ''201: pbx.extensions."201", pbx.ivrs.main'';
    };

    pagingNumberClash = {
      module.pbx.paging.all.number = lib.mkForce "800";
      assertion = "800: pbx.conferences.board, pbx.paging.all";
    };

    pagingMemberIsNoExtension = {
      module.pbx.paging.all.members = lib.mkForce [
        "201"
        "299"
      ];
      assertion = "pbx.paging.all: 299";
    };

    pagingHeaderWithoutValueThrows = {
      module.pbx.paging.all.headers = ["Call-Info"];
      throws = true;
    };

    destinationWithTwoKindsThrows = {
      module.pbx.ringGroups.front.noAnswer = {
        voicemail = "201";
        hangup = true;
      };
      throws = true;
    };
  };
in {
  run = checkCases base;
  tests = cases;
}
