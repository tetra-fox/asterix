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
        callerId = "5551000";
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

  # the baseline without pbx.enable and without its objects
  disabled =
    lib.genAttrs ["extensions" "ringGroups" "queues" "conferences" "ivrs" "paging" "hours" "inbound"] (_: lib.mkForce {})
    // {
      enable = lib.mkForce false;
      outbound = lib.mkForce null;
      emergency = lib.mkForce null;
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

    # its mailbox would start with #, which Asterisk reads as a directive in
    # voicemail.conf; without a mailbox the number works (vm-pbx-calls)
    hashExtensionWithMailbox = {
      module = {config, ...}: {
        pbx.extensions."#1" = {
          password = config.lib.asterisk.secret "/run/secrets/hash";
          voicemail.pin = config.lib.asterisk.secret "/run/secrets/vm-hash";
        };
      };
      assertions = ["services.asterisk.voicemail.mailboxes: mailbox numbers may only contain letters, digits and _*#+-, and not start with * or #: #1@default."];
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

    # a pickup code inside the outbound pattern takes the one number outside
    # it matches, like a pbx number there, as pbx.outbound.prefix says
    callPickupInsideOutboundPattern = {
      module.services.asterisk.features.general.pickupexten = "981";
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

    # and lines of settings follow them
    stepsAddedThroughSettings = {
      module.services.asterisk.settings."extensions.conf".pbx-internal.exten = ["201,2,NoOp(extra)"];
      assertion = "steps were added to pbx-internal/201 from elsewhere";
    };

    # numbers the pbx does not own can be added to pbx-internal
    numberAddedToPbxInternal = {
      module.services.asterisk.dialplan.contexts.pbx-internal.extensions."*72" = ["Playback(beep)"];
      assertions = [];
    };

    numberAddedToPbxInternalThroughSettings = {
      module.services.asterisk.settings."extensions.conf".pbx-internal.exten = ["*72,1,Playback(beep)"];
      assertions = [];
    };

    # hangup takes only true; nothing else may hang up quietly
    hangupFalseThrows = {
      module.pbx.ringGroups.front.noAnswer = {hangup = false;};
      throws = true;
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

    # and one of its raw text, by name
    voicemailDestinationFromExtraConfig = {
      module = {
        pbx.extensions."202" = {
          noAnswer.voicemail = "300@sales";
          busy.voicemail = "301@sales";
        };
        services.asterisk.extraConfig."voicemail.conf" = ''
          [sales]
          300 => 1234,Sales
        '';
      };
      assertions = [
        ''
          pbx: destinations that do not exist:
            pbx.extensions."202".busy: voicemail 301@sales
        ''
      ];
    };

    # VoiceMail() takes the context in any case, but files the message under
    # the mailbox as dialed, and reaches no mailbox through an alias
    voicemailDestinationContextInAnyCase = {
      module = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        pbx = {
          extensions."202" = {
            noAnswer.voicemail = "201@Default";
            busy.voicemail = "300@sales";
          };
          ringGroups.front.noAnswer.voicemail = "1234@devices";
          queues.support.noAnswer.voicemail = "Alice@Sales";
        };
        services.asterisk = {
          voicemail.settings.aliasescontext = "aliases";
          settings."voicemail.conf" = {
            Sales = {
              "300" = "${secret "/run/secrets/vm-300"},Sales";
              alice = "${secret "/run/secrets/vm-alice"},Alice";
            };
            aliases."1234@devices" = "201@default";
          };
        };
      };
      assertions = [
        ''
          pbx: destinations that do not exist:
            pbx.ringGroups.front.noAnswer: voicemail 1234@devices
            pbx.queues.support.noAnswer: voicemail Alice@Sales
        ''
      ];
    };

    # with searchcontexts VoiceMail() takes a mailbox from any context,
    # whatever context it is given
    voicemailDestinationWithSearchContexts = {
      module = {config, ...}: {
        pbx.extensions."202" = {
          noAnswer.voicemail = "300";
          busy.voicemail = "301@sales";
        };
        services.asterisk = {
          voicemail.settings.searchcontexts = true;
          settings."voicemail.conf".sales."300" = "${config.lib.asterisk.secret "/run/secrets/vm-300"},Sales";
        };
      };
      assertions = [
        ''
          pbx: destinations that do not exist:
            pbx.extensions."202".busy: voicemail 301@sales
        ''
      ];
    };

    # Asterisk keeps 79 bytes of a caller ID name; each of these characters
    # takes 3
    extensionNameOf79Bytes = {
      module.pbx.extensions."201".name = lib.concatStrings (lib.replicate 26 (builtins.fromJSON ''"\u5c71"'')) + "!";
      assertions = [];
    };

    extensionNameTooLong = {
      module.pbx.extensions."201".name = lib.concatStrings (lib.replicate 27 (builtins.fromJSON ''"\u5c71"''));
      assertion = ''"201" (81 bytes)'';
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

    # each trunk of a number's list
    unknownTrunkInList = {
      module.pbx.inbound."5551000".trunk = lib.mkForce [
        "provider"
        "provder"
      ];
      assertions = [
        ''
          pbx: trunks that are not defined in services.asterisk.pjsip.trunks:
            pbx.inbound."5551000".trunk: provder
        ''
      ];
    };

    inboundWithoutTrunkThrows = {
      module.pbx.inbound."5551000".trunk = lib.mkForce [];
      throws = true;
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

    # [general], in any case, holds app_queue's own settings
    queueOnlyInPbx = {
      module.pbx.queues = {
        sales.number = "620";
        General.number = "621";
      };
      assertion = "General, sales are not queues of queues.conf";
    };

    # its members make it a queue of queues.conf
    queueWithMembersOnlyInPbx = {
      module.pbx.queues.sales = {
        number = "620";
        members = ["202"];
      };
      assertions = [];
    };

    queueMemberIsNoExtension = {
      module.pbx.queues.support.members = [
        "201"
        "299"
      ];
      assertion = "pbx.queues.support: 299";
    };

    # Asterisk cuts the section's name, so Queue() never finds it
    queueNameTooLong = {
      module = {
        pbx.queues.${lib.strings.replicate 80 "q"}.number = "620";
        services.asterisk.settings."queues.conf".${lib.strings.replicate 80 "q"}.member = ["PJSIP/202"];
      };
      assertion = "pbx.queues: names longer than 79 bytes, which Asterisk cuts, so Queue() never finds them: ${lib.strings.replicate 80 "q"}.";
    };

    # default_bridge and default_user exist without configuration, and a
    # user profile is no bridge profile
    conferenceProfiles = {
      module = {
        pbx.conferences = {
          board = {
            bridgeProfile = "quiet";
            userProfile = "default_user";
          };
          team = {
            bridgeProfile = "default_bridge";
            userProfile = "nobody";
          };
        };
        services.asterisk.confbridge.users.quiet.quiet = true;
      };
      assertion = ''
        pbx.conferences: profiles that are not defined:
          pbx.conferences.board.bridgeProfile: quiet
          pbx.conferences.team.userProfile: nobody
      '';
    };

    # Asterisk reads them the same as the typed ones, and finds queues and
    # profiles in any case
    queueAndProfilesFromSettings = {
      module = {
        pbx = {
          queues.Sales.number = "620";
          conferences.board = {
            bridgeProfile = "Small";
            userProfile = "guest";
          };
        };
        services.asterisk.settings = {
          "queues.conf".sales.member = ["PJSIP/202"];
          "confbridge.conf" = {
            # the type comes from the template
            guests = {
              template = true;
              type = "user";
            };
            guest = {
              inherits = ["guests"];
              startmuted = true;
            };
            small = {
              type = "bridge";
              max_members = 3;
            };
          };
        };
      };
      assertions = [];
    };

    inboundWithDestinationAndHours = {
      module.pbx.inbound."5551000".destination.ringGroup = "front";
      assertion = "5551000 need either `destination`, or `hours` with `open` and `closed`";
    };

    inboundWithoutClosed = {
      module.pbx.inbound."5551000".closed = lib.mkForce null;
      assertion = "5551000 need either `destination`, or `hours` with `open` and `closed`";
    };

    # the assertion, not an error from the dialplan of a number with no hours
    inboundWithoutHours = {
      module.pbx.inbound = {
        "5551001".trunk = "provider";
        "5551002" = {
          trunk = "provider";
          open.ringGroup = "front";
          closed.voicemail = "201";
        };
      };
      assertion = "5551001, 5551002 need either `destination`, or `hours` with `open` and `closed`";
    };

    unknownHours = {
      module.pbx.inbound."5551000".hours = lib.mkForce "shop";
      assertion = "5551000 use hours that are not defined in pbx.hours";
    };

    trunkWithContextOfItsOwn = {
      module.services.asterisk.pjsip.trunks.provider.context = "from-provider";
      assertion = "the trunk(s) provider have a context of their own";
    };

    # the final pjsip.conf says where the trunk's calls start
    trunkWithContextFromSettings = {
      module.services.asterisk = {
        settings."pjsip.conf"."endpoint:provider".context = "from-provider";
        dialplan.contexts.from-provider.extensions.s = ["Hangup()"];
      };
      assertions = ["pbx.inbound: the trunk(s) provider have a context of their own, so their calls do not reach pbx.inbound; remove it."];
    };

    notifyIsNoExtension = {
      module.pbx.emergency.notify = lib.mkForce ["299"];
      assertion = "pbx.emergency.notify: 299 are not extensions of pbx.extensions";
    };

    # with neither callerId, the provider decides which number an emergency
    # call presents
    emergencyWithoutCallerIdWarns = {
      module.pbx.outbound.callerId = lib.mkForce null;
      assertions = [];
      warning = "pbx.emergency.callerId";
    };

    # emergency numbers take digits only; * and # come with the outbound
    # prefix, as in #911 (vm-pbx-calls)
    emergencyNumberWithStar = {
      module.pbx.emergency.numbers = lib.mkForce ["*911"];
      throws = true;
    };

    objectsWithoutEnable = {
      module.pbx.enable = lib.mkForce false;
      warning = "pbx objects are defined, but pbx.enable is not set";
    };

    nothingWithoutEnable = {
      module.pbx = disabled;
      warnings = [];
    };

    outboundWithoutEnable = {
      module.pbx =
        disabled
        // {
          outbound = lib.mkForce {
            prefix = "9";
            trunk = "provider";
          };
        };
      warning = "pbx objects are defined, but pbx.enable is not set";
    };

    emergencyWithoutEnable = {
      module.pbx =
        disabled
        // {
          emergency = lib.mkForce {
            numbers = ["911"];
            trunk = "provider";
          };
        };
      warning = "pbx objects are defined, but pbx.enable is not set";
    };

    voicemailMenuWithoutEnable = {
      module.pbx = disabled // {voicemailMenu = "*97";};
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

    # a right/ zone counts leap seconds, which the system clock leaves out
    rightZoneAsserts = {
      module.pbx.hours.office.timezone = lib.mkForce "right/America/Los_Angeles";
      assertions = [
        ''
          pbx.hours: time zones of right/, which count leap seconds as the system clock does not, so the hours would open and close 27 s late; use the zone without right/:
            pbx.hours.office.timezone: right/America/Los_Angeles
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

    # its length is known only once the secret is read
    ht801AdminPasswordInterpolated = {
      module = {config, ...}: {
        imports = [phones];
        pbx.phones.grandstream.ht801 = {
          enable = true;
          adminPassword = "${config.lib.asterisk.secret "/run/secrets/ht801-admin"}";
          devices."201".mac = "c0:74:ad:00:02:01";
        };
      };
      assertions = [];
      warnings = [];
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

    # V2 hardware takes 4 to 30 characters, from adminPassword or an adapter's
    # own P2
    ht801AdminPasswordLength = {
      module = {
        imports = [phones];
        pbx.phones.grandstream.ht801 = {
          enable = true;
          adminPassword = 123;
          devices = lib.mapAttrs (_: device: device // {endpoint = "201";}) {
            short.mac = "c0:74:ad:00:02:01";
            four = {
              mac = "c0:74:ad:00:02:02";
              settings.P2 = "abcd";
            };
            thirty = {
              mac = "c0:74:ad:00:02:03";
              settings.P2 = lib.strings.replicate 30 "x";
            };
            long = {
              mac = "c0:74:ad:00:02:04";
              settings.P2 = lib.strings.replicate 31 "x";
            };
          };
        };
      };
      assertions = ["pbx.phones.grandstream.ht801: the admin password (P2) of long, short is not 4 to 30 characters long, which HT801 V2 hardware requires."];
    };

    # XML holds no control character but tab and line breaks, and a P-value
    # is one line: from the options, and from the endpoint's user name
    ht801ControlCharacters = {
      module = {
        imports = [phones];
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "202${builtins.fromJSON ''"\u0007"''}";
        pbx.phones.grandstream.ht801 = {
          enable = true;
          timeZone = "CET-1CEST\n";
          devices = {
            "201" = {
              mac = "c0:74:ad:00:02:01";
              settings.P1362 = "de\tx";
            };
            "202".mac = "c0:74:ad:00:02:02";
          };
        };
      };
      assertions = ["pbx.phones.grandstream.ht801: P-values cannot contain control characters: 201 P64, 201 P1362, 202 P36, 202 P64."];
    };

    # P47 and P237 name where the adapter registers and fetches its file; a
    # socket on 0.0.0.0 or :: listens on every address, which no adapter can
    # connect to
    ht801WildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          grandstream.ht801 = {
            enable = true;
            devices = {
              "201".mac = "c0:74:ad:00:02:01";
              "202" = {
                mac = "c0:74:ad:00:02:02";
                settings = {
                  P47 = "0.0.0.0:5060";
                  P237 = "[fd00:20::10]:8080";
                };
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.grandstream.ht801: P-values that send adapters to 0.0.0.0 or ::, which no adapter can reach: 201 P47, 201 P237, 202 P47. Set pbx.phones.listenAddress to the PBX's address on the adapters' network, or give that address in sipServer (P47) and settings.P237."];
    };

    # listening on :: serves adapters that are given the PBX's address
    ht801WildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          grandstream.ht801 = {
            enable = true;
            sipServer = "10.0.20.10";
            settings.P237 = "10.0.20.10";
            devices."201".mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # two spellings of one address would be one file
    ht801SameMacTwice = {
      module = {
        imports = [phones];
        pbx.phones.grandstream.ht801 = {
          enable = true;
          devices = {
            "201".mac = "c0:74:ad:00:02:01";
            "202".mac = "C0-74-AD-00-02-01";
          };
        };
      };
      assertions = ["pbx.phones.grandstream.ht801.devices: MAC addresses must be unique."];
    };

    phonesFileNames = {
      module = {
        imports = [phones];
        pbx.phones = {
          enable = true;
          files = lib.genAttrs [".hidden" "a/b" "a b"] (_: {text = "x";});
        };
      };
      assertions = ["pbx.phones.files: file names may only contain letters, digits and _.+- (no directories)."];
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

    # the socket's ListenStream= takes an address, and a line break would
    # start a line of its own in the unit; the firewall's rules name the
    # interfaces
    phonesListenAddressAndInterfaces = {
      module = {
        imports = [phones];
        pbx.phones = {
          enable = true;
          listenAddress = lib.mkForce "10.0.20.10\nExecStartPre=/bin/false";
          firewallInterfaces = [
            "voip"
            "voip\nreboot"
          ];
        };
      };
      assertions = [
        ''pbx.phones.listenAddress must be one IPv4 or IPv6 address: "10.0.20.10\nExecStartPre=/bin/false".''
        ''pbx.phones.firewallInterfaces: Linux takes interface names of 1 to 15 bytes without /, : or whitespace: "voip\nreboot".''
      ];
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

    # the assertion, not an error from the file of an adapter whose endpoint
    # does not exist or has no auth
    ht801EndpointMissing = {
      module = {
        services.asterisk.pjsip.endpoints.kitchen.context = "pbx-internal";
        pbx.phones = {
          listenAddress = "10.0.20.10";
          allowedNetworks = ["10.0.20.0/24"];
          grandstream.ht801 = {
            enable = true;
            devices = {
              "299".mac = "c0:74:ad:00:02:99";
              kitchen.mac = "c0:74:ad:00:02:98";
            };
          };
        };
      };
      assertions = [
        "pbx.phones.grandstream.ht801.devices.299: endpoint `299` must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the adapter registers with one user name for both."
        "pbx.phones.grandstream.ht801.devices.kitchen: endpoint `kitchen` must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the adapter registers with one user name for both."
        "services.asterisk: PJSIP endpoint(s) kitchen have neither auth nor identify and their aor takes registrations, so anyone who reaches the SIP port can register as them. Give each a password (pjsip.endpoints.<name>.auth.password), or for a device known by its address an identify with settings.identify_by = \"ip\", or aor.maxContacts = 0 if it never registers, or set open = true where anyone may register on purpose."
      ];
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

    # ConfBridge refuses a name of 80 bytes or more
    conferenceNameLongerThan79Bytes = {
      module.pbx.conferences = {
        ${lib.strings.replicate 80 "c"} = {};
        ${lib.strings.replicate 79 "d"} = {};
      };
      assertion = "pbx.conferences: names longer than 79 bytes, which ConfBridge refuses: ${lib.strings.replicate 80 "c"}.";
    };

    # ConfBridge finds a conference by its name in any case, so these would be
    # one room
    conferencesAlikeButForCase = {
      module.pbx.conferences = {
        Board.number = "801";
        BOARD = {};
      };
      assertion = "pbx.conferences: names that differ only in case, which ConfBridge takes for one conference: BOARD, Board, board.";
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
