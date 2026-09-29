# The pbx layer on a running system: opening hours in their time zone with
# holidays and the close-early toggle, inbound calls routed by them, a hunt
# group ringing one phone after the other, an external ring group member who
# has to press 1 before the call is theirs, emergency calls that notify two
# phones without waiting for them, the busy and no-answer destinations of an
# extension, a voice menu driven by DTMF, and a page to two phones. A second Asterisk plays the SIP provider and the mobile
# phone of the external member.
#
#   pbx       10.2.0.10, clock set by the test
#   provider  10.2.0.5
#   phones    10.2.0.21, runs 201 and 202 (ring without answering), 203 and
#             204 (busy)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = {
    "201" = "Reception";
    "202" = "Sales";
    "203" = "Boss";
    "204" = "Warehouse";
  };

  onlyAddress = address: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-pbx";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {
                sip-trunk = "trunk-password";
                vm-200 = "4200";
              }
              // lib.concatMapAttrs (extension: _: {
                "sip-${extension}" = "pw-${extension}";
                "vm-${extension}" = "4${extension}";
              })
              extensions;
          })
          (onlyAddress "10.2.0.10")
        ];
        # the test sets the clock
        services.timesyncd.enable = false;

        pbx = {
          enable = true;
          extensions = lib.mkMerge [
            (lib.mapAttrs (extension: name: {
                inherit name;
                password = secret "sip-${extension}";
                voicemail.pin = secret "vm-${extension}";
              })
              extensions)
            {"201".ringTime = 5;}
          ];

          ringGroups = {
            front = {
              number = "610";
              members = [
                "201"
                "202"
              ];
              ringTime = 10;
            };
            hunt = {
              number = "620";
              members = [
                "202"
                "201"
              ];
              strategy = "hunt";
              ringTime = 10;
              noAnswer.context.context = "hunt-done";
            };
            # longer than three rounds of the confirmation prompt
            cell = {
              number = "630";
              external = ["5559000"];
              ringTime = 60;
              noAnswer.context.context = "cell-done";
            };
          };

          hours.office = {
            timezone = "America/Los_Angeles";
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
            holidays = ["dec 25"];
            closeEarly = "*28";
          };

          inbound."5551000" = {
            trunk = "provider";
            hours = "office";
            open.ringGroup = "front";
            closed.voicemail = "200";
          };

          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };

          ivrs.menu = {
            number = "700";
            prompt.text = "Press 1 for the test.";
            options."1".context.context = "ivr-one";
            attempts = 2;
            noInput.context.context = "ivr-noinput";
            invalid.context.context = "ivr-invalid";
          };

          paging.all = {
            number = "650";
            members = [
              "201"
              "202"
            ];
          };

          emergency = {
            numbers = ["911"];
            trunk = "provider";
            callerId = "5551000";
            notify = [
              "201"
              "202"
            ];
          };
        };

        services.asterisk = {
          openFirewall = true;
          # the test follows the voice menu through verbose messages in the journal
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
          pjsip = {
            transports.udp = {};
            trunks.provider = {
              host = "10.2.0.5";
              username = "5551000";
              password = secret "sip-trunk";
              allow = [
                "alaw"
                "ulaw"
              ];
              registration.contactUser = "5551000";
            };
          };
          voicemail.mailboxes."200" = {
            fullName = "Front desk";
            pin = secret "vm-200";
          };
          # what the test reads back from astdb
          dialplan.contexts = {
            hourstest.extensions.s = [
              "Gosub(pbx-hours-office,s,1)"
              "Set(DB(hourstest/result)=\${GOSUB_RETVAL})"
            ];
            hunt-done.extensions.s = [
              "Set(DB(test/hunt)=done)"
              "Hangup()"
            ];
            cell-done.extensions.s = [
              "Set(DB(test/cell)=noanswer)"
              "Hangup()"
            ];
            ivr-one.extensions.s = [
              "Set(DB(test/ivr)=one)"
              "Hangup()"
            ];
            ivr-noinput.extensions.s = [
              "Set(DB(test/ivr)=noinput)"
              "Hangup()"
            ];
            ivr-invalid.extensions.s = [
              "Set(DB(test/ivr)=invalid)"
              "Hangup()"
            ];
          };
        };
      };

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {fixed.customer = "trunk-password";})
          (onlyAddress "10.2.0.5")
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            # the office's account; the endpoint name is its user name
            endpoints."5551000" = {
              context = "carrier";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/customer";
              allow = [
                "alaw"
                "ulaw"
              ];
            };
          };
          dialplan.contexts = {
            carrier.extensions = {
              # calls from the office: remember who called which number
              "_X." = [
                "Set(DB(calls/last)=\${CALLERID(num)}:\${EXTEN})"
                "Answer()"
                "Playback(tt-monkeys)"
                "Wait(30)"
                "Hangup()"
              ];
              # a mobile phone, which presses 1 when cell/press is set, as a
              # person would, and otherwise stays silent, as its voicemail
              # would
              "5559000" = [
                "Set(DB(calls/cell)=\${CALLERID(num)})"
                "Answer()"
                "Wait(2)"
                "ExecIf($[\"\${DB(cell/press)}\" = \"1\"]?SendDTMF(1))"
                "Wait(60)"
                "Hangup()"
              ];
            };
            # audio for calls placed to the office
            feed.extensions.s = [
              "Playback(tt-monkeys)"
              "Wait(2)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddress "10.2.0.21")
        ];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        provider.wait_for_unit("asterisk.service")

        def db(machine, family, key):
            output = asterisk(machine, f"database get {family} {key}")
            match = re.search(r"^Value: (.*)$", output, re.M)
            return match.group(1) if match else None

        def hours():
            """What pbx-hours-office returns now."""
            asterisk(pbx, "database del hourstest result")
            asterisk(pbx, "channel originate Local/s@hourstest application Wait 5")
            pbx.wait_until_succeeds("asterisk -rx 'database get hourstest result' | grep -q '^Value: '", timeout=30)
            return db(pbx, "hourstest", "result")

        # the clock only moves forward, and before the phones register:
        # registrations expire by the wall clock
        with subtest("opening hours count in their time zone, with holidays"):
            for utc, expected, what in [
                ("2026-12-02 18:00", "open", "Wednesday 10:00 in Los Angeles, closed in UTC"),
                ("2026-12-03 01:30", "closed", "Wednesday 17:30"),
                ("2026-12-03 16:30", "closed", "Thursday 08:30, open in UTC"),
                ("2026-12-03 17:05", "open", "Thursday 09:05"),
                ("2026-12-05 18:00", "closed", "Saturday 10:00"),
                ("2026-12-25 18:00", "closed", "Friday 10:00, a holiday"),
                ("2026-12-28 18:00", "open", "Monday 10:00"),
            ]:
                pbx.succeed(f"date -u -s '{utc}'")
                result = hours()
                assert result == expected, f"{utc} UTC ({what}): {result}, expected {expected}"

        reception = Phone(phones, "201", "201", "pw-201", "10.2.0.10", sip_port=5060, cli_port=2300, auto_answer=180)
        sales = Phone(phones, "202", "202", "pw-202", "10.2.0.10", sip_port=5061, cli_port=2301, auto_answer=180)
        boss = Phone(phones, "203", "203", "pw-203", "10.2.0.10", sip_port=5062, cli_port=2302)
        warehouse = Phone(phones, "204", "204", "pw-204", "10.2.0.10", sip_port=5063, cli_port=2303, auto_answer=486)

        with subtest("the trunk and the phones register"):
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q 'Registered'", timeout=180)
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q 'provider/sip:10.2.0.5.* Avail'", timeout=180)
            start_phones([reception, sales, boss, warehouse])
            for phone in (reception, sales, boss, warehouse):
                phone.wait_registered()
            reception.watch("*28")

        with subtest("closing early from a phone sends inbound calls to the closed destination"):
            boss.call("*28")
            boss.wait_disconnected()
            pbx.succeed("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'")
            reception.wait_count("<note>On the phone</note>", 1)
            assert hours() == "closed"
            before = {p.name: p.requests("INVITE") for p in (reception, sales)}
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            pbx.wait_until_succeeds("test -f /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0000.txt", timeout=120)
            assert {p.name: p.requests("INVITE") for p in (reception, sales)} == before, "the ring group rang while closed"
            wait_idle(pbx)

        with subtest("reopening sends them to the ring group"):
            disconnects = boss.disconnects()
            boss.call("*28")
            boss.wait_disconnected(after=disconnects)
            pbx.succeed("asterisk -rx 'core show hint *28' | grep -q 'State:Idle'")
            assert hours() == "open"
            before = {p.name: p.requests("INVITE") for p in (reception, sales, boss)}
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            for phone in (reception, sales):
                phone.wait_request("INVITE", after=before[phone.name], timeout=60)
            assert boss.requests("INVITE") == before["203"], "203 is not in the ring group"
            wait_idle(pbx, timeout=60)
            pbx.fail("test -f /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0001.txt")

        with subtest("a hunt group rings its members one after the other"):
            invites = {p.name: p.requests("INVITE") for p in (reception, sales)}
            cancels = sales.requests("CANCEL")
            boss.call("620")
            sales.wait_request("INVITE", after=invites["202"])
            # `call new` itself takes a while, well inside the 10 s
            time.sleep(2)
            assert reception.requests("INVITE") == invites["201"], "201 rang together with 202"
            reception.wait_request("INVITE", after=invites["201"], timeout=30)
            assert sales.requests("CANCEL") > cancels, "202 still rang when 201 started"
            pbx.wait_until_succeeds("asterisk -rx 'database get test hunt' | grep -q 'Value: done'", timeout=30)
            boss.hangup()
            wait_idle(pbx)

        with subtest("an external member takes the call after pressing 1"):
            provider.succeed("asterisk -rx 'database put cell press 1'")
            boss.call("630")
            wait_bridged(pbx, "203", "5559000@pbx-ringgroup-cell", timeout=60)
            assert db(provider, "calls", "cell") == "5551000", "the mobile does not see the office number"
            boss.hangup()
            wait_idle(pbx)

        with subtest("an external member's voicemail cannot take the call"):
            provider.succeed("asterisk -rx 'database del cell press'")
            confirmed = boss.count("state changed to CONFIRMED")
            start = time.time()
            boss.call("630")
            pbx.wait_until_succeeds("asterisk -rx 'database get test cell' | grep -q 'Value: noanswer'", timeout=90)
            # three unanswered prompts end it, not the ring time of 60 s
            assert time.time() - start < 55, f"took {time.time() - start:.0f} s"
            assert boss.count("state changed to CONFIRMED") == confirmed, "the call was answered"
            wait_idle(pbx)

        with subtest("an emergency call goes out at once and notifies two phones"):
            invites = {p.name: p.requests("INVITE") for p in (reception, sales)}
            boss.call("911")
            provider.wait_until_succeeds("asterisk -rx 'database get calls last' | grep -q 'Value: 5551000:911$'", timeout=60)
            for phone in (reception, sales):
                phone.wait_request("INVITE", after=invites[phone.name], timeout=30)
                invite = phone.received("INVITE")[-1]
                assert '"Boss" <sip:203@' in invite, invite
            # the notified phones ring 30 s without answering
            ringing = {endpoint_of(c["name"]) for c in channels(pbx)}
            assert {"201", "202", "provider"} <= ringing, ringing
            boss.hangup()
            wait_idle(pbx, timeout=60)

        with subtest("an extension's busy and no-answer destinations"):
            boss.call("204")
            channel = wait_channel(pbx, "203", app="VoiceMail")
            assert channel["data"] == "204@default,b", channel
            boss.hangup()
            wait_idle(pbx)
            boss.call("201")
            channel = wait_channel(pbx, "203", app="VoiceMail", timeout=30)
            assert channel["data"] == "201@default,u", channel
            boss.hangup()
            wait_idle(pbx)

        def menu(digits):
            """Calls the voice menu from 203, sends `digits` one per prompt,
            and returns where the call ended up."""
            asterisk(pbx, "database del test ivr")
            cursor = journal_cursor(pbx)
            boss.call("700")
            for count, digit in enumerate(digits, 1):
                wait_journal(pbx, cursor, "Playing 'pbx/ivr-menu\\.", count=count)
                boss.dtmf(digit)
            pbx.wait_until_succeeds("asterisk -rx 'database get test ivr' | grep -q '^Value: '", timeout=60)
            result = db(pbx, "test", "ivr")
            prompts = len(re.findall("Playing 'pbx/ivr-menu\\.", journal_since(pbx, cursor)))
            boss.hangup()
            wait_idle(pbx)
            return result, prompts

        with subtest("a voice menu sends a key to its destination"):
            assert menu("1") == ("one", 1)

        with subtest("a voice menu replays its prompt, then takes the no-input destination"):
            assert menu("") == ("noinput", 2)

        with subtest("a voice menu replays its prompt after an invalid key, then takes the invalid destination"):
            assert menu("55") == ("invalid", 2)

        with subtest("a page rings its members at once and asks them to answer by themselves"):
            invites = {p.name: p.requests("INVITE") for p in (reception, sales)}
            boss.call("650")
            # the members ring without answering, so they have to ring together
            for phone in (reception, sales):
                phone.wait_request("INVITE", after=invites[phone.name], timeout=30)
                invite = phone.received("INVITE")[-1]
                assert "Call-Info: <sip:pbx>;answer-after=0" in invite, invite
                assert "Alert-Info: <http://example.com>;info=alert-autoanswer;delay=0" in invite, invite
            boss.hangup()
            wait_idle(pbx)
      '';
  }
