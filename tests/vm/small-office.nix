# examples/small-office.nix, used unmodified, against a second Asterisk that
# plays the SIP provider (configured with this module as well): the trunk
# registers at the provider's host name; the office's number rings 201 and
# 202, then the sales mailbox takes a message; an outbound call shows the
# office number and carries audio both ways; the support queue 600 rings 201
# and 202 and the one who answers gets the caller.
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
          self.nixosModules.pbx
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
        # the test follows calls through verbose messages in the journal
        services.asterisk = {
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
        };
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

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        # a provider is up before the office starts, as in reality: the office
        # qualifies its trunk within 5 s of starting and only retries a minute later
        provider.start()
        provider.wait_for_unit("asterisk.service")
        start_all()
        pbx.wait_for_unit("asterisk.service")

        # the ring group rings without anyone answering
        reception = Phone(phones, "201", "201", "pw-201", "10.1.0.10", sip_port=5060, cli_port=2300, auto_answer=180)
        sales = Phone(phones, "202", "202", "pw-202", "10.1.0.10", sip_port=5061, cli_port=2301, auto_answer=180)
        boss = Phone(phones, "203", "203", "pw-203", "10.1.0.10", sip_port=5062, cli_port=2302)

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        with subtest("the trunk registers with the provider"):
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q 'Registered'", timeout=180)
            provider.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q '5551000/sip:5551000@203.0.113.10'")
            # calls only go to a reachable contact
            pbx.wait_until_succeeds(
                "asterisk -rx 'pjsip show contacts' | grep -q 'provider/sip:sip.provider.example .* Avail'", timeout=180
            )

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

        with subtest("the support queue rings 201 and 202 with music for the caller, and the one who answers takes the call"):
            cursor = journal_cursor(pbx)
            invites = {p.name: p.requests("INVITE") for p in (reception, sales)}
            cancels = sales.requests("CANCEL")
            boss.call("600")
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/203-")
            for phone in (reception, sales):
                phone.wait_request("INVITE", after=invites[phone.name])
            reception.cli("call answer 200")
            # through the Local channel into pbx-devices that rings 201
            wait_bridged(pbx, "203", "201@pbx-devices")
            wait_bridged(pbx, "201@pbx-devices", "201")
            sales.wait_request("CANCEL", after=cancels)
            hear_each_other(boss, reception)
            boss.hangup()
            wait_idle(pbx, timeout=180)
      '';
  }
