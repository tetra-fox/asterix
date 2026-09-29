# Ring groups, voice menus and paging of the pbx layer, checked by who rings,
# who gets the call and what each phone hears. Ring groups: ten members ring
# at once or one after the other, passing over a busy member and one that is
# not registered, and the first to answer gets the call while every other leg
# is cancelled; a group whose only member is not registered goes to its
# no-answer destination at once; an outside member, called through the
# group's own trunk or pbx.outbound's, takes the call by pressing 1, hands it
# back to the members with 2, and stops hearing the confirmation prompt as
# soon as a member answers or the caller hangs up. Voice menus: each of the
# twelve keys leads where it is set to, a key that starts an extension number
# waits for the next digit, the prompt plays as often as `attempts` says, a
# key opens a nested menu or the menu itself, and a spoken prompt of 2,000
# characters, some not ASCII, plays. Paging: twenty members hear the pager,
# who hears nobody unless the page is duplex, the pager's own extension is
# left out, a member that does not answer rings until the page ends, and
# headers the configuration sets reach the phones. Call pickup, with groups
# set on the endpoints: a phone outside a ring group takes its call with *8
# and every member stops ringing, and of two calls ringing in one pickup
# group *8 takes the one that rang first, then the other.
#
#   pbx     the trunks provider (pbx.outbound's) and second lead to carrier-a
#           and carrier-b on the phones' machine
#   phones  200 calls and pages, 201 to 220 ring until the test answers
#           them, 221 is busy, 222 never registers
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  numbers = map toString (lib.range 200 222);
  range = first: last: map toString (lib.range first last);

  # the carriers do not register; the pbx calls them on these ports
  carrierPorts = {
    provider = 5098;
    second = 5099;
  };

  # each menu's prompt is a tone above those of the phones (tests/vm/phone.py)
  promptTones = {
    keys = 2500;
    dial = 2600;
    five = 2700;
    top = 2800;
    sub = 2900;
  };
  prompts = pkgs.runCommand "test-prompts" {nativeBuildInputs = [pkgs.sox];} ''
    mkdir -p $out/sounds/test
    ${lib.concatStrings (lib.mapAttrsToList (name: tone: ''
        sox -n -r 8000 -b 16 -c 1 -e signed-integer -t raw $out/sounds/test/${name}.sln synth 0.5 sine ${toString tone} vol 0.5
      '')
      promptTones)}
  '';

  # 2,000 characters, 50 of them in each sentence
  spokenText = lib.concatStrings (lib.replicate 40 (builtins.fromJSON ''"Gr\u00fc\u00df Gott! F\u00fcr den Verkauf, dr\u00fccken Sie 1. \u65e5\u672c\u8a9e\u3067\u3059. "''));

  keys = [
    "0"
    "1"
    "2"
    "3"
    "4"
    "5"
    "6"
    "7"
    "8"
    "9"
    "*"
  ];

  # a hand-written destination
  landing = context: extension: {context = {inherit context extension;};};
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-pbx-groups";

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {trunk = "trunk-5551000";}
              // lib.listToAttrs (map (number: lib.nameValuePair "sip-${number}" "pw-${number}") numbers);
          })
        ];

        pbx = {
          enable = true;
          extensions = lib.genAttrs numbers (number: {password = secret "sip-${number}";});

          ringGroups = {
            everyone = {
              number = "610";
              members = range 201 208 ++ ["221" "222"];
              ringTime = 30;
            };
            # the unregistered and the busy member come first
            hunt = {
              number = "620";
              members = ["222" "221"] ++ range 201 208;
              strategy = "hunt";
              ringTime = 3;
            };
            alone = {
              number = "611";
              members = ["222"];
              ringTime = 30;
              noAnswer = landing "landed" "alone";
            };
            mixed = {
              number = "630";
              members = ["201"];
              external = ["5559001"];
              trunk = "second";
              ringTime = 60;
            };
            # through pbx.outbound's trunk
            cell = {
              number = "631";
              external = ["5559000"];
              ringTime = 60;
            };
          };

          outbound = {
            prefix = "9";
            trunk = "provider";
          };

          ivrs = {
            keys = {
              number = "700";
              prompt.sound = "test/keys";
              options = lib.genAttrs keys (landing "landed-keys") // {"#".hangup = true;};
              noInput = landing "landed-keys" "wrong";
              invalid = landing "landed-keys" "wrong";
            };
            # 2 is a key, and the first digit of the extensions
            dial = {
              number = "701";
              prompt.sound = "test/dial";
              directDial = true;
              options."2" = landing "landed-dial" "2";
            };
            five = {
              number = "702";
              prompt.sound = "test/five";
              attempts = 5;
              timeout = 1;
              noInput = landing "landed" "five";
            };
            top = {
              number = "703";
              prompt.sound = "test/top";
              options = {
                "1".ivr = "sub";
                "9".ivr = "top";
              };
            };
            sub = {
              prompt.sound = "test/sub";
              attempts = 1;
              timeout = 1;
              noInput = landing "landed" "sub";
            };
            spoken = {
              number = "704";
              prompt.text = spokenText;
            };
          };

          paging = {
            # the pager is a member too
            all = {
              number = "650";
              members = range 200 220;
            };
            solo = {
              number = "651";
              members = ["201"];
            };
            talk = {
              number = "652";
              members = range 201 203;
              duplex = true;
              headers = ["X-Page-Zone: talk"];
            };
          };
        };

        services.asterisk = {
          openFirewall = true;
          # the test follows calls through verbose messages in the journal
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
          sounds.packages = [prompts];

          pjsip = {
            transports.udp = {};
            trunks =
              lib.mapAttrs (_: port: {
                # Asterisk resolves SIP host names without /etc/hosts
                host = nodes.phones.networking.primaryIPAddress;
                inherit port;
                username = "5551000";
                password = secret "trunk";
                register = false;
                # the phones send from the carriers' address too
                matchProviderHost = false;
                # Asterisk skips a contact whose last qualify failed, and the
                # carriers start after the pbx first qualifies them
                qualifyFrequency = 5;
              })
              carrierPorts;
            # pickup groups, set on the endpoints as pbx.extensions has none: 209
            # picks up calls to the ring group everyone, 213 and 214 to 211 and 212
            endpoints =
              lib.genAttrs (range 201 208) (_: {settings.named_call_group = "floor";})
              // {
                "209".settings.named_pickup_group = "floor";
                "211".settings.named_call_group = "desk";
                "212".settings.named_call_group = "desk";
                "213".settings.named_pickup_group = "desk";
                "214".settings.named_pickup_group = "desk";
              };
          };

          # where the destinations of the groups and menus lead
          dialplan.contexts = {
            landed.extensions = lib.genAttrs ["alone" "five" "sub"] (name: [
              "Set(DB(test/${name})=landed)"
              "Hangup()"
            ]);
            # notes each key and goes back to the menu
            landed-keys.extensions =
              lib.genAttrs keys (key: [
                "Set(DB(test/keys)=\${DB(test/keys)}${key})"
                "Goto(pbx-ivr-keys,s,1)"
              ])
              // {
                wrong = [
                  "Set(DB(test/keys)=\${DB(test/keys)}!)"
                  "Hangup()"
                ];
              };
            landed-dial.extensions."2" = [
              "Set(DB(test/dial)=2)"
              "Goto(pbx-ivr-dial,s,1)"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        # 24 pjsua instances
        virtualisation.memorySize = 2048;
        # the carriers only receive requests, which the firewall would drop
        networking.firewall.allowedUDPPorts = lib.attrValues carrierPorts;
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        PROMPTS = ${builtins.toJSON promptTones}

        phone = {
            number: Phone(
                phones, number, number, f"pw-{number}", "pbx", sip_port=5060 + i, cli_port=2300 + i,
                auto_answer=486 if number == "221" else 180,
            )
            for i, number in enumerate(str(n) for n in range(200, 222))
        }
        boss = phone["200"]
        busy = phone["221"]
        carrier_a = Phone(phones, "carrier-a", "carrier", "none", "pbx", sip_port=${toString carrierPorts.provider}, cli_port=2398, register=False)
        carrier_b = Phone(phones, "carrier-b", "carrier", "none", "pbx", sip_port=${toString carrierPorts.second}, cli_port=2399, register=False)

        def members(first, last):
            return [phone[str(n)] for n in range(first, last + 1)]

        def db(family, key):
            match = re.search(r"^Value: (.*)$", asterisk(pbx, f"database get {family} {key}"), re.M)
            return match.group(1) if match else None

        def wait_db(family, key, timeout=60):
            pbx.wait_until_succeeds(f"asterisk -rx 'database get {family} {key}' | grep -q '^Value: '", timeout=timeout)
            return db(family, key)

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def answer(p):
            p.cli("call answer 200")

        def called(cursor):
            """Extensions Dial called since `cursor`, in order."""
            return re.findall(r"Called PJSIP/(\d+)/", journal_since(pbx, cursor))

        def wait_confirming(cursor):
            """Wait until an outside member hears the confirmation prompt."""
            wait_journal(pbx, cursor, r"Playing 'followme/no-recording\.")

        def distinct(tones):
            return [t for i, t in enumerate(tones) if i == 0 or tones[i - 1] != t]

        def played(cursor):
            """Sound files the pbx played since `cursor`, in order."""
            return re.findall(r"Playing '([^.']+)\.", journal_since(pbx, cursor))

        with subtest("phones register"):
            start_phones(list(phone.values()) + [carrier_a, carrier_b])
            # 222 never registers; the trunks' contacts count too
            wait_contacts(pbx, 24)
            for trunk in ("provider", "second"):
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +{trunk}/sip:.* Avail'", timeout=60)

        with subtest("a ring group rings all ten members at once, passing over a busy and an unregistered one, and the first to answer gets the call"):
            cursor = journal_cursor(pbx)
            ringing = members(201, 208)
            invites = {p.name: p.requests("INVITE") for p in ringing + [busy]}
            cancels = {p.name: p.requests("CANCEL") for p in ringing}
            boss.call("610")
            for p in ringing + [busy]:
                p.wait_request("INVITE", after=invites[p.name])
            winner = phone["205"]
            answer(winner)
            wait_bridged(pbx, "200", "205")
            for p in ringing:
                if p is not winner:
                    p.wait_request("CANCEL", after=cancels[p.name])
            assert winner.requests("CANCEL") == cancels["205"], "205 was cancelled"
            # 222 has no contact to call
            assert sorted(called(cursor)) == [p.name for p in ringing] + ["221"], called(cursor)
            hear_each_other(boss, winner)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a hunt group rings its ten members one after the other, passing over a busy and an unregistered one"):
            cursor = journal_cursor(pbx)
            invites = {p.name: p.requests("INVITE") for p in members(201, 208)}
            cancels = {p.name: p.requests("CANCEL") for p in members(201, 202)}
            boss.call("620")
            third = phone["203"]
            third.wait_request("INVITE", after=invites["203"], timeout=30)
            answer(third)
            wait_bridged(pbx, "200", "203")
            assert called(cursor) == ["221", "201", "202", "203"], called(cursor)
            for p in members(201, 202):
                assert p.requests("CANCEL") > cancels[p.name], f"{p.name} was not cancelled"
            for p in members(204, 208):
                assert p.requests("INVITE") == invites[p.name], f"{p.name} rang after 203 answered"
            hear_each_other(boss, third)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a ring group whose only member is not registered goes to its no-answer destination at once"):
            asterisk(pbx, "database del test alone")
            start = time.time()
            boss.call("611")
            assert wait_db("test", "alone") == "landed"
            # not after the group's 30 s
            assert time.time() - start < 15, f"took {time.time() - start:.0f} s"
            wait_idle(pbx)

        with subtest("an outside member hands the call back with 2, and the member who answers gets it"):
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = {p.name: p.requests("INVITE") for p in (member, carrier_a, carrier_b)}
            cancels = member.requests("CANCEL")
            ended = carrier_b.disconnects()
            boss.call("630")
            member.wait_request("INVITE", after=invites["201"])
            # through the group's own trunk, not pbx.outbound's
            carrier_b.wait_request("INVITE", after=invites["carrier-b"])
            assert "INVITE sip:5559001@" in carrier_b.received("INVITE")[-1]
            wait_confirming(cursor)
            carrier_b.dtmf("2")
            carrier_b.wait_disconnected(after=ended)
            assert member.requests("CANCEL") == cancels, "201 stopped ringing"
            answer(member)
            wait_bridged(pbx, "200", "201")
            hear_each_other(boss, member)
            assert carrier_a.requests("INVITE") == invites["carrier-a"], "pbx.outbound's trunk was used"
            boss.hangup()
            wait_idle(pbx)

        with subtest("an outside member takes the call by pressing 1, and the member stops ringing"):
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = member.requests("INVITE")
            cancels = member.requests("CANCEL")
            boss.call("630")
            member.wait_request("INVITE", after=invites)
            wait_confirming(cursor)
            carrier_b.dtmf("1")
            wait_bridged(pbx, "200", "5559001@pbx-ringgroup-mixed")
            member.wait_request("CANCEL", after=cancels)
            hear_each_other(boss, carrier_b)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a member who answers ends an outside member's confirmation prompt at once"):
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = member.requests("INVITE")
            ended = carrier_b.disconnects()
            boss.call("630")
            member.wait_request("INVITE", after=invites)
            wait_confirming(cursor)
            answer(member)
            wait_bridged(pbx, "200", "201")
            taken = time.time()
            carrier_b.wait_disconnected(after=ended)
            # one round of the prompt lasts 5 s
            assert time.time() - taken < 5, f"the outside member heard the prompt for {time.time() - taken:.0f} s after 201 answered"
            hear_each_other(boss, member)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a caller who hangs up ends an outside member's confirmation prompt at once"):
            cursor = journal_cursor(pbx)
            invites = {p.name: p.requests("INVITE") for p in (carrier_a, carrier_b)}
            ended = carrier_a.disconnects()
            boss.call("631")
            # through pbx.outbound's trunk
            carrier_a.wait_request("INVITE", after=invites["carrier-a"])
            assert "INVITE sip:5559000@" in carrier_a.received("INVITE")[-1]
            assert carrier_b.requests("INVITE") == invites["carrier-b"], "the other trunk was used"
            wait_confirming(cursor)
            boss.hangup()
            gone = time.time()
            carrier_a.wait_disconnected(after=ended)
            assert time.time() - gone < 5, f"the outside member heard the prompt for {time.time() - gone:.0f} s after the caller hung up"
            wait_idle(pbx)

        with subtest("a voice menu sends each of its twelve keys where it is set to"):
            asterisk(pbx, "database del test keys")
            cursor = journal_cursor(pbx)
            mark = recorded(boss)
            ended = boss.disconnects()
            boss.call("700")
            wait_journal(pbx, cursor, "Playing 'test/keys\\.")
            # each key goes to landed-keys, which notes it and plays the menu
            # again, and # hangs up
            boss.dtmf("0123456789*#")
            boss.wait_disconnected(after=ended)
            assert db("test", "keys") == "0123456789*", db("test", "keys")
            assert played(cursor).count("test/keys") == 12, played(cursor)
            assert distinct(bursts(boss, mark, PROMPTS.values())) == [PROMPTS["keys"]], heard(boss, mark)
            wait_idle(pbx)

        with subtest("a key that starts an extension number waits for the next digit"):
            asterisk(pbx, "database del test dial")
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = member.requests("INVITE")
            boss.call("701")
            wait_journal(pbx, cursor, "Playing 'test/dial\\.")
            pressed = time.time()
            boss.dtmf("2")
            assert wait_db("test", "dial") == "2"
            # Asterisk's digit timeout, 5 s
            assert time.time() - pressed > 4, f"2 counted after {time.time() - pressed:.1f} s"
            wait_journal(pbx, cursor, "Playing 'test/dial\\.", count=2)
            boss.dtmf("201")
            member.wait_request("INVITE", after=invites)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a voice menu plays its prompt as often as attempts says"):
            asterisk(pbx, "database del test five")
            cursor = journal_cursor(pbx)
            mark = recorded(boss)
            boss.call("702")
            assert wait_db("test", "five") == "landed"
            assert played(cursor) == ["test/five"] * 5, played(cursor)
            assert bursts(boss, mark, PROMPTS.values()) == [PROMPTS["five"]] * 5, heard(boss, mark)
            wait_idle(pbx)

        with subtest("a key opens a nested menu, or the menu itself"):
            asterisk(pbx, "database del test sub")
            cursor = journal_cursor(pbx)
            mark = recorded(boss)
            boss.call("703")
            wait_journal(pbx, cursor, "Playing 'test/top\\.")
            boss.dtmf("9")
            wait_journal(pbx, cursor, "Playing 'test/top\\.", count=2)
            boss.dtmf("1")
            # sub plays once, then takes its no-input destination
            assert wait_db("test", "sub") == "landed"
            assert played(cursor) == ["test/top", "test/top", "test/sub"], played(cursor)
            assert distinct(bursts(boss, mark, PROMPTS.values())) == [PROMPTS["top"], PROMPTS["sub"]], heard(boss, mark)
            wait_idle(pbx)

        with subtest("a spoken prompt of 2,000 characters, some not ASCII, plays"):
            datadir = pbx.succeed("sed -n 's/^astdatadir *=> *//p' /etc/asterisk/asterisk.conf").strip()
            size = int(pbx.succeed(f"stat -L -c %s {datadir}/sounds/pbx/ivr-spoken.wav16"))
            # 16 bit samples at 16 kHz after the header; flite speaks the text in about 2.5 minutes
            assert (size - 44) / 32000 > 120, f"{(size - 44) / 32000:.0f} s"
            cursor = journal_cursor(pbx)
            boss.call("704")
            wait_journal(pbx, cursor, "Playing 'pbx/ivr-spoken\\.")
            mark = recorded(boss)
            wait_recorded(boss, mark, 3)
            windows = heard(boss, mark)
            # speech, with pauses between the words
            assert sum(1 for w in windows if w) > len(windows) / 2, windows
            boss.hangup()
            wait_idle(pbx)

        with subtest("a page with one member: the member hears the pager, who hears nobody"):
            member = phone["201"]
            invites = member.requests("INVITE")
            boss.call("651")
            member.wait_request("INVITE", after=invites)
            answer(member)
            wait_hears(member, [boss.tone])
            mark = recorded(boss)
            wait_hears(boss, [])
            assert not hears_any(heard(boss, mark), [member.tone]), heard(boss, mark)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a page to twenty members, the pager among them: those who answer hear the pager, who hears nobody, and the one who does not rings until the page ends"):
            paged = members(201, 220)
            invites = {p.name: p.requests("INVITE") for p in paged + [boss]}
            boss.call("650")
            for p in paged:
                p.wait_request("INVITE", after=invites[p.name])
            ignoring = phone["220"]
            answering = [p for p in paged if p is not ignoring]
            cli_parallel([(p, "call answer 200") for p in answering])
            for p in answering:
                wait_hears(p, [boss.tone])
            mark = recorded(boss)
            wait_hears(boss, [])
            assert not hears_any(heard(boss, mark), [p.tone for p in answering]), heard(boss, mark)
            assert boss.requests("INVITE") == invites["200"], "the pager was paged"
            cancels = ignoring.requests("CANCEL")
            boss.hangup()
            ignoring.wait_request("CANCEL", after=cancels)
            wait_idle(pbx)

        with subtest("a duplex page: the pager and the members hear each other, and the phones get the page's own headers"):
            paged = members(201, 203)
            invites = {p.name: p.requests("INVITE") for p in paged}
            boss.call("652")
            for p in paged:
                p.wait_request("INVITE", after=invites[p.name])
                invite = p.received("INVITE")[-1]
                assert "X-Page-Zone: talk" in invite, invite
                assert "answer-after" not in invite, invite
            cli_parallel([(p, "call answer 200") for p in paged])
            wait_hears(boss, [p.tone for p in paged])
            for p in paged:
                wait_hears(p, [boss.tone] + [q.tone for q in paged if q is not p])
            boss.hangup()
            wait_idle(pbx)

        with subtest("a phone outside a ring group takes its call with *8, and every member stops ringing"):
            ringing = members(201, 208)
            invites = {p.name: p.requests("INVITE") for p in ringing}
            cancels = {p.name: p.requests("CANCEL") for p in ringing}
            boss.call("610")
            for p in ringing:
                p.wait_request("INVITE", after=invites[p.name])
            picker = phone["209"]
            picker.call("*8")
            wait_bridged(pbx, "200", "209")
            for p in ringing:
                p.wait_request("CANCEL", after=cancels[p.name])
            hear_each_other(boss, picker)
            boss.hangup()
            wait_idle(pbx)

        with subtest("two calls ring at once in one pickup group: *8 takes the one that rang first, then the other"):
            callee = {p.name: p for p in members(211, 212)}
            invites = {name: p.requests("INVITE") for name, p in callee.items()}
            second = phone["215"]
            boss.call("211")
            callee["211"].wait_request("INVITE", after=invites["211"])
            second.call("212")
            callee["212"].wait_request("INVITE", after=invites["212"])
            phone["213"].call("*8")
            wait_bridged(pbx, "200", "213")
            phone["214"].call("*8")
            wait_bridged(pbx, "215", "214")
            hear_each_other(boss, phone["213"])
            hear_each_other(second, phone["214"])
            cli_parallel([(boss, "call hangup_all"), (second, "call hangup_all")])
            wait_idle(pbx)
      '';
  }
