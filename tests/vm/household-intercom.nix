# examples/household-intercom.nix, used unmodified.
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
        # SIP messages in the journal, for looking into failures
        services.asterisk = {
          pjsip.global.debug = true;
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
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

    testScript =
      builtins.readFile ./phone.py
      + ''
        passwords = ${builtins.toJSON passwords}

        start_all()
        pbx.wait_for_unit("asterisk.service")

        ata = {
            ext: Phone(adapters, ext, ext, passwords[ext], "10.0.20.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["101", "102"])
        }
        soft = {
            ext: Phone(softphones, ext, ext, passwords[ext], "10.0.10.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["201", "202"])
        }
        phones = {**ata, **soft}

        with subtest("the host does not route between the VLANs"):
            pbx.succeed("test \"$(sysctl -n net.ipv4.ip_forward)\" = 0")
            pbx.succeed("test \"$(sysctl -n net.ipv6.conf.all.forwarding)\" = 0")

        with subtest("SIP is only offered on the phone networks"):
            sockets = pbx.succeed("ss -Hlun 'sport = :5060'")
            assert "10.0.10.10:5060" in sockets and "10.0.20.10:5060" in sockets, sockets
            assert "0.0.0.0:5060" not in sockets and "10.0.1.10:5060" not in sockets, sockets

        with subtest("all phones register"):
            for phone in phones.values():
                phone.start()
            for phone in phones.values():
                phone.wait_registered()
            contacts = asterisk(pbx, "pjsip show contacts")
            for ext in phones:
                assert f"Contact:  {ext}/sip:{ext}@" in contacts, contacts

        with subtest("a wrong password is rejected"):
            wrong = Phone(adapters, "wrong", "102", "not-the-password", "10.0.20.10", sip_port=5070, cli_port=2310)
            wrong.start()
            # pjsua gives up once the server rejects its credentials
            wrong.wait_registration_failed("Credential failed to authenticate")
            wrong.stop()

        with subtest("credentials only work from the phone's own network"):
            # adapter 102's correct password, used from the trusted LAN. Asterisk
            # answers a request that fails the endpoint's contact ACL like one with a
            # wrong password (401), so the reason is only in its log.
            moved = Phone(softphones, "moved", "102", passwords["102"], "10.0.10.10", sip_port=5070, cli_port=2310)
            moved.start()
            moved.wait_registration_failed("Credential failed to authenticate")
            moved.stop()
            journal = pbx.succeed("journalctl -u asterisk.service")
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
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service")
            sipp(intruder, "malformed", "10.0.10.10", "-s", "201")
            assert pbx.succeed("systemctl show -P MainPID asterisk.service") == pid, "Asterisk restarted"
            pbx.succeed("iptables -D nixos-fw -i servers -p udp --dport 5060 -j ACCEPT")
            assert "10.0.1.66" not in asterisk(pbx, "pjsip show contacts")

        with subtest("an adapter and a softphone call each other across VLANs"):
            soft["201"].call("101")
            print(wait_for_media_both_ways(pbx, [soft["201"], ata["101"]]))
            # each phone only ever talks to the PBX's address on its own VLAN
            assert "c=IN IP4 10.0.20.10" in ata["101"].log_text()
            assert "c=IN IP4 10.0.10.21" not in ata["101"].log_text()
            assert "c=IN IP4 10.0.10.10" in soft["201"].log_text()
            assert "c=IN IP4 10.0.20.21" not in soft["201"].log_text()
            soft["201"].hangup()
            wait_idle(pbx)

        with subtest("911 says that it cannot be called, then hangs up"):
            before = ata["101"].disconnects()
            ata["101"].call("911")
            wait_channel(pbx, "101", app="Playback", state="Up")
            # audio arrives, so the recording exists
            print(wait_for_media_both_ways(pbx, [ata["101"]]))
            ata["101"].wait_disconnected(after=before, timeout=60)
            wait_idle(pbx)

        with subtest("three phones meet in the conference room"):
            for ext in ["101", "201", "202"]:
                phones[ext].call("800")
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^800 +3 '", timeout=90)
            print(wait_for_media_both_ways(pbx, [phones[ext] for ext in ["101", "201", "202"]]))
            for ext in ["101", "201", "202"]:
                phones[ext].hangup()
            wait_idle(pbx)
      '';
  }
