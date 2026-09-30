# The pbx layer on a running system: opening hours in their time zone with
# holidays and the close-early toggle, whose busy lamp follows it within 2 s
# and which, lamp included, holds across a restart, inbound calls routed by
# them, a hunt group ringing one phone after the other, an external ring
# group member who has to press 1 before the call is theirs, emergency calls
# that notify two extensions without waiting for them, the busy and no-answer
# destinations of an extension, a voice menu driven by DTMF, and pages, which
# leave out the caller and members in a call. Wherever an extension is
# called, all of its devices ring, and its busy lamp shows it ringing and free
# again within 2 s. A second Asterisk plays the SIP provider and the mobile
# phone of the external member.
#
#   pbx       10.2.0.10, clock set by the test
#   provider  10.2.0.5
#   phones    10.2.0.21, runs 201, 202 on a desk phone and a mobile (all ring
#             without answering), 203, and 204 on two phones (both busy)
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
            {
              "201".ringTime = 5;
              "202".ringTime = 5;
            }
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

          paging = {
            all = {
              number = "650";
              members = [
                "201"
                "202"
              ];
            };
            # paged by 203, which is listed first, so a page to it would go
            # out before the others
            team = {
              number = "660";
              members = [
                "203"
                "202"
              ];
              skipBusy = false;
            };
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
            # extensions with two devices
            endpoints = {
              "202".aor.maxContacts = 2;
              "204".aor.maxContacts = 2;
            };
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
        # the second devices of 202 and 204
        sales_mobile = Phone(phones, "202-mobile", "202", "pw-202", "10.2.0.10", sip_port=5064, cli_port=2304, auto_answer=180)
        dock = Phone(phones, "204-dock", "204", "pw-204", "10.2.0.10", sip_port=5065, cli_port=2305, auto_answer=486)

        def calls_of(endpoint):
            return [c for c in channels(pbx) if endpoint_of(c["name"]) == endpoint]

        def lamp(number, note):
            """Capture times of the NOTIFYs that showed `note` on reception's
            busy lamp for `number`."""
            return sip_times(pbx, r"\ANOTIFY sip:201@", f'entity="sip:{re.escape(number)}@', f"<note>{note}</note>")

        def answered(phone):
            """Capture time of the answer to the last call `phone` placed."""
            return sip_times(pbx, r"\ASIP/2\.0 200 ", r"^CSeq: \d+ INVITE", rf"^From: .*sip:{phone.user}@")[-1]

        with subtest("the trunk and the phones register"):
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q 'Registered'", timeout=180)
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q 'provider/sip:10.2.0.5.* Avail'", timeout=180)
            start_phones([reception, sales, boss, warehouse, sales_mobile, dock])
            for phone in (reception, sales, boss, warehouse, sales_mobile, dock):
                phone.wait_registered()
            reception.watch("*28")
            # an extension with two devices
            reception.watch("202")

        with subtest("closing early from a phone sends inbound calls to the closed destination"):
            boss.call("*28")
            boss.wait_disconnected()
            pbx.succeed("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'")
            reception.wait_count("<note>On the phone</note>", 1)
            # the toggle sets the state right after it answers
            within(2, answered(boss), lamp("*28", "On the phone"))
            assert hours() == "closed"
            before = {p.name: p.requests("INVITE") for p in (reception, sales)}
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            pbx.wait_until_succeeds("test -f /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0000.txt", timeout=120)
            assert {p.name: p.requests("INVITE") for p in (reception, sales)} == before, "the ring group rang while closed"
            wait_idle(pbx)

        with subtest("closed early stays closed across a restart, and its lamp lit"):
            shown = lamp("*28", "On the phone")
            pbx.succeed("systemctl restart asterisk.service")
            pbx.wait_for_unit("asterisk.service")
            pbx.wait_until_succeeds("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'", timeout=60)
            assert hours() == "closed"
            # Asterisk restores reception's subscription from astdb and tells it again
            retry(lambda _: len(lamp("*28", "On the phone")) > len(shown), timeout_seconds=60)
            out = [moment for moment in lamp("*28", "Ready") if moment > shown[-1]]
            assert not out, f"the lamp of *28 went out at {out}"
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q 'Registered'", timeout=180)

        with subtest("reopening sends them to the ring group"):
            disconnects = boss.disconnects()
            lit = len(lamp("*28", "Ready"))
            boss.call("*28")
            boss.wait_disconnected(after=disconnects)
            pbx.succeed("asterisk -rx 'core show hint *28' | grep -q 'State:Idle'")
            retry(lambda _: len(lamp("*28", "Ready")) > lit, timeout_seconds=30)
            within(2, answered(boss), lamp("*28", "Ready"))
            assert hours() == "open"
            before = {p.name: p.requests("INVITE") for p in (reception, sales, sales_mobile, boss)}
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            for phone in (reception, sales, sales_mobile):
                phone.wait_request("INVITE", after=before[phone.name], timeout=60)
            assert boss.requests("INVITE") == before["203"], "203 is not in the ring group"
            wait_idle(pbx, timeout=60)
            pbx.fail("test -f /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0001.txt")

        with subtest("a hunt group rings its members one after the other"):
            invites = {p.name: p.requests("INVITE") for p in (reception, sales, sales_mobile)}
            cancels = {p.name: p.requests("CANCEL") for p in (sales, sales_mobile)}
            boss.call("620")
            for device in (sales, sales_mobile):
                device.wait_request("INVITE", after=invites[device.name])
            # `call new` itself takes a while, well inside the 10 s
            time.sleep(2)
            assert reception.requests("INVITE") == invites["201"], "201 rang together with 202"
            reception.wait_request("INVITE", after=invites["201"], timeout=30)
            for device in (sales, sales_mobile):
                assert device.requests("CANCEL") > cancels[device.name], f"{device.name} still rang when 201 started"
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

        with subtest("an emergency call goes out at once and notifies two extensions"):
            invites = {p.name: p.requests("INVITE") for p in (reception, sales, sales_mobile)}
            boss.call("911")
            provider.wait_until_succeeds("asterisk -rx 'database get calls last' | grep -q 'Value: 5551000:911$'", timeout=60)
            for phone in (reception, sales, sales_mobile):
                phone.wait_request("INVITE", after=invites[phone.name], timeout=30)
                invite = phone.received("INVITE")[-1]
                assert '"Boss" <sip:203@' in invite, invite
            # the notified phones ring without answering
            ringing = {endpoint_of(c["name"]) for c in channels(pbx)}
            assert {"201", "202", "provider"} <= ringing, ringing
            # declined, so the test does not wait out their 30 s of ringing
            for phone in (reception, sales, sales_mobile):
                phone.hangup()
            boss.hangup()
            wait_idle(pbx, timeout=60)

        with subtest("an extension's busy and no-answer destinations"):
            # busy: both devices of 204 are
            invites = {p.name: p.requests("INVITE") for p in (warehouse, dock)}
            boss.call("204")
            channel = wait_channel(pbx, "203", app="VoiceMail")
            assert channel["data"] == "204@default,b", channel
            for device in (warehouse, dock):
                assert device.requests("INVITE") > invites[device.name], f"{device.name} was not called"
            boss.hangup()
            wait_idle(pbx)
            boss.call("201")
            channel = wait_channel(pbx, "203", app="VoiceMail", timeout=30)
            assert channel["data"] == "201@default,u", channel
            boss.hangup()
            wait_idle(pbx)

        with subtest("a call to an extension rings all of its devices, then its no-answer destination, and its busy lamp follows"):
            devices = (sales, sales_mobile)
            invites = {p.name: p.requests("INVITE") for p in devices}
            rang, freed = len(lamp("202", "Ringing")), len(lamp("202", "Ready"))
            # a device's ringing comes first, then the pbx's to 203
            ringing = (r"\ASIP/2\.0 180 ", r"^To: .*sip:202@")
            rings = len(sip_times(pbx, *ringing))
            boss.call("202")
            for device in devices:
                device.wait_request("INVITE", after=invites[device.name], timeout=30)
            retry(lambda _: len(lamp("202", "Ringing")) > rang, timeout_seconds=30)
            within(2, sip_times(pbx, *ringing)[rings], lamp("202", "Ringing"))
            channel = wait_channel(pbx, "203", app="VoiceMail", timeout=30)
            assert channel["data"] == "202@default,u", channel
            # the lamp goes out once both devices stopped ringing
            retry(lambda _: len(lamp("202", "Ready")) > freed, timeout_seconds=30)
            within(2, sip_times(pbx, r"\ACANCEL sip:202@")[-1], lamp("202", "Ready"))
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
            invites = {p.name: p.requests("INVITE") for p in (reception, sales, sales_mobile)}
            boss.call("650")
            # the members ring without answering, so they have to ring together
            for phone in (reception, sales, sales_mobile):
                phone.wait_request("INVITE", after=invites[phone.name], timeout=30)
                invite = phone.received("INVITE")[-1]
                assert "Call-Info: <sip:pbx>;answer-after=0" in invite, invite
                assert "Alert-Info: <http://example.com>;info=alert-autoanswer;delay=0" in invite, invite
            boss.hangup()
            wait_idle(pbx)

        with subtest("a page leaves out members in a call, and the caller's own extension"):
            reception.call("203")
            wait_bridged(pbx, "201", "203")
            invites = {p.name: p.requests("INVITE") for p in (sales, sales_mobile)}
            warehouse.call("650")
            for device in (sales, sales_mobile):
                device.wait_request("INVITE", after=invites[device.name], timeout=30)
            # 201 comes first in the group, so a page to it would already be out
            assert len(calls_of("201")) == 1, calls_of("201")
            warehouse.hangup()
            reception.hangup()
            wait_idle(pbx)
            invites = {p.name: p.requests("INVITE") for p in (sales, sales_mobile)}
            boss.call("660")
            for device in (sales, sales_mobile):
                device.wait_request("INVITE", after=invites[device.name], timeout=30)
            assert len(calls_of("203")) == 1, calls_of("203")
            boss.hangup()
            wait_idle(pbx)
      '';
  }
