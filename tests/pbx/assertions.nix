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

    # and one inside an inbound pattern takes the one number it matches, as
    # pbx.inbound says, like one inside the outbound pattern
    callPickupInsideInboundPattern = {
      module = {
        pbx.inbound."_98X" = {
          trunk = "provider";
          destination.hangup = true;
        };
        services.asterisk.features.general.pickupexten = "981";
      };
      assertions = [];
    };

    # a number, s or a pattern of numbers: an extension of the trunk's
    # context such as h, which Asterisk runs at every hangup, or one with a
    # letter, which a caller would have to send, is none of them
    inboundKeys = {
      module.pbx.inbound = lib.genAttrs ["5551abc" "h" "S" "1+5551000" "555-1000" "_" "_[]" "_555abc" "_555-XXXX"] (_: {
        trunk = "provider";
        destination.hangup = true;
      });
      assertions = [
        ''pbx.inbound: keys must be a number of digits, * and #, with an optional leading +; s, which takes the calls that name no number; or a pattern of such numbers that starts with _, such as _X.: pbx.inbound."1+5551000", pbx.inbound."555-1000", pbx.inbound."5551abc", pbx.inbound.S, pbx.inbound._, pbx.inbound._555-XXXX, pbx.inbound._555abc, pbx.inbound."_[]", pbx.inbound.h.''
      ];
    };

    inboundNumbersSAndPatterns = {
      module.pbx.inbound = lib.genAttrs ["+15551001" "*5551002#" "s" "_X." "_555XXXX" "_[2-9]xx!" "_+1NXXNXXXXXX" "_*[0-9#]Z"] (_: {
        trunk = "provider";
        destination.hangup = true;
      });
      assertions = [];
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

    # every context the pbx writes is guarded the same way, before or after
    # its steps
    stepsAddedToGeneratedContexts = {
      module.services.asterisk.dialplan.contexts = {
        pbx-extension-201.extensions.s = ["NoOp(extra)"];
        pbx-ringgroup-front.extensions.s = lib.mkBefore ["NoOp(first)"];
        pbx-inbound-provider.extensions."5551000" = ["NoOp(extra)"];
        pbx-outbound.extensions."_9X." = ["NoOp(extra)"];
        pbx-emergency.extensions."911" = lib.mkBefore ["NoOp(first)"];
      };
      assertions = [
        "pbx: steps were added to pbx-emergency/911, pbx-extension-201/s, pbx-inbound-provider/5551000, pbx-outbound/_9X., pbx-ringgroup-front/s from elsewhere, so they run before or after the pbx's own. Change these through the pbx options, or replace their steps with lib.mkForce; steps of your own can go in the context's extraConfig, which is written as it is, or in a context of your own that a `context` destination names."
      ];
    };

    stepsAddedToGeneratedContextsThroughSettings = {
      module.services.asterisk.settings."extensions.conf".pbx-queue-support.exten = ["s,4,NoOp(extra)"];
      assertions = [
        ''pbx: steps were added to pbx-queue-support/s from elsewhere, as lines of services.asterisk.settings."extensions.conf". Change these through the pbx options; steps of your own can go in the context's extraConfig, which is written as it is, or in a context of your own that a `context` destination names.''
      ];
    };

    # replaced steps, an extension of its own and raw lines are the user's
    generatedContextsChangedOnPurpose = {
      module.services.asterisk.dialplan.contexts = {
        pbx-extension-201.extensions.s = lib.mkForce ["Dial(PJSIP/201)"];
        pbx-ringgroup-front.extensions.h = ["NoOp(hung up)"];
        pbx-ivr-main.extraConfig = "exten => s,n,NoOp(extra)";
      };
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

    # each comes back to where it started without a key press, so the call
    # rings or plays on until the caller hangs up: an extension that is busy
    # and a group that rings it, two groups, a queue and a menu on their own
    destinationLoops = {
      module.pbx = {
        extensions."202".busy.ringGroup = "front";
        ringGroups = {
          front.noAnswer.extension = "202";
          side = {
            members = ["201"];
            noAnswer.ringGroup = "back";
          };
          back = {
            members = ["202"];
            noAnswer.ringGroup = "side";
          };
        };
        queues.support.noAnswer.queue = "support";
        ivrs.main.noInput.ivr = "main";
      };
      assertions = [
        ''
          pbx: destinations that lead back to their own object without a key press, so a call goes round until the caller hangs up:
            pbx.extensions."202".busy: ringGroup front
            pbx.ringGroups.back.noAnswer: ringGroup side
            pbx.ringGroups.front.noAnswer: extension 202
            pbx.ringGroups.side.noAnswer: ringGroup back
            pbx.queues.support.noAnswer: queue support
            pbx.ivrs.main.noInput: ivr main
          Send one of them elsewhere, such as to voicemail; a voice menu's options and invalid key may lead back, since the caller presses a key for those.
        ''
      ];
    };

    # a key press breaks the round: a menu that comes back to itself on a key
    # or an invalid one, and a group that sends callers back to its menu
    loopsThroughKeys = {
      module.pbx = {
        ringGroups.front.noAnswer.ivr = "main";
        ivrs.main = {
          options."9".ivr = "main";
          invalid.ivr = "main";
        };
      };
      assertions = [];
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

    # Asterisk splits the groups at commas and strips the ends of each
    pickupGroupWithCommaThrows = {
      module.pbx.extensions."201".pickupGroups = ["front,back"];
      throws = true;
    };

    pickupGroupWithSpaceAtTheEndThrows = {
      module.pbx.extensions."201".pickupGroups = ["front "];
      throws = true;
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

    # an outside number is an extension of the group's own context, where s
    # would replace the steps that ring the members and h run at every
    # hangup, and part of a Local channel, which & and / would break
    externalNumberThatIsNoNumberThrows = {
      module.pbx.ringGroups.front.external = ["s"];
      throws = true;
    };

    externalNumbersWithPlusStarAndHash = {
      module.pbx.ringGroups.front.external = [
        "+15559000"
        "*675559000"
        "5559000#"
      ];
      assertions = [];
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

    # calls from these trunks start where the outbound pattern can be
    # dialled: in pbx-internal, which includes pbx-outbound, in a context that
    # includes it at some hours, and in one set in settings
    trunksReachingOutbound = {
      module = {config, ...}: let
        trunk = context: {
          host = "sip.branch.example";
          username = "5552000";
          password = config.lib.asterisk.secret "/run/secrets/branch";
          inherit context;
        };
      in {
        services.asterisk = {
          pjsip.trunks = {
            branch = trunk "pbx-internal";
            lobby = trunk "from-lobby";
            annex = trunk "from-annex";
          };
          dialplan.contexts = {
            from-lobby.includes = ["pbx-internal,08:00-18:00,*,*,*"];
            from-annex.extensions.s = ["Hangup()"];
          };
          settings."pjsip.conf"."endpoint:annex".context = "pbx-outbound";
        };
      };
      assertions = [
        "pbx: calls from the trunk(s) annex (pbx-outbound), branch (pbx-internal), lobby (from-lobby) start in a context that reaches pbx-outbound, so anyone who can call in through them can dial out, emergency numbers included. Give such a trunk a context without that, such as the pbx-inbound-<trunk> pbx gives it, or list it in pbx.tieLines if it connects another PBX whose callers may dial out."
      ];
    };

    # a tie line may, and a menu between the trunk and the phones' numbers
    # takes a key press first
    trunksOnPurpose = {
      module = {config, ...}: let
        trunk = context: {
          host = "sip.branch.example";
          username = "5552000";
          password = config.lib.asterisk.secret "/run/secrets/branch";
          inherit context;
        };
      in {
        pbx.tieLines = ["branch"];
        services.asterisk = {
          pjsip.trunks = {
            branch = trunk "pbx-internal";
            lobby = trunk "from-lobby";
          };
          dialplan.contexts.from-lobby.extensions.s = ["Goto(pbx-ivr-main,s,1)"];
        };
      };
      assertions = [];
    };

    unknownTieLine = {
      module.pbx.tieLines = ["brnach"];
      assertion = "pbx.tieLines: brnach";
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

    # with the prefix 9 and no route of its own, 911 would reach the trunk as 11
    outboundWithoutEmergency = {
      module.pbx.emergency = lib.mkForce null;
      assertions = [
        ''
          pbx.outbound is set but pbx.emergency is not, so an emergency number dialled from a phone goes out as a number outside, or nowhere: with the prefix 9, 911 reaches the trunk as 11. Add the emergency numbers where the PBX is, such as
            pbx.emergency.numbers = [ "911" ];
          which go out through pbx.outbound.trunk unless pbx.emergency.trunk names another, or, if this PBX makes no emergency calls,
            pbx.emergency.numbers = [ ];
        ''
      ];
    };

    # an empty list says so, and needs no trunk
    outboundWithoutEmergencyNumbers = {
      module.pbx.emergency = lib.mkForce {numbers = [];};
      assertions = [];
    };

    # but only written out: emergency settings without numbers say nothing
    emergencyNumbersUnset = {
      module.pbx.emergency = lib.mkForce {callerId = "5551000";};
      throws = true;
    };

    # emergency calls go out through pbx.outbound's trunk unless they name one
    emergencyThroughOutboundTrunk = {
      module.pbx.emergency = lib.mkForce {numbers = ["911"];};
      assertions = [];
    };

    emergencyWithoutTrunk = {
      module.pbx = {
        outbound = lib.mkForce null;
        emergency = lib.mkForce {numbers = ["911"];};
      };
      assertions = ["pbx.emergency: emergency calls need a trunk; set pbx.emergency.trunk, or pbx.outbound, whose trunk they then go out through."];
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

    # its length is known only once the secret is read
    phonesAdminPasswordInterpolated = {
      module = {config, ...}: {
        imports = [phones];
        pbx.phones = {
          adminPassword = "${config.lib.asterisk.secret "/run/secrets/ht801-admin"}";
          devices."201" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertions = [];
      warnings = [];
    };

    # an integer lands in the store just like a string
    phonesIntegerAdminPasswordWarns = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = 1234;
          devices."201" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertions = [];
      warning = "pbx.phones.adminPassword is not a secret reference";
    };

    # V2 hardware takes 4 to 30 characters and V1 hardware ! to ~, from
    # adminPassword or an adapter's own P2
    grandstreamAdminPassword = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = 123;
          devices = lib.mapAttrs (_: device:
            device
            // {
              model = "grandstream-ht801";
              lines = ["201"];
            }) {
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
            space = {
              mac = "c0:74:ad:00:02:05";
              settings.P2 = "open sesame";
            };
            umlaut = {
              mac = "c0:74:ad:00:02:06";
              settings.P2 = builtins.fromJSON ''"k\u00e4se"'';
            };
          };
        };
      };
      assertions = ["pbx.phones: the admin password (P2) of long, short, space, umlaut is not 4 to 30 characters from ASCII 33 (!) to 126 (~), which Grandstream's V2 hardware requires of the length and V1 hardware of the characters."];
    };

    # XML holds no control character but tab and line breaks, and a P-value
    # is one line: from the options, and from the endpoint's user name
    grandstreamControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          grandstream.timeZone = "CET-1CEST\n";
          devices = {
            "201" = {
              model = "grandstream-ht801";
              mac = "c0:74:ad:00:02:01";
              settings.P1362 = "de\tx";
            };
            "202" = {
              model = "grandstream-ht801";
              mac = "c0:74:ad:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: P-values cannot contain control characters: 201 P64, 201 P1362, 202 P36, 202 P64."];
    };

    # listening on :: serves adapters that are given the PBX's address
    grandstreamWildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          sipServer = "10.0.20.10";
          grandstream.settings.P237 = "10.0.20.10";
          devices."201" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # two spellings of one address would be one file
    phonesSameMacTwice = {
      module = {
        imports = [phones];
        pbx.phones.devices = {
          "201" = {
            model = "yealink-t33g";
            mac = "c0:74:ad:00:02:01";
          };
          # its file has the Yealink's name too, which the assertion reports
          # instead of a conflict between the two files
          "202" = {
            model = "poly-vvx450";
            mac = "C0-74-AD-00-02-01";
          };
        };
      };
      assertions = ["pbx.phones.devices: MAC addresses must be unique."];
    };

    # host:port and [v6]:port, where the port belongs in sipPort
    phonesSipServerWithPort = {
      module = {
        imports = [phones];
        pbx.phones = {
          sipServer = "10.0.20.10:5070";
          devices."201" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
          };
        };
      };
      assertions = [''pbx.phones.sipServer is "10.0.20.10:5070", but takes the host alone; give the port in pbx.phones.sipPort.''];
    };

    # the device has nowhere to put the endpoints past its last line
    phonesTooManyLines = {
      module = {
        imports = [phones];
        pbx.phones.devices = {
          kitchen = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
            lines = ["201" "202"];
          };
          garage = {
            model = "grandstream-ht812";
            mac = "c0:74:ad:00:02:02";
            lines = ["201" "202" null];
          };
        };
      };
      assertions = [
        "pbx.phones.devices.garage: a grandstream-ht812 has 2 lines, but lines lists 3."
        "pbx.phones.devices.kitchen: a grandstream-ht801 has 1 line, but lines lists 2."
      ];
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
          devices."201" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:01";
            allowedAddress = "10.0.20.021";
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
    phonesEndpointWithRenamedAor = {
      module = {
        imports = [phones];
        services.asterisk.pjsip.endpoints."201".aor.name = "kitchen";
        pbx.phones.devices."201" = {
          model = "grandstream-ht801";
          mac = "c0:74:ad:00:02:01";
        };
      };
      assertion = "an `aor` named like the endpoint";
    };

    # the assertion, not an error from the file of an adapter whose endpoint
    # does not exist or has no auth
    phonesEndpointMissing = {
      module = {
        imports = [phones];
        services.asterisk.pjsip.endpoints.kitchen.context = "pbx-internal";
        pbx.phones.devices = {
          "299" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:99";
          };
          garage = {
            model = "grandstream-ht814";
            mac = "c0:74:ad:00:02:98";
            lines = ["201" "kitchen" null "299"];
          };
        };
      };
      assertions = [
        "pbx.phones.devices.299: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: `299`."
        "pbx.phones.devices.garage: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: `kitchen`, `299`."
        "services.asterisk: PJSIP endpoint(s) kitchen have neither auth nor identify, so anyone who reaches the SIP port can register as them, and call from their context by naming them in From. Give each a password (pjsip.endpoints.<name>.auth.password) or an identify for a device known by its address, or set open = true where anyone may use them on purpose."
      ];
    };

    # P47 and P747 name where the adapter registers and P237 where it fetches
    # its file; a socket on 0.0.0.0 or :: listens on every address, which no
    # device can connect to
    grandstreamWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "grandstream-ht801";
              mac = "c0:74:ad:00:02:01";
            };
            "202" = {
              model = "grandstream-ht802";
              mac = "c0:74:ad:00:02:02";
              lines = ["202" "201"];
              settings = {
                P47 = "0.0.0.0:5060";
                P237 = "[fd00:20::10]:8080";
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: P-values that send devices to 0.0.0.0 or ::, which no device can reach: 201 P47, 201 P237, 202 P47, 202 P747. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.P237."];
    };

    # a phone's account 7 registers at P50602
    grandstreamPhoneWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          devices.desk = {
            model = "grandstream-grp2614";
            mac = "c0:74:ad:00:02:01";
            lines = ["201" null null null null null "202"];
          };
        };
      };
      assertions = ["pbx.phones.devices: P-values that send devices to 0.0.0.0 or ::, which no device can reach: desk P47, desk P237, desk P50602. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.P237."];
    };

    # the adapters' rule on the admin password is not the phones'
    grandstreamPhoneAdminPassword = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = "open sesame";
          devices.desk = {
            model = "grandstream-gxp2130";
            mac = "c0:74:ad:00:02:01";
            lines = ["201"];
          };
        };
      };
      assertions = [];
    };

    # a file sets a password of 1 to 32 characters from ! to ~ but the colon,
    # after the user name: from adminPassword or a phone's own setting
    yealinkAdminPassword = {
      module = {config, ...}: {
        imports = [phones];
        pbx.phones = {
          adminPassword = 123;
          devices = lib.mapAttrs (_: device:
            device
            // {
              model = "yealink-t30";
              lines = ["201"];
            }) {
            integer.mac = "80:5e:c0:00:02:01";
            four = {
              mac = "80:5e:c0:00:02:02";
              settings."static.security.user_password" = "admin:abcd";
            };
            thirtyTwo = {
              mac = "80:5e:c0:00:02:03";
              settings."static.security.user_password" = "admin:${lib.strings.replicate 32 "x"}";
            };
            secret = {
              mac = "80:5e:c0:00:02:04";
              settings."static.security.user_password" = "admin:${config.lib.asterisk.secret "/run/secrets/yealink-admin"}";
            };
            long = {
              mac = "80:5e:c0:00:02:05";
              settings."static.security.user_password" = "admin:${lib.strings.replicate 33 "x"}";
            };
            space = {
              mac = "80:5e:c0:00:02:06";
              settings."static.security.user_password" = "admin:open sesame";
            };
            colon = {
              mac = "80:5e:c0:00:02:07";
              settings."static.security.user_password" = "admin:a:b";
            };
            empty = {
              mac = "80:5e:c0:00:02:08";
              settings."static.security.user_password" = "admin:";
            };
            noUser = {
              mac = "80:5e:c0:00:02:09";
              settings."static.security.user_password" = "abcd";
            };
            umlaut = {
              mac = "80:5e:c0:00:02:0a";
              settings."static.security.user_password" = builtins.fromJSON ''"admin:käse"'';
            };
          };
        };
      };
      assertions = ["pbx.phones: static.security.user_password of colon, empty, long, noUser, space, umlaut is not <user name>:<password> with a password of 1 to 32 characters from ASCII 33 (!) to 126 (~) other than the colon, which is what Yealink phones take from a configuration file."];
    };

    # a value is one line: from the options, and from the endpoint's user name
    yealinkControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          yealink.settings."account.1.label" = "Front\n";
          devices = {
            "201" = {
              model = "yealink-t30";
              mac = "80:5e:c0:00:02:01";
              settings."lang.gui" = "German\tx";
            };
            "202" = {
              model = "yealink-t30";
              mac = "80:5e:c0:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Yealink settings cannot contain control characters: 201 account.1.label, 201 lang.gui, 202 account.1.auth_name, 202 account.1.label."];
    };

    # the accounts' SIP servers name where the phone registers and the
    # provisioning URL where it fetches its file; a socket on 0.0.0.0 or ::
    # listens on every address, which no phone can connect to
    yealinkWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "yealink-t30";
              mac = "80:5e:c0:00:02:01";
            };
            "202" = {
              model = "yealink-t31";
              mac = "80:5e:c0:00:02:02";
              lines = ["202" "201"];
              settings = {
                "account.2.sip_server.2.address" = "0.0.0.0";
                "static.auto_provision.server.url" = "http://[fd00:20::10]:8080/";
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Yealink settings that send phones to 0.0.0.0 or ::, which no phone can reach: 201 account.1.sip_server.1.address, 201 static.auto_provision.server.url, 202 account.1.sip_server.1.address, 202 account.2.sip_server.1.address, 202 account.2.sip_server.2.address. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings.\"static.auto_provision.server.url\"."];
    };

    # listening on :: serves phones that are given the PBX's address
    yealinkWildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          sipServer = "10.0.20.10";
          yealink.settings."static.auto_provision.server.url" = "http://10.0.20.10/";
          devices."201" = {
            model = "yealink-t30";
            mac = "80:5e:c0:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # a key with a model prefix or a space would not be one parameter
    yealinkSettingsKeys = {
      module = {
        imports = [phones];
        pbx.phones = {
          yealink.settings = {
            "account.1.label" = "Front";
            "[T46S]features.dnd_mode" = 1;
          };
          devices."201" = {
            model = "yealink-t30";
            mac = "80:5e:c0:00:02:01";
            settings."lang gui" = "German";
          };
        };
      };
      assertions = ["pbx.phones: settings of Yealink devices must be configuration parameters such as local_time.time_zone, letters, digits and _ in parts separated by dots."];
    };

    # 1 to 32 characters of ASCII without < and >, and not the factory default
    # 456, from adminPassword or a phone's own parameter
    polyAdminPassword = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = "456";
          devices = lib.mapAttrs (_: device:
            {
              model = "poly-vvx150";
              lines = ["201"];
            }
            // device) {
            default.mac = "64:16:7f:00:02:01";
            one = {
              mac = "64:16:7f:00:02:02";
              settings."device.auth.localAdminPassword" = "x";
            };
            thirtyTwo = {
              mac = "64:16:7f:00:02:03";
              settings."device.auth.localAdminPassword" = lib.strings.replicate 32 "x";
            };
            space = {
              mac = "64:16:7f:00:02:04";
              settings."device.auth.localAdminPassword" = "open sesame";
            };
            integer = {
              mac = "64:16:7f:00:02:05";
              settings."device.auth.localAdminPassword" = 1234;
            };
            empty = {
              mac = "64:16:7f:00:02:06";
              settings."device.auth.localAdminPassword" = "";
            };
            long = {
              mac = "64:16:7f:00:02:07";
              settings."device.auth.localAdminPassword" = lib.strings.replicate 33 "x";
            };
            chevron = {
              mac = "64:16:7f:00:02:08";
              settings."device.auth.localAdminPassword" = "a<b";
            };
            umlaut = {
              mac = "64:16:7f:00:02:09";
              settings."device.auth.localAdminPassword" = builtins.fromJSON ''"k\u00e4se"'';
            };
          };
        };
      };
      assertions = ["pbx.phones: the admin password (device.auth.localAdminPassword) of chevron, default, empty, long, umlaut is not 1 to 32 characters of ASCII without < and >, or is 456, the factory default, none of which Poly phones take."];
    };

    # an attribute value holds no control character, from the options and from
    # the endpoint's user name
    polyControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          poly.settings."lcl.ml.lang" = "German\tGermany";
          devices = {
            "201" = {
              model = "poly-vvx150";
              mac = "64:16:7f:00:02:01";
              settings."reg.1.label" = "Front\ndesk";
            };
            "202" = {
              model = "poly-edge-e100";
              mac = "64:16:7f:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Poly parameters cannot contain control characters: 201 lcl.ml.lang, 201 reg.1.label, 202 lcl.ml.lang, 202 reg.1.auth.userId."];
    };

    # device.prov.serverName names where the phone fetches its files and
    # reg.x.server.y.address where it registers; a socket on 0.0.0.0 or ::
    # listens on every address, which no phone can connect to
    polyWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "poly-vvx150";
              mac = "64:16:7f:00:02:01";
            };
            "202" = {
              model = "poly-edge-e100";
              mac = "64:16:7f:00:02:02";
              lines = ["202" "201"];
              settings = {
                "device.prov.serverName" = "http://[fd00:20::10]:8080";
                "reg.1.server.2.address" = "0.0.0.0";
              };
            };
          };
        };
      };
      assertions = [''pbx.phones.devices: Poly parameters that send phones to 0.0.0.0 or ::, which no phone can reach: 201 device.prov.serverName, 201 reg.1.server.1.address, 202 reg.1.server.1.address, 202 reg.1.server.2.address, 202 reg.2.server.1.address. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings."device.prov.serverName".''];
    };

    # listening on :: serves phones that are given the PBX's address
    polyWildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          sipServer = "10.0.20.10";
          poly.settings."device.prov.serverName" = "http://10.0.20.10";
          devices."201" = {
            model = "poly-vvx150";
            mac = "64:16:7f:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # parameter names become XML attribute names
    polySettingsKeys = {
      module = {
        imports = [phones];
        pbx.phones = {
          poly.settings = {
            "reg.1.label" = "Front";
            "acd-agent-available" = 1;
            "1st.key" = 1;
            "has space" = 1;
            "a..b" = 1;
          };
          devices."201" = {
            model = "poly-vvx150";
            mac = "64:16:7f:00:02:01";
            settings."reg.1.label=x" = 1;
          };
        };
      };
      assertions = [''pbx.phones: settings of Poly devices must be parameter names such as reg.1.label, parts of letters, digits, _ and - separated by dots and starting with a letter: "1st.key", "a..b", "has space", "reg.1.label=x".''];
    };

    # a setting is `name` or `name[index]`, without a leading zero, from
    # snom.settings or a phone's settings
    snomSettingKeys = {
      module = {
        imports = [phones];
        pbx.phones = {
          snom.settings."user_active.1" = "on";
          devices."201" = {
            model = "snom-d785";
            mac = "00:04:13:00:02:01";
            settings."user_realname[01]" = "Reception";
          };
        };
      };
      assertions = ["pbx.phones: settings of Snom phones must be setting names such as language, or name[index] for an indexed one such as user_realname[1]."];
    };

    # XML holds no control character but tab and line breaks, and a setting is
    # one line: from the options, and from the endpoint's user name
    snomControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          snom.timeZone = "GER+1\n";
          devices = {
            "201" = {
              model = "snom-d785";
              mac = "00:04:13:00:02:01";
              settings.language = "Deutsch\tx";
            };
            "202" = {
              model = "snom-d785";
              mac = "00:04:13:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Snom settings cannot contain control characters: 201 language, 201 timezone, 202 timezone, 202 user_pname[1]."];
    };

    # user_host names where a line registers and setting_server where the phone
    # fetches its file; a socket on 0.0.0.0 or :: listens on every address,
    # which no phone can connect to
    snomWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "snom-d785";
              mac = "00:04:13:00:02:01";
            };
            "202" = {
              model = "snom-d315";
              mac = "00:04:13:00:02:02";
              lines = ["202" "201"];
              settings = {
                setting_server = "http://[fd00:20::10]:8080/snomD315-{mac}.htm";
                "user_host[2]" = "0.0.0.0:5060";
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Snom settings that send phones to 0.0.0.0 or ::, which no phone can reach: 201 setting_server, 201 user_host[1], 202 user_host[1], 202 user_host[2]. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings.setting_server."];
    };

    # listening on :: serves phones that are given the PBX's address; with no
    # file name in setting_server a phone requests its own file by name
    snomWildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          sipServer = "10.0.20.10";
          snom.settings.setting_server = "http://10.0.20.10/";
          devices."201" = {
            model = "snom-d785";
            mac = "00:04:13:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # the multiplatform firmware takes 8 to 127 characters from ! to ~ of three
    # kinds, the ATA 191 and 192 at least 8 and the SPA112 and SPA122 at most
    # 32, from adminPassword or a device's own setting; the SPA phones have no
    # rule
    ciscoAdminPassword = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = "Abcdefg1";
          devices = lib.mapAttrs (_: device: device // {lines = ["201"];}) {
            good = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:01";
            };
            short = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:02";
              settings.Admin_Password = "Abc!123";
            };
            twoKinds = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:03";
              settings.Admin_Password = "abcdefg1";
            };
            space = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:04";
              settings.Admin_Password = "Abc defg1";
            };
            umlaut = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:05";
              settings.Admin_Password = builtins.fromJSON ''"Käsebrot1"'';
            };
            ata = {
              model = "cisco-ata191";
              mac = "00:62:ec:00:02:06";
              settings."router-configuration/Web_Login_Admin_Password" = "1234567";
            };
            spa112 = {
              model = "cisco-spa112";
              mac = "00:62:ec:00:02:07";
              settings."router-configuration/Web_Login_Admin_Password" = lib.strings.replicate 33 "x";
            };
            spa504g = {
              model = "cisco-spa504g";
              mac = "00:62:ec:00:02:08";
              settings.Admin_Passwd = "x";
            };
          };
        };
      };
      assertions = [
        "pbx.phones: the admin password (router-configuration/Web_Login_Admin_Password) of ata is not at least 8 characters, which the ATA 191 and ATA 192 require."
        "pbx.phones: the admin password (Admin_Password) of short, space, twoKinds, umlaut is not 8 to 127 characters from ASCII 33 (!) to 126 (~) of three kinds out of capital letters, small letters, digits and others, which the multiplatform firmware requires."
        "pbx.phones: the admin password (router-configuration/Web_Login_Admin_Password) of spa112 is not at most 32 characters, which the SPA112 and SPA122 take."
      ];
    };

    # XML holds no control character but tab and line breaks, and a setting is
    # one line: from the options, and from the endpoint's user name
    ciscoControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          cisco.settings."router-configuration/Time_Setup/Time_Zone" = "+01 2 2\n";
          devices = {
            "201" = {
              model = "cisco-spa504g";
              mac = "00:62:ec:00:02:01";
              settings.Time_Zone = "GMT\t";
            };
            "202" = {
              model = "cisco-ata191";
              mac = "00:62:ec:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: settings of Cisco devices cannot contain control characters: 201 Time_Zone, 201 router-configuration/Time_Setup/Time_Zone, 202 Auth_ID_1_, 202 router-configuration/Time_Setup/Time_Zone."];
    };

    # Proxy_n_ names where a line registers and Profile_Rule where the device
    # fetches its file; a socket on 0.0.0.0 or :: listens on every address,
    # which no device can connect to
    ciscoWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:01";
            };
            "202" = {
              model = "cisco-ata191";
              mac = "00:62:ec:00:02:02";
              lines = ["202" "201"];
              settings = {
                Proxy_2_ = "0.0.0.0:5060";
                Profile_Rule = "http://[fd00:20::10]:8080/$MA.xml";
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: settings that send Cisco devices to 0.0.0.0 or ::, which no device can reach: 201 Profile_Rule, 201 Proxy_1_, 202 Proxy_1_, 202 Proxy_2_. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.Profile_Rule."];
    };

    # an element name cannot hold a space, start with a digit or be empty
    ciscoSettingNames = {
      module = {
        imports = [phones];
        pbx.phones = {
          cisco.settings."Time Zone" = "GMT";
          devices."201" = {
            model = "cisco-8841";
            mac = "00:62:ec:00:02:01";
            settings = {
              "1st" = "x";
              "router-configuration//Time_Zone" = "x";
            };
          };
        };
      };
      assertions = ["pbx.phones: settings of Cisco devices must be XML element names such as Primary_NTP_Server, or paths of them such as router-configuration/Time_Setup/Time_Zone."];
    };

    # every Fanvil firmware takes 1 to 39 letters and digits, from adminPassword
    # or a device's own web.account.1.Password
    fanvilAdminPassword = {
      module = {
        imports = [phones];
        pbx.phones = {
          adminPassword = "abc123";
          devices = lib.mapAttrs (_: device:
            device
            // {
              model = "fanvil-x301";
              lines = ["201"];
            }) {
            global.mac = "0c:38:3e:00:02:01";
            integer = {
              mac = "0c:38:3e:00:02:02";
              settings."web.account.1.Password" = 1234;
            };
            longest = {
              mac = "0c:38:3e:00:02:03";
              settings."web.account.1.Password" = lib.strings.replicate 39 "x";
            };
            long = {
              mac = "0c:38:3e:00:02:04";
              settings."web.account.1.Password" = lib.strings.replicate 40 "x";
            };
            empty = {
              mac = "0c:38:3e:00:02:05";
              settings."web.account.1.Password" = "";
            };
            symbol = {
              mac = "0c:38:3e:00:02:06";
              settings."web.account.1.Password" = "pa$$word";
            };
            umlaut = {
              mac = "0c:38:3e:00:02:07";
              settings."web.account.1.Password" = builtins.fromJSON ''"k\u00e4se"'';
            };
          };
        };
      };
      assertions = ["pbx.phones: the admin password (web.account.1.Password) of empty, long, symbol, umlaut is not 1 to 39 letters and digits, which is what every Fanvil firmware takes (the X1S, X1SG, X3SG, X3U and X305 take no symbols)."];
    };

    # an XML value holds no control character but tab and line breaks, and a
    # setting is one line: from the options, and from the endpoint's user name
    fanvilControlCharacters = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        pbx.phones = {
          fanvil.settings."phone.display.LCDTitle" = "Front\n";
          devices = {
            "201" = {
              model = "fanvil-x301";
              mac = "0c:38:3e:00:02:01";
              settings."sip.line.1.DisplayName" = "Front\tDesk";
            };
            "202" = {
              model = "fanvil-x301";
              mac = "0c:38:3e:00:02:02";
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Fanvil settings cannot contain control characters: 201 phone.display.LCDTitle, 201 sip.line.1.DisplayName, 202 phone.display.LCDTitle, 202 sip.line.1.RegisterUser."];
    };

    # ap.FlashServerIP names where the phone fetches its file and each line's
    # RegisterAddr where it registers, a used line's or one given in settings;
    # a socket on 0.0.0.0 or :: listens on every address, which no phone can
    # connect to
    fanvilWildcardServers = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          devices = {
            "201" = {
              model = "fanvil-x301";
              mac = "0c:38:3e:00:02:01";
            };
            "202" = {
              model = "fanvil-x303";
              mac = "0c:38:3e:00:02:02";
              lines = ["202" null "201"];
              settings = {
                "ap.FlashServerIP" = "http://[fd00:20::10]:8080";
                "sip.line.2.RegisterAddr" = "0.0.0.0";
              };
            };
          };
        };
      };
      assertions = ["pbx.phones.devices: Fanvil settings that send devices to 0.0.0.0 or ::, which no device can reach: 201 ap.FlashServerIP, 201 sip.line.1.RegisterAddr, 202 sip.line.1.RegisterAddr, 202 sip.line.2.RegisterAddr, 202 sip.line.3.RegisterAddr. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.\"ap.FlashServerIP\"."];
    };

    # listening on :: serves phones that are given the PBX's address
    fanvilWildcardListenWithAddresses = {
      module = {
        imports = [phones];
        pbx.phones = {
          listenAddress = lib.mkForce "::";
          sipServer = "10.0.20.10";
          fanvil.settings."ap.FlashServerIP" = "http://10.0.20.10";
          devices."201" = {
            model = "fanvil-x301";
            mac = "0c:38:3e:00:02:01";
          };
        };
      };
      assertions = [];
    };

    # an element's index follows its name and a value is an element, never an
    # index
    fanvilSettingsKeys = {
      module = {
        imports = [phones];
        pbx.phones = {
          fanvil.settings = {
            "web.account.1" = "x";
            "phone..date" = "x";
            "phone.display.DefaultLanguage" = "en";
          };
          devices."201" = {
            model = "fanvil-x301";
            mac = "0c:38:3e:00:02:01";
            settings = {
              "1st.key" = "x";
              "sip.line.1.2.DisplayName" = "x";
              "phone date" = "x";
              "DHCPOption100-101" = 1;
            };
          };
        };
      };
      assertions = [''pbx.phones: settings of Fanvil devices must be paths of sysConf elements such as sip.line.1.DisplayName: "phone..date", "web.account.1", "1st.key", "phone date", "sip.line.1.2.DisplayName".''];
    };

    # one element cannot hold both a value and other elements
    fanvilNestedKeys = {
      module = {
        imports = [phones];
        pbx.phones = {
          ntpServer = "10.0.20.1";
          fanvil.settings."phone.date" = "x";
          devices."201" = {
            model = "fanvil-x301";
            mac = "0c:38:3e:00:02:01";
            settings."sip.line.1.PhoneNumber.Extra" = "y";
          };
        };
      };
      assertions = ["pbx.phones.devices: Fanvil settings that other settings are below, which one XML element cannot be: 201 phone.date, 201 sip.line.1.PhoneNumber."];
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

    # flite's English voice skips what is not ASCII, and speaks a text with no
    # ASCII letter or digit as 0.185 s of silence; one with some is spoken
    ivrPromptTextsFliteCannotSpeak = {
      module.pbx.ivrs = lib.mapAttrs (_: text: {prompt.text = text;}) {
        blank = "";
        dots = "...";
        umlaut = builtins.fromJSON ''"\u00fc"'';
        kanji = builtins.fromJSON ''"\u65e5\u672c\u8a9e"'';
        greeting = builtins.fromJSON ''"Gr\u00fc\u00dfe"'';
        number = "2";
      };
      assertions = [
        ''pbx.ivrs: flite speaks these prompt texts as silence, since they hold no ASCII letter or digit: pbx.ivrs.blank.prompt.text, pbx.ivrs.dots.prompt.text, pbx.ivrs.kanji.prompt.text, pbx.ivrs.umlaut.prompt.text. Write the text in English, or for a menu without a prompt use prompt.sound = "silence/1".''
      ];
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
        "east&west" = {
          number = "654";
          members = ["201"];
        };
      };
      assertion = ''
        pbx.paging: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ ( ) ^ or &):
          pbx.paging."a,b"
          pbx.paging."a^b"
          pbx.paging."all (east)"
          pbx.paging."east&west"
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
