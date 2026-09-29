# Invalid pbx configurations must fail evaluation with a clear message. The
# result is the list of cases that did not behave as expected (see
# checkCases in ../eval-lib.nix).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) checkCases;

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
      assertion = ''9911: pbx.extensions."9911", pbx.emergency.numbers'';
    };

    malformedNumber = {
      module.pbx.queues.support.number = lib.mkForce "61O";
      assertion = "numbers may only contain digits, * and #: 61O (pbx.queues.support)";
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

    contextDestinationFromCore = {
      module = {
        pbx.extensions."202".busy.context.context = "custom";
        services.asterisk.dialplan.contexts.custom.extensions.s = ["Hangup()"];
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
      warning = "ht801.adminPassword is a plain string";
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

    ivrName = {
      module.pbx.ivrs."main menu".prompt.sound = "custom/main-menu";
      assertion = "menu names may only contain letters, digits, _ and -";
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
in
  checkCases base cases
