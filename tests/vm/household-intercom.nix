# examples/household-intercom.nix, used unmodified: Asterisk starts without
# an error or a warning, waits for a phone network's address it binds, and
# does not start without a secret; the host does not route between the
# VLANs; SIP and RTP are only open on the phone networks; phones register from
# their own network only, a wrong password and the intruder (firewall, SIP
# ACL) are refused; calls in every direction ring with the caller's name, are
# heard both ways through the pbx's address on each network and end from
# either side; a number that does not exist gets 404, 911 plays its recording
# twice and hangs up; three phones in the conference room hear each other and
# two go on when one leaves; a dialplan change is applied by a reload that
# keeps the call, the registrations and the process.
#
#   pbx          servers (VLAN 3) 10.0.1.10, lan (VLAN 1) 10.0.10.10, voip (VLAN 2) 10.0.20.10
#   softphones   lan  10.0.10.21  runs extensions 201 and 202
#   adapters     voip 10.0.20.21  runs extensions 101 and 102 (the HT801s' SIP side)
#   intruder     servers 10.0.1.66
#
# The pbx is also on the servers VLAN (the host's main network in the
# example), so the intruder can actually reach the host and the firewall and
# the SIP ACL are both exercised.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  passwords = {
    "101" = "ata-101-pw";
    "102" = "ata-102-pw";
    "201" = "soft-201-pw";
    "202" = "soft-202-pw";
  };

  # the names the example gives the phones
  names = {
    "101" = "Kitchen";
    "102" = "Living room";
    "201" = "Phone A";
    "202" = "Phone B";
  };

  address = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-household-intercom";

    nodes = {
      pbx = {
        imports = [
          self.nixosModules.default
          ../../examples/household-intercom.nix
          ./common.nix
          (sopsSecrets (pkgs.lib.mapAttrs' (ext: pw: pkgs.lib.nameValuePair "sip-${ext}" pw) passwords))
          (address "servers" "10.0.1.10")
          (address "lan" "10.0.10.10")
          (address "voip" "10.0.20.10")
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          voip.vlan = 2;
          servers.vlan = 3;
        };
        # SIP messages and what the dialplan does in the journal, for the test
        # and for looking into failures
        services.asterisk = {
          pjsip.global.debug = true;
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
        };
        # a change of the dialplan, as the owner would deploy it
        specialisation.dialplan.configuration = {
          services.asterisk.dialplan.contexts.intercom.extensions."199" = [
            "Answer()"
            "Playback(demo-congrats)"
            "Hangup()"
          ];
        };
      };

      softphones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        virtualisation.vlans = [1];
        networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [
          {
            address = "10.0.10.21";
            prefixLength = 24;
          }
        ];
      };

      adapters = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        virtualisation.vlans = [2];
        networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [
          {
            address = "10.0.20.21";
            prefixLength = 24;
          }
        ];
      };

      intruder = {
        imports = [
          ./common.nix
          ./phone.nix
          ./sipp.nix
        ];
        virtualisation.vlans = [3];
        networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [
          {
            address = "10.0.1.66";
            prefixLength = 24;
          }
        ];
        # the PBX's phone networks are behind its servers-VLAN address
        networking.interfaces.eth1.ipv4.routes = [
          {
            address = "10.0.10.0";
            prefixLength = 24;
            via = "10.0.1.10";
          }
        ];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        passwords = ${builtins.toJSON passwords}
        names = ${builtins.toJSON names}

        start_all()
        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()

        # the phones ring until the test answers
        ata = {
            ext: Phone(adapters, ext, ext, passwords[ext], "10.0.20.10", sip_port=5060 + i, cli_port=2300 + i, auto_answer=180)
            for i, ext in enumerate(["101", "102"])
        }
        soft = {
            ext: Phone(softphones, ext, ext, passwords[ext], "10.0.10.10", sip_port=5060 + i, cli_port=2300 + i, auto_answer=180)
            for i, ext in enumerate(["201", "202"])
        }
        phones = {**ata, **soft}

        def main_pid():
            return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def ended_with(phone):
            """The SIP status the phone's last call ended with."""
            return int(re.findall(r"is DISCONNECTED \[reason=(\d+) ", phone.log_text())[-1])

        def wait_counts_grow(count, minimum=50, timeout=60):
            """pjsip show channelstats lists `count` channels, one per phone in
            a call, whose receive and transmit counts go on growing. Returns
            the channels."""
            deadline = time.time() + timeout
            while len(before := channel_stats(pbx)) != count:
                assert time.time() < deadline, before
                time.sleep(1)
            while True:
                now = channel_stats(pbx)
                if set(now) == set(before) and all(
                    now[c]["rx"] >= before[c]["rx"] + minimum and now[c]["tx"] >= before[c]["tx"] + minimum for c in before
                ):
                    return set(now)
                assert time.time() < deadline, (before, now)
                time.sleep(1)

        def units(output, action):
            """The units switch-to-configuration says it is `action` (reloading,
            restarting, ...)."""
            return [
                unit
                for line in output.splitlines()
                if line.startswith(f"{action} the following units: ")
                for unit in line.split(": ", 1)[1].split(", ")
            ]

        def call_and_answer(pairs):
            """Each caller calls its callee, which rings with the caller's name
            until it answers; then they hear each other."""
            cli_parallel([(phones[caller], f"call new {phones[caller].uri(callee)}") for caller, callee in pairs])
            for caller, callee in pairs:
                wait_channel(pbx, callee, state="Ringing")
                invite = phones[callee].received("INVITE")[-1]
                assert f'From: "{names[caller]}" <sip:{caller}@' in invite, invite
            cli_parallel([(phones[callee], "call answer 200") for _, callee in pairs])
            for caller, callee in pairs:
                wait_bridged(pbx, caller, callee)
                hear_each_other(phones[caller], phones[callee])

        with subtest("Asterisk starts without an error or a warning"):
            journal = pbx.succeed("journalctl --sync && journalctl -u asterisk.service -b")
            assert not re.search("ERROR|WARNING", journal), journal
            assert "Asterisk 22." in asterisk(pbx, "core show version")

        with subtest("the host does not route between the VLANs"):
            forwarding = pbx.succeed("sysctl net.ipv4.conf.all.forwarding net.ipv6.conf.all.forwarding")
            assert forwarding == "net.ipv4.conf.all.forwarding = 0\nnet.ipv6.conf.all.forwarding = 0\n", forwarding
            # a device on the VoIP VLAN that sends traffic for the trusted LAN
            # to the host reaches the host's address there, but no device on it
            pbx.wait_until_succeeds("ping -c 1 -W 2 10.0.10.21")
            adapters.succeed("ip route add 10.0.10.0/24 via 10.0.20.10")
            adapters.succeed("ping -c 1 -W 5 10.0.10.10")
            adapters.fail("ping -c 1 -W 5 10.0.10.21")
            adapters.succeed("ip route del 10.0.10.0/24 via 10.0.20.10")

        with subtest("SIP is only offered on the phone networks, and RTP is only open there"):
            sockets = pbx.succeed("ss -Hlun 'sport = :5060'")
            assert "10.0.10.10:5060" in sockets and "10.0.20.10:5060" in sockets, sockets
            assert "0.0.0.0:5060" not in sockets and "10.0.1.10:5060" not in sockets, sockets
            # RTP takes even ports up to 20000, and RTCP the one above each
            rules = pbx.succeed("iptables -S nixos-fw")
            for interface in ["lan", "voip"]:
                assert f"-A nixos-fw -i {interface} -p udp -m udp --dport 10000:20001 -j nixos-fw-accept" in rules, rules
            assert "-i servers" not in rules, rules

        with subtest("Asterisk waits for a phone network's address it binds, and starts once it is there"):
            cursor = journal_cursor(pbx)
            pbx.succeed("ip address del 10.0.20.10/24 dev voip")
            pbx.succeed("systemctl restart --no-block asterisk.service")
            wait_journal(pbx, cursor, "asterisk-config: waiting for address 10.0.20.10$")
            pbx.succeed("ip address add 10.0.20.10/24 dev voip")
            pbx.wait_for_unit("asterisk.service")
            journal = journal_since(pbx, cursor)
            assert journal.count("asterisk-config: waiting for address") == 1, journal
            pbx.wait_until_succeeds("ss -Hlun 'sport = :5060' | grep -q 10.0.20.10:5060")

        with subtest("Asterisk does not start without a secret sops-nix did not write"):
            pbx.succeed("systemctl stop asterisk.service")
            pbx.succeed("mv /run/secrets/sip-101 /run/sip-101")
            cursor = journal_cursor(pbx)
            pbx.fail("systemctl start asterisk.service")
            status = pbx.execute("systemctl status asterisk.service")[1]
            assert "status=243/CREDENTIALS" in status, status
            # systemd names the file it missed only at debug level
            # (src/core/exec-credential.c), and the renderer never runs
            journal = journal_since(pbx, cursor)
            assert "Failed to set up credentials: No such file or directory" in journal and "render-secrets" not in journal, journal
            pbx.succeed("mv /run/sip-101 /run/secrets/sip-101")
            pbx.succeed("systemctl reset-failed asterisk.service")
            pbx.succeed("systemctl start asterisk.service")

        with subtest("all phones register from their own network"):
            endpoints = asterisk(pbx, "pjsip show endpoints")
            for ext in phones:
                assert re.search(rf"Endpoint: +{ext}/{ext} +Unavailable ", endpoints), endpoints
            start_phones(list(phones.values()))
            wait_registrations({phone: 200 for phone in phones.values()})
            contacts = asterisk(pbx, "pjsip show contacts")
            for ext, network in [("101", "20"), ("102", "20"), ("201", "10"), ("202", "10")]:
                assert re.search(rf"Contact:  {ext}/sip:{ext}@10\.0\.{network}\.21:", contacts), contacts
            endpoints = asterisk(pbx, "pjsip show endpoints")
            for ext in phones:
                assert re.search(rf"Endpoint: +{ext}/{ext} +Not in use ", endpoints), endpoints

        with subtest("a wrong password is rejected"):
            cursor = journal_cursor(pbx)
            wrong = Phone(adapters, "wrong", "102", "not-the-password", "10.0.20.10", sip_port=5070, cli_port=2310)
            wrong.start()
            # pjsua gives up once the server rejects its credentials
            wrong.wait_registration_failed("Credential failed to authenticate")
            wrong.stop()
            wait_journal(pbx, cursor, r"Request 'REGISTER' from '<sip:102@10\.0\.20\.10>' failed for '10\.0\.20\.21:5070' .* - Failed to authenticate")

        with subtest("credentials only work from the phone's own network"):
            # adapter 102's correct password, used from the trusted LAN. Asterisk
            # answers a request that fails the endpoint's contact ACL like one with a
            # wrong password (401), so the reason is only in its log.
            moved = Phone(softphones, "moved", "102", passwords["102"], "10.0.10.10", sip_port=5070, cli_port=2310)
            moved.start()
            moved.wait_registration_failed("Credential failed to authenticate")
            moved.stop()
            journal = pbx.succeed("journalctl --sync && journalctl -u asterisk.service")
            assert re.search(
                r"from '<sip:102@10\.0\.10\.10>' failed for '10\.0\.10\.21:5070' .* - Not match Endpoint Contact ACL", journal
            ), "102 was not rejected by its contact ACL"
            assert "102@10.0.10.21" not in asterisk(pbx, "pjsip show contacts")

        with subtest("the intruder cannot register: firewall"):
            intruder.succeed("ping -c 1 -W 5 10.0.10.10")
            thief = Phone(intruder, "thief", "201", passwords["201"], "10.0.10.10")
            thief.start()
            thief.wait_registration_failed("registration failed, status=408", timeout=180)
            thief.stop()

        with subtest("the intruder cannot register or take Asterisk down: SIP ACL, with the firewall opened"):
            pbx.succeed("iptables -I nixos-fw -i servers -p udp --dport 5060 -j ACCEPT")
            thief = Phone(intruder, "thief2", "201", passwords["201"], "10.0.10.10", sip_port=5072, cli_port=2302)
            thief.start()
            thief.wait_registration_failed("registration failed, status=403", timeout=180)
            thief.stop()
            # nor with a Contact on 201's own network, which its contact ACL permits:
            # the SIP ACL refuses the source before the endpoint is looked at
            cursor = journal_cursor(pbx)
            posing = Phone(intruder, "posing", "201", passwords["201"], "10.0.10.10", sip_port=5073, cli_port=2303)
            posing.start("--contact=sip:201@10.0.10.66:5073")
            wait_registrations({posing: 403})
            posing.stop()
            wait_journal(pbx, cursor, r"SIP ACL: Rejecting '10\.0\.1\.66'")
            # requests no phone sends reach Asterisk's parser, and it keeps running
            pid = main_pid()
            sipp(intruder, "malformed", "10.0.10.10", "-s", "201")
            assert main_pid() == pid, "Asterisk restarted"
            pbx.succeed("iptables -D nixos-fw -i servers -p udp --dport 5060 -j ACCEPT")
            assert "10.0.1.66" not in asterisk(pbx, "pjsip show contacts")

        with subtest("calls in every direction ring with the caller's name, are heard both ways through the pbx, and end from either side"):
            # each round is two calls at once; the second of each pair hangs up
            # in one call and the first in the other
            for pairs, hanging_up in [
                ([("101", "102"), ("201", "202")], ["101", "202"]),
                ([("101", "201"), ("202", "102")], ["201", "202"]),
            ]:
                call_and_answer(pairs)
                wait_counts_grow(4)
                ended = {ext: phones[ext].disconnects() for pair in pairs for ext in pair}
                cli_parallel([(phones[ext], "call hangup_all") for ext in hanging_up])
                for ext, count in ended.items():
                    phones[ext].wait_disconnected(after=count)
                wait_idle(pbx)
            # each phone only ever talks to the PBX's address on its own VLAN
            for ext in ata:
                log = ata[ext].log_text()
                assert "c=IN IP4 10.0.20.10" in log and "c=IN IP4 10.0.10.21" not in log, ext
            for ext in soft:
                log = soft[ext].log_text()
                assert "c=IN IP4 10.0.10.10" in log and "c=IN IP4 10.0.20.21" not in log, ext

        with subtest("a number that does not exist gets 404"):
            ended = soft["201"].disconnects()
            soft["201"].call("999")
            soft["201"].wait_disconnected(after=ended)
            assert ended_with(soft["201"]) == 404, soft["201"].log_text()

        with subtest("911 says twice that it cannot be called, then hangs up"):
            caller = ata["101"]
            cursor = journal_cursor(pbx)
            ended, byes = caller.disconnects(), caller.requests("BYE")
            mark = recorded(caller)
            caller.call("911")
            caller.wait_disconnected(after=ended, timeout=60)
            # the pbx ended the call
            assert caller.requests("BYE") == byes + 1, caller.log_text()
            wait_idle(pbx)
            wait_journal(pbx, cursor, r"<PJSIP/101-[0-9a-f]+> Playing 'custom/no-emergency-calls\.", count=2)
            # 7 s of speech in the two plays
            loud = [level for level in levels(caller, mark) if level > SILENCE]
            assert len(loud) >= 30, levels(caller, mark)

        with subtest("three phones meet in the conference room, each hears the other two, and two go on when one leaves"):
            room = [phones[ext] for ext in ["101", "201", "202"]]
            cli_parallel([(p, f"call new {p.uri('800')}") for p in room])
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^800 +3 '", timeout=90)
            wait_counts_grow(3)
            for p in room:
                wait_hears(p, [other.tone for other in room if other is not p])
            ended = soft["201"].disconnects()
            soft["201"].hangup()
            soft["201"].wait_disconnected(after=ended)
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^800 +2 '", timeout=30)
            hear_each_other(ata["101"], soft["202"])
            cli_parallel([(p, "call hangup_all") for p in [ata["101"], soft["202"]]])
            wait_idle(pbx)

        with subtest("a dialplan change is applied with a reload: the call goes on, every phone stays registered, and 199 plays the demo"):
            pid = main_pid()
            call_and_answer([("201", "202")])
            talking = wait_counts_grow(2)
            cursor = journal_cursor(pbx)
            output = pbx.succeed(f"{base}/specialisation/dialplan/bin/switch-to-configuration test 2>&1")
            print(output)
            assert "asterisk.service" in units(output, "reloading"), output
            assert all("asterisk.service" not in units(output, action) for action in ["stopping", "starting", "restarting"]), output
            wait_journal(pbx, cursor, "asterisk-config: module reload pbx_config.so")
            assert main_pid() == pid, "asterisk was restarted"
            # the same channels
            assert wait_counts_grow(2) == talking
            hear_each_other(soft["201"], soft["202"])
            contacts = asterisk(pbx, "pjsip show contacts")
            for ext in phones:
                assert f"Contact:  {ext}/sip:{ext}@" in contacts, contacts
            caller = ata["101"]
            mark = recorded(caller)
            caller.call("199")
            wait_journal(pbx, cursor, r"<PJSIP/101-[0-9a-f]+> Playing 'demo-congrats\.")
            # the demo goes on for half a minute; 3 s of it hold speech
            wait_recorded(caller, mark, 3)
            loud = [level for level in levels(caller, mark) if level > SILENCE]
            assert len(loud) >= 10, levels(caller, mark)
            cli_parallel([(p, "call hangup_all") for p in [caller, soft["201"], soft["202"]]])
            wait_idle(pbx)
      '';
  }
