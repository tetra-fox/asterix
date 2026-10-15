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
    imports = [self.nixosModules.default];
    services.asterix = {
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
  phones.services.asterix.phones = {
    listenAddress = "10.0.20.10";
    allowedNetworks = lib.mkDefault ["10.0.20.0/24"];
  };

  cases = {
    baselineIsValid = {
      module = {};
      assertions = [];
      warnings = [];
    };

    # every kind of number on 9911, which is also 911 after the prefix, and
    # two of each named kind on a number of their own; a call pickup on 9911
    # takes it from all of them
    everyKindOfNumberClashes = let
      owners = [
        ''services.asterix.extensions."9911"''
        "services.asterix.ringGroups.clash"
        "services.asterix.queues.clash"
        "services.asterix.conferences.clash"
        "services.asterix.ivrs.clash"
        "services.asterix.paging.clash"
        "services.asterix.voicemailMenu"
        "services.asterix.hours.clash.closeEarly"
        "services.asterix.emergency.numbers (911 after services.asterix.outbound.prefix)"
        "services.asterix.emergency.numbers"
      ];
      # the object named clash on 9911, and one and two on `twins`
      named = twins: object: {
        clash = object "9911";
        one = object twins;
        two = object twins;
      };
    in {
      module = {config, ...}: {
        services.asterix = {
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
          services.asterix: numbers with more than one owner:
            601: services.asterix.ringGroups.one, services.asterix.ringGroups.two
            602: services.asterix.queues.one, services.asterix.queues.two
            603: services.asterix.conferences.one, services.asterix.conferences.two
            604: services.asterix.ivrs.one, services.asterix.ivrs.two
            605: services.asterix.paging.one, services.asterix.paging.two
            606: services.asterix.hours.one.closeEarly, services.asterix.hours.two.closeEarly
            9911: ${lib.concatStringsSep ", " owners}
        ''
        ''services.asterix: chan_pjsip takes a call to 9911, the pickupexten of features.conf, as a call pickup before the dialplan runs, so it never reaches ${lib.concatStringsSep ", " owners}, services.asterix.inbound."9911". Use another number, or change services.asterisk.features.general.pickupexten.''
      ];
    };

    # a number, s or a pattern of numbers: an extension of the trunk's
    # context such as h, which Asterisk runs at every hangup, or one with a
    # letter, which a caller would have to send, is none of them. The keys
    # from +15551001 on are valid and stay out of the message.
    inboundKeys = {
      module.services.asterix.inbound = lib.genAttrs ["5551abc" "h" "S" "1+5551000" "555-1000" "_" "_[]" "_555abc" "_555-XXXX" "+15551001" "*5551002#" "s" "_X." "_555XXXX" "_[2-9]xx!" "_+1NXXNXXXXXX" "_*[0-9#]Z"] (_: {
        trunk = "provider";
        destination.hangup = true;
      });
      assertions = [
        ''services.asterix.inbound: keys must be a number of digits, * and #, with an optional leading +; s, which takes the calls that name no number; or a pattern of such numbers that starts with _, such as _X.: services.asterix.inbound."1+5551000", services.asterix.inbound."555-1000", services.asterix.inbound."5551abc", services.asterix.inbound.S, services.asterix.inbound._, services.asterix.inbound._555-XXXX, services.asterix.inbound._555abc, services.asterix.inbound."_[]", services.asterix.inbound.h.''
      ];
    };

    # list definitions concatenate, so steps added to a context the pbx writes
    # run before or after its own; replaced steps, an extension of its own and
    # raw lines are the user's
    stepsAddedToGeneratedContexts = {
      module.services.asterisk.dialplan.contexts = {
        pbx-internal.extensions."201" = ["NoOp(extra)"];
        pbx-extension-201.extensions.s = ["NoOp(extra)"];
        pbx-extension-202.extensions.s = lib.mkForce ["Dial(PJSIP/202)"];
        pbx-ringgroup-front.extensions = {
          s = lib.mkBefore ["NoOp(first)"];
          h = ["NoOp(hung up)"];
        };
        pbx-ivr-main.extraConfig = "exten => s,n,NoOp(extra)";
        pbx-inbound-provider.extensions."5551000" = ["NoOp(extra)"];
        pbx-outbound.extensions."_9X." = ["NoOp(extra)"];
        pbx-emergency.extensions."911" = lib.mkBefore ["NoOp(first)"];
      };
      assertions = [
        "services.asterix: steps were added to pbx-emergency/911, pbx-extension-201/s, pbx-inbound-provider/5551000, pbx-internal/201, pbx-outbound/_9X., pbx-ringgroup-front/s from elsewhere, so they run before or after the layer's own. Change these through the services.asterix options, or replace their steps with lib.mkForce; steps of your own can go in the context's extraConfig, which is written as it is, or in a context of your own that a `context` destination names."
      ];
    };

    # and lines of settings follow them; a number the pbx does not own is the
    # user's
    stepsAddedToGeneratedContextsThroughSettings = {
      module.services.asterisk.settings."extensions.conf" = {
        pbx-queue-support.exten = ["s,4,NoOp(extra)"];
        pbx-internal.exten = ["*72,1,Playback(beep)"];
      };
      assertions = [
        ''services.asterix: steps were added to pbx-queue-support/s from elsewhere, as lines of services.asterisk.settings."extensions.conf". Change these through the services.asterix options; steps of your own can go in the context's extraConfig, which is written as it is, or in a context of your own that a `context` destination names.''
      ];
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
          services.asterix: destinations that do not exist:
            ${lib.concatMapStringsSep "\n  " (slot: "${slot.where}: ${described.${slot.kind}}") missing.slots}
        ''
      ];
    };

    # each comes back to where it started without a key press, so the call
    # rings or plays on until the caller hangs up: an extension that is busy
    # and a group that rings it, two groups, a queue and a menu on their own.
    # A key press breaks the round: the menu's key 9 and invalid key lead back
    # to it, and lobby sends callers back to the menu whose key 2 rings it.
    destinationLoops = {
      module.services.asterix = {
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
          lobby = {
            members = ["201"];
            noAnswer.ivr = "main";
          };
        };
        queues.support.noAnswer.queue = "support";
        ivrs.main = {
          options = {
            "2".ringGroup = "lobby";
            "9".ivr = "main";
          };
          noInput.ivr = "main";
          invalid.ivr = "main";
        };
      };
      assertions = [
        ''
          services.asterix: destinations that lead back to their own object without a key press, so a call goes round until the caller hangs up:
            services.asterix.extensions."202".busy: ringGroup front
            services.asterix.ringGroups.back.noAnswer: ringGroup side
            services.asterix.ringGroups.front.noAnswer: extension 202
            services.asterix.ringGroups.side.noAnswer: ringGroup back
            services.asterix.queues.support.noAnswer: queue support
            services.asterix.ivrs.main.noInput: ivr main
          Send one of them elsewhere, such as to voicemail; a voice menu's options and invalid key may lead back, since the caller presses a key for those.
        ''
      ];
    };

    # VoiceMail() takes the context in any case, but files the message under
    # the mailbox as dialed, and reaches no mailbox through an alias
    voicemailDestinationContextInAnyCase = {
      module = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        services.asterix = {
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
          services.asterix: destinations that do not exist:
            services.asterix.ringGroups.front.noAnswer: voicemail 1234@devices
            services.asterix.queues.support.noAnswer: voicemail Alice@Sales
        ''
      ];
    };

    # trunks, extensions and hours that pbx objects name but nobody defines;
    # each trunk of a number's list counts
    danglingReferences = {
      module.services.asterix = {
        inbound."5551000" = {
          trunk = lib.mkForce [
            "provider"
            "provder"
          ];
          hours = lib.mkForce "shop";
        };
        outbound.trunk = lib.mkForce "provder";
        emergency = {
          trunk = lib.mkForce "provder";
          notify = lib.mkForce ["299"];
        };
        tieLines = ["brnach"];
        ringGroups.front = {
          members = lib.mkForce [
            "201"
            "299"
          ];
          external = ["5559000"];
          trunk = "provder";
        };
        queues.support.members = [
          "201"
          "299"
        ];
        paging.all.members = lib.mkForce [
          "201"
          "299"
        ];
      };
      assertions = [
        "services.asterix.inbound: 5551000 use hours that are not defined in services.asterix.hours."
        ''
          services.asterix: trunks that are not defined in services.asterisk.pjsip.trunks:
            services.asterix.inbound."5551000".trunk: provder
            services.asterix.outbound.trunk: provder
            services.asterix.emergency.trunk: provder
            services.asterix.tieLines: brnach
        ''
        "services.asterix.emergency.notify: 299 are not extensions of services.asterix.extensions."
        ''
          services.asterix: trunks that are not defined in services.asterisk.pjsip.trunks:
            services.asterix.ringGroups.front.trunk: provder
        ''
        ''
          services.asterix.ringGroups: members that are not extensions of services.asterix.extensions:
            services.asterix.ringGroups.front: 299
        ''
        ''
          services.asterix.queues: members that are not extensions of services.asterix.extensions, where other devices go in services.asterisk.queues.queues.<name>.members:
            services.asterix.queues.support: 299
        ''
        ''
          services.asterix.paging: members that are not extensions of services.asterix.extensions:
            services.asterix.paging.all: 299
        ''
      ];
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
        services.asterix = {
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
        services.asterix: trunk names that Asterisk would misread in a dial string (they may not contain , ; [ ] " \ ''${ $[ & / or an unclosed parenthesis):
          services.asterix.outbound.trunk: a&b
          services.asterix.emergency.trunk: e''${f}
          services.asterix.ringGroups.front.trunk: c/d
      '';
    };

    # [general], in any case, holds app_queue's own settings; a queue of
    # settings counts, found in any case
    queueOnlyInPbx = {
      module = {
        services.asterix.queues = {
          Sales.number = "620";
          General.number = "621";
          east.number = "622";
        };
        services.asterisk.settings."queues.conf".sales.member = ["PJSIP/202"];
      };
      assertions = ["services.asterix.queues: General, east are not queues of queues.conf (services.asterisk.queues.queues or settings)."];
    };

    # default_bridge and default_user exist without configuration, a user
    # profile is no bridge profile, and profiles of settings count, found in
    # any case, with the type their template gives them
    conferenceProfiles = {
      module = {
        services.asterix.conferences = {
          board = {
            bridgeProfile = "quiet";
            userProfile = "default_user";
          };
          team = {
            bridgeProfile = "default_bridge";
            userProfile = "nobody";
          };
          lobby = {
            bridgeProfile = "Small";
            userProfile = "guest";
          };
        };
        services.asterisk = {
          confbridge.users.quiet.quiet = true;
          settings."confbridge.conf" = {
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
      assertions = [
        ''
          services.asterix.conferences: profiles that are not defined:
            services.asterix.conferences.board.bridgeProfile: quiet
            services.asterix.conferences.team.userProfile: nobody
        ''
      ];
    };

    # a destination and hours, hours without closed, neither, and open and
    # closed without hours; the assertion, not an error from the dialplan of
    # a number with no hours
    incompleteInbound = {
      module.services.asterix.inbound = {
        "5551000".destination.ringGroup = "front";
        "5551001".trunk = "provider";
        "5551002" = {
          trunk = "provider";
          open.ringGroup = "front";
          closed.voicemail = "201";
        };
        "5551003" = {
          trunk = "provider";
          hours = "office";
          open.ringGroup = "front";
        };
      };
      assertion = "services.asterix.inbound: 5551000, 5551001, 5551002, 5551003 need either `destination`, or `hours` with `open` and `closed`.";
    };

    # where calls from a trunk start is its endpoint's context in the final
    # pjsip.conf. Calls from branch, lobby and annex start where the outbound
    # pattern can be dialled: in pbx-internal, which includes pbx-outbound, in
    # a context that includes it at some hours, and in one set in settings. A
    # tie line may, and a menu between the trunk and the phones' numbers takes
    # a key press first.
    trunkContexts = {
      module = {config, ...}: let
        trunk = context: {
          host = "sip.branch.example";
          username = "5552000";
          password = config.lib.asterisk.secret "/run/secrets/branch";
          inherit context;
        };
      in {
        services.asterix.tieLines = ["tie"];
        services.asterisk = {
          pjsip.trunks = {
            branch = trunk "pbx-internal";
            lobby = trunk "from-lobby";
            annex = trunk "from-annex";
            tie = trunk "pbx-internal";
            menu = trunk "from-menu";
          };
          dialplan.contexts = {
            from-lobby.includes = ["pbx-internal,08:00-18:00,*,*,*"];
            from-annex.extensions.s = ["Hangup()"];
            from-menu.extensions.s = ["Goto(pbx-ivr-main,s,1)"];
            from-provider.extensions.s = ["Hangup()"];
          };
          settings."pjsip.conf" = {
            "endpoint:annex".context = "pbx-outbound";
            "endpoint:provider".context = "from-provider";
          };
        };
      };
      assertions = [
        "services.asterix.inbound: the trunk(s) provider have a context of their own, so their calls do not reach services.asterix.inbound; remove it."
        "services.asterix: calls from the trunk(s) annex (pbx-outbound), branch (pbx-internal), lobby (from-lobby) start in a context that reaches pbx-outbound, so anyone who can call in through them can dial out, emergency numbers included. Give such a trunk a context without that, such as the pbx-inbound-<trunk> pbx gives it, or list it in services.asterix.tieLines if it connects another PBX whose callers may dial out."
      ];
    };

    # emergency settings without numbers are an error rather than an empty
    # list, which would say that the PBX makes no emergency calls
    emergencyNumbersUnset = {
      module.services.asterix.emergency = lib.mkForce {callerId = "5551000";};
      throws = true;
    };

    # GotoIfTime skips a time past 23:59, so these hours would never open
    openUntil24Throws = {
      module.services.asterix.hours.office.open = lib.mkForce [
        {
          days = "mon-fri";
          time = "09:00-24:00";
        }
      ];
      throws = true;
    };

    # feb 30 never comes, and GotoIfTime reads dec 30-2 as dec 1, 2, 30 and
    # 31; feb 29 comes in leap years, apr 30-31 closes on apr 30
    holidaysThatNeverCome = {
      module.services.asterix.hours.office.holidays = [
        "feb 30"
        "dec 30-2"
        "feb 29"
        "apr 30-31"
      ];
      assertions = [
        ''
          services.asterix.hours: holidays on a day their month does not have, or that end before they start:
            services.asterix.hours.office.holidays: feb 30
            services.asterix.hours.office.holidays: dec 30-2
        ''
      ];
    };

    # what `systemd-analyze verify` takes and refuses in IPAddressAllow= (it
    # ignores a refused entry with a warning in its own journal, and an empty
    # one resets the list), and what Rust's IpAddr parses for allowedAddress,
    # which the server compares the client's address with
    phonesAddresses = {
      module = {
        imports = [phones];
        services.asterix.phones = {
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
      assertions = [
        "services.asterix.phones.allowedNetworks: entries must be addresses, networks such as 10.0.20.0/24, or any, localhost, link-local or multicast, which is what systemd takes: `10.0.20.0/33`, `phones`, `10.0.20.021`, `[fd00::21]`, `10.0.20.0/24 phones`, ``."
        "services.asterix.phones.files: allowedAddress must be one IPv4 or IPv6 address: brackets.cfg has `[fd00::21]`, cfgc074ad000201.xml has `10.0.20.021`, name.cfg has `kitchen.lan`, network.cfg has `10.0.20.21/32`, zone.cfg has `fe80::21%voip`."
      ];
    };

    # a device registers each line with one user name, for the endpoint and its
    # aor; the assertion, not an error from the file of a device whose
    # endpoint does not exist, has no auth or an aor named otherwise
    phonesUnregisteredLines = {
      module = {
        imports = [phones];
        services.asterisk.pjsip.endpoints = {
          kitchen = {
            context = "pbx-internal";
            open = true;
          };
          "202".aor.name = "desk";
        };
        services.asterix.phones.devices = {
          "202" = {
            model = "grandstream-ht801";
            mac = "c0:74:ad:00:02:02";
          };
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
        "services.asterix.phones.devices.202: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: `202`."
        "services.asterix.phones.devices.299: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: `299`."
        "services.asterix.phones.devices.garage: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: `kitchen`, `299`."
      ];
    };

    # a value or key is one line of the file: values from the options and from
    # the endpoint's user name, and keys without a model prefix or a space
    yealinkValuesAndKeys = {
      module = {
        imports = [phones];
        # inside the value, since pjsip.conf refuses one at either end
        services.asterisk.pjsip.endpoints."202".auth.username = lib.mkForce "20${builtins.fromJSON ''"\u0007"''}2";
        services.asterix.phones = {
          yealink.settings = {
            "account.1.label" = "Front\n";
            "[T46S]features.dnd_mode" = 1;
          };
          devices = {
            "201" = {
              model = "yealink-t30";
              mac = "80:5e:c0:00:02:01";
              settings = {
                "lang.gui" = "German\tx";
                "lang gui" = "German";
              };
            };
            "202" = {
              model = "yealink-t30";
              mac = "80:5e:c0:00:02:02";
            };
          };
        };
      };
      assertions = [
        "services.asterix.phones.devices: Yealink settings cannot contain control characters: 201 account.1.label, 201 lang.gui, 202 account.1.auth_name, 202 account.1.label."
        "services.asterix.phones: settings of Yealink devices must be configuration parameters such as local_time.time_zone, letters, digits and _ in parts separated by dots."
      ];
    };

    # user_host names where a line registers and setting_server where the phone
    # fetches its file; a socket on 0.0.0.0 or :: listens on every address,
    # which no phone can connect to
    snomWildcardServers = {
      module = {
        imports = [phones];
        services.asterix.phones = {
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
      assertions = ["services.asterix.phones.devices: Snom settings that send phones to 0.0.0.0 or ::, which no phone can reach: 201 setting_server, 201 user_host[1], 202 user_host[1], 202 user_host[2]. Set services.asterix.phones.listenAddress to the PBX's address on the phones' network, or give that address in services.asterix.phones.sipServer and settings.setting_server."];
    };

    # the multiplatform firmware takes 8 to 127 characters from ! to ~ of three
    # kinds, the ATA 191 and 192 at least 8 and the SPA112 and SPA122 at most
    # 32, from adminPassword or a device's own setting; the SPA phones have no
    # rule
    ciscoAdminPassword = {
      module = {
        imports = [phones];
        services.asterix.phones = {
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
        "services.asterix.phones: the admin password (router-configuration/Web_Login_Admin_Password) of ata is not at least 8 characters, which the ATA 191 and ATA 192 require."
        "services.asterix.phones: the admin password (Admin_Password) of short, space, twoKinds, umlaut is not 8 to 127 characters from ASCII 33 (!) to 126 (~) of three kinds out of capital letters, small letters, digits and others, which the multiplatform firmware requires."
        "services.asterix.phones: the admin password (router-configuration/Web_Login_Admin_Password) of spa112 is not at most 32 characters, which the SPA112 and SPA122 take."
      ];
    };

    # one element cannot hold both a value and other elements
    fanvilNestedKeys = {
      module = {
        imports = [phones];
        services.asterix.phones = {
          ntpServer = "10.0.20.1";
          fanvil.settings."phone.date" = "x";
          devices."201" = {
            model = "fanvil-x301";
            mac = "0c:38:3e:00:02:01";
            settings."sip.line.1.PhoneNumber.Extra" = "y";
          };
        };
      };
      assertions = ["services.asterix.phones.devices: Fanvil settings that other settings are below, which one XML element cannot be: 201 phone.date, 201 sip.line.1.PhoneNumber."];
    };

    # Gosub ends its target at the first (; with closeEarly the name is also
    # in Set(), which ends the variable at =, and in a hint, which splits at &
    hoursNames = {
      module.services.asterix.hours = let
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
        services.asterix.hours: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] ''${ $[ or (, nor & or = or more than 62 bytes with closeEarly):
          services.asterix.hours."a,b"
          services.asterix.hours."a=b"
          services.asterix.hours."c&d"
          services.asterix.hours."office (east)"
      '';
    };

    # Queue's argument parser drops backslashes, and an unclosed parenthesis
    # takes the timeout into the name
    queueNames = {
      module = {
        services.asterix.queues = {
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
        services.asterix.queues: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
          services.asterix.queues."a,b"
          services.asterix.queues."a\\b"
          services.asterix.queues."c(d"
      '';
    };
  };
in {
  run = checkCases base;
  tests = cases;
}
