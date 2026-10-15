# examples/household-intercom.nix, used unmodified: Asterisk starts without
# an error or a warning and waits for a phone network's address it binds;
# SIP and RTP are only open on the phone networks; phones register from their
# own network only, and the intruder is refused by the firewall and by the
# SIP ACL; calls in every direction ring with the caller's name, are heard
# both ways through the pbx's address on each network and end from either
# side.
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
          self.nixosModules.asterisk
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

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        passwords = ${builtins.toJSON passwords}
        names = ${builtins.toJSON names}

        start_all()
        pbx.wait_for_unit("asterisk.service")

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

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def wait_counts_grow(count, minimum=50, timeout=60):
            """pjsip show channelstats lists `count` channels, one per phone in
            a call, whose receive and transmit counts go on growing."""
            deadline = time.time() + timeout
            while len(before := channel_stats(pbx)) != count:
                assert time.time() < deadline, before
                time.sleep(1)
            while True:
                now = channel_stats(pbx)
                if set(now) == set(before) and all(
                    now[c]["rx"] >= before[c]["rx"] + minimum and now[c]["tx"] >= before[c]["tx"] + minimum for c in before
                ):
                    return
                assert time.time() < deadline, (before, now)
                time.sleep(1)

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
            version = asterisk(pbx, "core show version").split()[1]
            assert version == "${nodes.pbx.services.asterisk.package.version}", version

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

        with subtest("credentials only work from the phone's own network"):
            # adapter 102's correct password, used from the trusted LAN. Asterisk
            # answers a request that fails the endpoint's contact ACL like one with a
            # wrong password (401), so the reason is only in its log.
            moved = Phone(softphones, "moved", "102", passwords["102"], "10.0.10.10", sip_port=5070, cli_port=2310)
            moved.start()
            # pjsua gives up once the server rejects its credentials
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

        with subtest("the intruder cannot register: SIP ACL, with the firewall opened"):
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
      '';
  }
