# The inside of the pbx layer on a running system, checked by who rings, who
# gets the call and what each phone hears. Closing early from a phone closes
# the opening hours, while the toggle's busy lamp follows within 2 s. A call
# to an extension rings every device of it, while its busy lamp shows it
# ringing, then goes to the no-answer destination. Ring groups: members ring
# at once or one after the other, passing over a busy member and one that is
# not registered, and the first to answer gets the call while every other
# leg is cancelled. An outside member, called through the group's own trunk
# with services.asterix.outbound's caller ID, takes the call by pressing 1, hands it back
# to the members with 2, and stops hearing the confirmation prompt as soon as
# a member answers. Paging: members get the auto-answer headers, members in a
# call are left out unless skipBusy is off, and the pager's own extension
# always is.
#
#   pbx     the trunks provider (services.asterix.outbound's) and second lead to carrier-a
#           and carrier-b on the phones' machine
#   phones  200 calls and pages, 201 to 204 ring until the test answers them,
#           205 watches busy lamps, 221 is busy, 222 never registers and 230
#           rings on two devices
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  numbers = map toString (lib.range 200 205 ++ [221 222 230]);
  range = first: last: map toString (lib.range first last);

  # the carriers do not register; the pbx calls them on these ports
  carrierPorts = {
    provider = 5098;
    second = 5099;
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-pbx";

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {
                trunk = "trunk-password";
                vm-230 = "4230";
              }
              // lib.listToAttrs (map (number: lib.nameValuePair "sip-${number}" "pw-${number}") numbers);
          })
        ];

        services.asterix = {
          enable = true;
          extensions = lib.mkMerge [
            (lib.genAttrs numbers (number: {
              password = secret "sip-${number}";
            }))
            {
              "230" = {
                ringTime = 3;
                voicemail.pin = secret "vm-230";
              };
            }
          ];

          ringGroups = {
            everyone = {
              number = "610";
              members = range 201 203 ++ ["221" "222"];
              ringTime = 30;
            };
            # the unregistered and the busy member come first
            hunt = {
              number = "620";
              members = ["222" "221"] ++ range 201 204;
              strategy = "hunt";
              ringTime = 3;
            };
            mixed = {
              number = "630";
              members = ["201"];
              external = ["5559001"];
              trunk = "second";
              ringTime = 60;
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

          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };
          emergency.numbers = ["911"];

          # the pager is a member of each, and comes first, so a page to it
          # would go out before the others
          paging = {
            all = {
              number = "650";
              members = range 200 203;
            };
            team = {
              number = "651";
              members = range 200 202;
              skipBusy = false;
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

          pjsip = {
            transports.udp = {};
            # an extension with two devices
            endpoints."230".aor.maxContacts = 2;
            trunks =
              lib.mapAttrs (_: port: {
                # Asterisk resolves SIP host names without /etc/hosts
                host = nodes.phones.networking.primaryIPAddress;
                inherit port;
                # not the office's number, so the caller ID can only come
                # from services.asterix.outbound
                username = "office";
                password = secret "trunk";
                register = false;
                # the phones send from the carriers' address too
                matchProviderHost = false;
                # Asterisk skips a contact whose last qualify failed, and the
                # carriers start after the pbx first qualifies them
                qualifyFrequency = 5;
              })
              carrierPorts;
          };

          # what the opening hours say now, which the test reads from astdb
          dialplan.contexts.hourstest.extensions.s = [
            "Gosub(pbx-hours-office,s,1)"
            "Set(DB(hourstest/result)=\${GOSUB_RETVAL})"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
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

        phone = {
            number: Phone(
                phones, number, number, f"pw-{number}", "pbx", sip_port=5060 + i, cli_port=2300 + i,
                auto_answer=486 if number == "221" else 180,
            )
            for i, number in enumerate(["200", "201", "202", "203", "204", "205", "221"])
        }
        boss = phone["200"]
        busy = phone["221"]
        watcher = phone["205"]
        # the devices of 230, which ring
        sales = Phone(phones, "230", "230", "pw-230", "pbx", sip_port=5082, cli_port=2322, auto_answer=180)
        sales_mobile = Phone(phones, "230-mobile", "230", "pw-230", "pbx", sip_port=5083, cli_port=2323, auto_answer=180)
        carrier_a = Phone(phones, "carrier-a", "carrier", "none", "pbx", sip_port=${toString carrierPorts.provider}, cli_port=2398, register=False)
        carrier_b = Phone(phones, "carrier-b", "carrier", "none", "pbx", sip_port=${toString carrierPorts.second}, cli_port=2399, register=False)

        def members(first, last):
            return [phone[str(n)] for n in range(first, last + 1)]

        def hours():
            """What pbx-hours-office returns now."""
            asterisk(pbx, "database del hourstest result")
            asterisk(pbx, "channel originate Local/s@hourstest application Wait 5")
            pbx.wait_until_succeeds("asterisk -rx 'database get hourstest result' | grep -q '^Value: '", timeout=30)
            match = re.search(r"^Value: (.*)$", asterisk(pbx, "database get hourstest result"), re.M)
            assert match
            return match.group(1)

        def trunks_reachable():
            for trunk in ("provider", "second"):
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +{trunk}/sip:.* Avail'", timeout=60)

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def answer(p):
            p.cli("call answer 200")

        def calls_of(endpoint):
            return [c for c in channels(pbx) if endpoint_of(c["name"]) == endpoint]

        def lamp(number, note):
            """Capture times of the NOTIFYs that showed `note` on the
            watcher's busy lamp for `number`."""
            return sip_times(pbx, rf"\ANOTIFY sip:{watcher.user}@", f'entity="sip:{re.escape(number)}@', f"<note>{note}</note>")

        def answered(p):
            """Capture time of the answer to the last call `p` placed, its first
            copy, as one sent again comes later."""
            answers = [
                m for m in sip_messages(pbx)
                if all(re.search(pattern, m["text"], re.M) for pattern in (r"\ASIP/2\.0 200 ", r"^CSeq: \d+ INVITE", rf"^From: .*sip:{p.user}@"))
            ]
            call = re.findall(r"^Call-ID: (.*)$", answers[-1]["text"], re.M)
            return next(m["time"] for m in answers if re.findall(r"^Call-ID: (.*)$", m["text"], re.M) == call)

        def called(cursor):
            """Extensions Dial called since `cursor`, in order."""
            return re.findall(r"Called PJSIP/(\d+)/", journal_since(pbx, cursor))

        def wait_confirming(cursor):
            """Wait until an outside member hears the confirmation prompt."""
            wait_journal(pbx, cursor, r"Playing 'followme/no-recording\.")

        with subtest("phones register"):
            start_phones(list(phone.values()) + [sales, sales_mobile, carrier_a, carrier_b])
            # 222 never registers; the trunks' contacts count too
            wait_contacts(pbx, 11)
            trunks_reachable()
            watcher.watch("*28")
            # an extension with two devices
            watcher.watch("230")

        with subtest("closing early from a phone closes the hours, and lights the toggle's busy lamp within 2 s"):
            boss.call("*28")
            boss.wait_disconnected()
            pbx.succeed("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'")
            watcher.wait_count("<note>On the phone</note>", 1)
            # the toggle sets the state right after it answers
            within(2, answered(boss), lamp("*28", "On the phone"))
            assert hours() == "closed"
            wait_idle(pbx)

        with subtest("a call to an extension rings all of its devices while its busy lamp shows it ringing, then the no-answer destination takes it"):
            devices = (sales, sales_mobile)
            invites = {p.name: p.requests("INVITE") for p in devices}
            rang, freed = len(lamp("230", "Ringing")), len(lamp("230", "Ready"))
            # a device's ringing comes first, then the pbx's to 200
            ringing = (r"\ASIP/2\.0 180 ", r"^To: .*sip:230@")
            rings = len(sip_times(pbx, *ringing))

            # the first copy of each CANCEL, as one sent again comes later
            def cancel_to(d):
                return rf"\ACANCEL sip:230@[\d.]+:{d.sip_port}\b"

            cancels = {d.name: len(sip_times(pbx, cancel_to(d))) for d in devices}
            boss.call("230")
            for device in devices:
                device.wait_request("INVITE", after=invites[device.name], timeout=30)
            retry(lambda _: len(lamp("230", "Ringing")) > rang, timeout_seconds=30)
            within(2, sip_times(pbx, *ringing)[rings], lamp("230", "Ringing"))
            channel = wait_channel(pbx, "200", app="VoiceMail", timeout=30)
            assert channel["data"] == "230@default,u", channel
            # the lamp goes out once both devices stopped ringing
            retry(lambda _: len(lamp("230", "Ready")) > freed, timeout_seconds=30)
            within(2, max(sip_times(pbx, cancel_to(d))[cancels[d.name]] for d in devices), lamp("230", "Ready"))
            boss.hangup()
            wait_idle(pbx)

        with subtest("a ring group rings its members at once, passing over a busy and an unregistered one, and the first to answer gets the call"):
            cursor = journal_cursor(pbx)
            ringing = members(201, 203)
            invites = {p.name: p.requests("INVITE") for p in ringing + [busy]}
            cancels = {p.name: p.requests("CANCEL") for p in ringing}
            boss.call("610")
            for p in ringing + [busy]:
                p.wait_request("INVITE", after=invites[p.name])
            winner = phone["202"]
            answer(winner)
            wait_bridged(pbx, "200", "202")
            for p in ringing:
                if p is not winner:
                    p.wait_request("CANCEL", after=cancels[p.name])
            assert winner.requests("CANCEL") == cancels["202"], "202 was cancelled"
            # 222 has no contact to call
            assert sorted(called(cursor)) == [p.name for p in ringing] + ["221"], called(cursor)
            hear_each_other(boss, winner)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a hunt group rings its members one after the other, passing over a busy and an unregistered one"):
            cursor = journal_cursor(pbx)
            invites = {p.name: p.requests("INVITE") for p in members(201, 204)}
            cancels = {p.name: p.requests("CANCEL") for p in members(201, 202)}
            boss.call("620")
            third = phone["203"]
            third.wait_request("INVITE", after=invites["203"], timeout=30)
            answer(third)
            wait_bridged(pbx, "200", "203")
            assert called(cursor) == ["221", "201", "202", "203"], called(cursor)
            for p in members(201, 202):
                assert p.requests("CANCEL") > cancels[p.name], f"{p.name} was not cancelled"
            assert phone["204"].requests("INVITE") == invites["204"], "204 rang after 203 answered"
            hear_each_other(boss, third)
            boss.hangup()
            wait_idle(pbx)

        with subtest("an outside member hands the call back with 2, and the member who answers gets it"):
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = {p.name: p.requests("INVITE") for p in (member, carrier_a, carrier_b)}
            cancels = member.requests("CANCEL")
            ended_calls = carrier_b.disconnects()
            boss.call("630")
            member.wait_request("INVITE", after=invites["201"])
            # through the group's own trunk, not services.asterix.outbound's
            carrier_b.wait_request("INVITE", after=invites["carrier-b"])
            assert "INVITE sip:5559001@" in carrier_b.received("INVITE")[-1]
            wait_confirming(cursor)
            carrier_b.dtmf("2")
            carrier_b.wait_disconnected(after=ended_calls)
            assert member.requests("CANCEL") == cancels, "201 stopped ringing"
            answer(member)
            wait_bridged(pbx, "200", "201")
            hear_each_other(boss, member)
            assert carrier_a.requests("INVITE") == invites["carrier-a"], "services.asterix.outbound's trunk was used"
            boss.hangup()
            wait_idle(pbx)

        with subtest("an outside member gets services.asterix.outbound's caller ID, takes the call by pressing 1, and the member stops ringing"):
            cursor = journal_cursor(pbx)
            member = phone["201"]
            invites = member.requests("INVITE")
            cancels = member.requests("CANCEL")
            boss.call("630")
            member.wait_request("INVITE", after=invites)
            wait_confirming(cursor)
            invite = carrier_b.received("INVITE")[-1]
            assert re.search(r"^P-Asserted-Identity: .*<sip:5551000@", invite, re.M), invite
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
            ended_calls = carrier_b.disconnects()
            boss.call("630")
            member.wait_request("INVITE", after=invites)
            wait_confirming(cursor)
            answer(member)
            wait_bridged(pbx, "200", "201")
            taken = time.time()
            carrier_b.wait_disconnected(after=ended_calls)
            # one round of the prompt lasts 5 s
            assert time.time() - taken < 5, f"the outside member heard the prompt for {time.time() - taken:.0f} s after 201 answered"
            hear_each_other(boss, member)
            boss.hangup()
            wait_idle(pbx)

        with subtest("a page asks its members to answer by themselves, leaves out members in a call unless skipBusy is off, and the pager's own extension always"):
            member, peer = phone["201"], phone["204"]
            invites = peer.requests("INVITE")
            member.call("204")
            peer.wait_request("INVITE", after=invites)
            answer(peer)
            wait_bridged(pbx, "201", "204")
            invites = {p.name: p.requests("INVITE") for p in members(200, 203)}
            boss.call("650")
            for p in members(202, 203):
                p.wait_request("INVITE", after=invites[p.name])
                invite = p.received("INVITE")[-1]
                assert "Call-Info: <sip:pbx>;answer-after=0" in invite, invite
                assert "Alert-Info: <http://example.com>;info=alert-autoanswer;delay=0" in invite, invite
            # 201 comes before 202 and 203 in the page, so a page to it would
            # already be out
            assert member.requests("INVITE") == invites["201"], "201 was paged in a call"
            assert boss.requests("INVITE") == invites["200"], "the pager was paged"
            boss.hangup()
            # only the call of 201 and 204 is left
            retry(lambda _: len(channels(pbx)) == 2, timeout_seconds=30)
            invites = {p.name: p.requests("INVITE") for p in members(200, 202)}
            boss.call("651")
            for p in members(201, 202):
                p.wait_request("INVITE", after=invites[p.name])
            assert len(calls_of("200")) == 1, calls_of("200")
            boss.hangup()
            member.cli("call hangup_all")
            wait_idle(pbx)
      '';
  }
