# examples/household-intercom.nix, used unmodified.
#
#   pbx          servers (VLAN 3) 10.0.1.10, lan (VLAN 1) 10.0.10.10, voip (VLAN 2) 10.0.20.10
#   softphones   lan  10.0.10.21  runs extensions 201 and 202
#   deskphones   voip 10.0.20.21  runs extensions 101, 102 and 103
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
    "101" = "desk-101-pw";
    "102" = "desk-102-pw";
    "103" = "desk-103-pw";
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
        # SIP messages in the journal, to check the paging headers on the wire
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

      deskphones = {
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

    testScript =
      builtins.readFile ./phone.py
      + ''
        passwords = ${builtins.toJSON passwords}

        start_all()
        pbx.wait_for_unit("asterisk.service")

        desk = {
            ext: Phone(deskphones, ext, ext, passwords[ext], "10.0.20.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["101", "102", "103"])
        }
        soft = {
            ext: Phone(softphones, ext, ext, passwords[ext], "10.0.10.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["201", "202"])
        }
        phones = {**desk, **soft}

        def invites(phone):
            return len(phone.received_invites())

        def wait_for_invite(phone, seen):
            phone.machine.wait_until_succeeds(
                f"test $(grep -c 'RX [0-9]* bytes Request msg INVITE' {phone.log}) -gt {seen}", timeout=120
            )

        def wait_idle():
            pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -q '^0 active channels'", timeout=120)

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
            wrong = Phone(deskphones, "wrong", "102", "not-the-password", "10.0.20.10", sip_port=5070, cli_port=2310)
            wrong.start()
            # pjsua gives up once the server rejects its credentials
            wrong.wait_registration_failed("Credential failed to authenticate")
            wrong.stop()

        with subtest("credentials only work from the phone's own network"):
            # desk phone 103's correct password, used from the trusted LAN. Asterisk
            # answers a request that fails the endpoint's contact ACL like one with a
            # wrong password (401), so the reason is only in its log.
            moved = Phone(softphones, "moved", "103", passwords["103"], "10.0.10.10", sip_port=5070, cli_port=2310)
            moved.start()
            moved.wait_registration_failed("Credential failed to authenticate")
            moved.stop()
            journal = pbx.succeed("journalctl -u asterisk.service")
            assert re.search(
                r"from '<sip:103@10\.0\.10\.10>' failed for '10\.0\.10\.21:5070' .* - Not match Endpoint Contact ACL", journal
            ), "103 was not rejected by its contact ACL"
            assert "103@10.0.10.21" not in asterisk(pbx, "pjsip show contacts")

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
            pbx.succeed("iptables -D nixos-fw -i servers -p udp --dport 5060 -j ACCEPT")
            assert "10.0.1.66" not in asterisk(pbx, "pjsip show contacts")

        with subtest("desk phone and softphone call each other across VLANs"):
            soft["201"].call("101")
            stats = wait_for_media_both_ways(pbx)
            print(stats)
            # each phone only ever talks to the PBX's address on its own VLAN
            assert "c=IN IP4 10.0.20.10" in desk["101"].log_text()
            assert "c=IN IP4 10.0.10.21" not in desk["101"].log_text()
            assert "c=IN IP4 10.0.10.10" in soft["201"].log_text()
            assert "c=IN IP4 10.0.20.21" not in soft["201"].log_text()
            soft["201"].hangup()
            wait_idle()

        with subtest("page all: every other phone is called with auto-answer headers"):
            before = {ext: invites(phone) for ext, phone in phones.items()}
            soft["201"].call("100")
            for ext in ["101", "102", "103", "202"]:
                wait_for_invite(phones[ext], before[ext])
                invite = phones[ext].received_invites()[-1]
                assert "Call-Info: <sip:intercom>;answer-after=0" in invite, invite
                assert "Alert-Info: info=alert-autoanswer" in invite, invite
            # the pager itself is busy and skipped
            assert invites(soft["201"]) == before["201"]
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^\\S+ +5 '", timeout=90)
            journal = pbx.succeed("journalctl -u asterisk.service")
            assert "Call-Info: <sip:intercom>;answer-after=0" in journal
            soft["201"].hangup()
            wait_idle()

        with subtest("a page group only reaches its members"):
            before = {ext: invites(phone) for ext, phone in phones.items()}
            soft["202"].call("110")
            for ext in ["101", "102"]:
                wait_for_invite(phones[ext], before[ext])
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^\\S+ +3 '", timeout=90)
            for ext in ["103", "201"]:
                assert invites(phones[ext]) == before[ext], f"{ext} was paged"
            soft["202"].hangup()
            wait_idle()
      '';
  }
