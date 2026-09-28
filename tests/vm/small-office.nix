# examples/small-office.nix, used unmodified, against a second Asterisk that
# plays the SIP provider (configured with this module as well).
#
#   pbx       lan (VLAN 1) 10.1.0.10, wan (VLAN 2) 203.0.113.10
#   provider  wan 203.0.113.5, sip.provider.example in its own DNS server
#   phones    lan 10.1.0.21, runs 201 and 202 (ring without answering) and 203
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;

  secrets = {
    sip-trunk = "trunk-password";
    sip-201 = "pw-201";
    sip-202 = "pw-202";
    sip-203 = "pw-203";
    vm-200 = "4200";
    vm-201 = "4201";
    vm-202 = "4202";
    vm-203 = "4203";
  };

  onlyAddress = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-small-office";

    nodes = {
      pbx = {
        imports = [
          self.nixosModules.default
          ../../examples/small-office.nix
          ./common.nix
          (sopsSecrets secrets)
          (onlyAddress "lan" "10.1.0.10")
          (onlyAddress "wan" "203.0.113.10")
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          wan.vlan = 2;
        };
        # Asterisk resolves SIP hosts with DNS only (not /etc/hosts): use the
        # provider's name server
        networking.nameservers = ["203.0.113.5"];
      };

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {fixed.customer = secrets.sip-trunk;})
          (onlyAddress "eth1" "203.0.113.5")
        ];
        virtualisation.vlans = [2];

        # DNS for the provider's host name
        services.dnsmasq = {
          enable = true;
          settings = {
            no-resolv = true;
            address = "/sip.provider.example/203.0.113.5";
          };
        };
        networking.firewall.allowedUDPPorts = [53];

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
            # calls from the office: remember who called which number
            carrier.extensions."_X." = [
              "Set(DB(calls/last)=\${CALLERID(num)}:\${EXTEN})"
              "Answer()"
              "Playback(tt-monkeys)"
              "Wait(30)"
              "Hangup()"
            ];
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
          (onlyAddress "eth1" "10.1.0.21")
        ];
        virtualisation.vlans = [1];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        provider.wait_for_unit("asterisk.service")

        # the ring group rings without anyone answering
        reception = Phone(phones, "201", "201", "pw-201", "10.1.0.10", sip_port=5060, cli_port=2300, auto_answer=180)
        sales = Phone(phones, "202", "202", "pw-202", "10.1.0.10", sip_port=5061, cli_port=2301, auto_answer=180)
        boss = Phone(phones, "203", "203", "pw-203", "10.1.0.10", sip_port=5062, cli_port=2302)

        with subtest("the trunk registers with the provider"):
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q 'Registered'", timeout=180)
            provider.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q '5551000/sip:5551000@203.0.113.10'")

        with subtest("phones register"):
            start_phones([reception, sales, boss])
            for phone in (reception, sales, boss):
                phone.wait_registered()

        with subtest("an inbound call rings the ring group, then goes to voicemail"):
            before = {p.name: p.requests("INVITE") for p in (reception, sales, boss)}
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            for phone in (reception, sales):
                phone.wait_request("INVITE", after=before[phone.name], timeout=120)
            pbx.wait_until_succeeds("test -f /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0000.txt", timeout=240)
            assert boss.requests("INVITE") == before["203"], "203 is not in the ring group"
            message = pbx.succeed("cat /var/lib/asterisk/spool/voicemail/default/200/INBOX/msg0000.txt")
            assert "callerid=" in message, message
            wait_idle(pbx, timeout=180)

        with subtest("an outbound call reaches the provider with the office number"):
            boss.call("95559999")
            provider.wait_until_succeeds("asterisk -rx 'database get calls last' | grep -q 'Value: 5551000:5559999'", timeout=120)
            # the provider's leg is the second channel
            wait_for_media_both_ways(pbx, [boss], minimum=20, count=2)
            boss.hangup()
            wait_idle(pbx, timeout=180)

        with subtest("two phones join the conference bridge"):
            reception.call("800")
            boss.call("800")
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -E '^800 +2 '", timeout=120)
            reception.hangup()
            boss.hangup()
            wait_idle(pbx, timeout=180)

        with subtest("the support queue has its members"):
            queue = asterisk(pbx, "queue show support")
            assert "PJSIP/201" in queue and "PJSIP/202" in queue, queue

        with subtest("voicemail PINs are secrets"):
            pbx.fail("grep -R 4200 /etc/asterisk/")
            pbx.succeed("grep -q '200 => 4200,Sales team' /run/asterisk/config/voicemail.conf")
      '';
  }
