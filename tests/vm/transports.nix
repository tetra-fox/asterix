# Phones on UDP and TCP over IPv4, and on UDP over IPv6 from a network
# without IPv4 (TLS is in tls-realtime.nix). They register on their
# transports, call each other in every direction with audio relayed across
# transports and address families, and each phone is only given PBX addresses
# of its own family. The IPv6 transport is bound to the PBX's address, which
# Asterisk can only bind once duplicate address detection is done with it.
#
#   VLAN 1  pbx      192.168.1.1, 2001:db8:1::1
#           phones   192.168.1.2  401 over UDP, 402 over TCP
#           v6phone  2001:db8:1::3 only, 403 over UDP
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = [
    "401"
    "402"
    "403"
  ];
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-transports";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports = {
              udp = {};
              tcp.protocol = "tcp";
              udp6.address = "2001:db8:1::1";
            };
            # no `transport`: Asterisk picks the one that matches the contact
            endpoints = lib.genAttrs extensions (extension: {
              context = "phones";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          dialplan.contexts.phones.extensions."_40X" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
      };

      v6phone = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        # no IPv4 at all, so pjsua offers IPv6 media on its own calls too
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [];
        virtualisation.qemu.networkingOptions = lib.mkForce [];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        import itertools

        start_all()
        pbx.wait_for_unit("asterisk.service")

        phone = {
            "401": Phone(phones, "401", "401", "pw-401", "pbx", sip_port=5060, cli_port=2300),
            "402": Phone(phones, "402", "402", "pw-402", "pbx;transport=tcp", sip_port=5061, cli_port=2301),
            "403": Phone(v6phone, "403", "403", "pw-403", "[2001:db8:1::1]", sip_port=5060, cli_port=2300),
        }

        with subtest("asterisk listens on every transport"):
            sockets = pbx.succeed("ss -Hlun 'sport = :5060'")
            assert "0.0.0.0:5060" in sockets and "[2001:db8:1::1]:5060" in sockets, sockets
            pbx.succeed("ss -Hltn 'sport = :5060' | grep -q '0.0.0.0:5060'")

        with subtest("phones register over UDP, TCP and IPv6"):
            v6phone.wait_until_succeeds("ip -o address show dev eth1 to 2001:db8:1::3 -tentative | grep -q .")
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(phone))
            contacts = asterisk(pbx, "pjsip show contacts")
            # pjsua registers the connection it opened, which calls then reuse
            assert re.search(r"402/sip:402@192\.168\.1\.2:[0-9]+;transport=TCP", contacts), contacts
            assert "403/sip:403@[2001:db8:1::3]" in contacts, contacts

        with subtest("every phone calls every other, with audio both ways"):
            for caller, callee in itertools.permutations(phone, 2):
                phone[caller].call(callee)
                wait_bridged(pbx, caller, callee)
                print(caller, callee, wait_for_media_both_ways(pbx, [phone[caller], phone[callee]]))
                phone[caller].hangup()
                wait_idle(pbx)

        with subtest("each phone is only given PBX addresses of its own family"):
            for ext, address in [("401", "IN IP4 192.168.1.1"), ("402", "IN IP4 192.168.1.1"), ("403", "IN IP6 2001:db8:1::1")]:
                invites = phone[ext].received("INVITE")
                assert len(invites) == 2, invites
                for invite in invites:
                    assert f"c={address}" in invite, invite
      '';
  }
