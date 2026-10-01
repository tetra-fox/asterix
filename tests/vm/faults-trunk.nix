# Faults between the office and its provider, and phones that lose power.
# The provider's name does not resolve when the office starts, for longer than
# Asterisk's default of ten registration attempts: the trunk keeps trying and
# registers once the name resolves, and the provider's address it lists
# identifies the provider all along. The provider stops answering in a call: a
# new call fails with congestion, a fast busy, after the INVITE's timeout, and
# immediately once qualify marks the provider unreachable; when it is back, the
# call goes on and calls go out again within the qualify interval. The same
# holds when the office's own trunk link goes down and up. The provider moves
# to a new address, and calls go both ways without a restart. A phone that
# loses power in a call, so no BYE ever comes, has its call ended by the
# session timer it asked for, on a call to another phone and on a trunk call,
# and one that asked for none by the RTP timeout pbx gives an extension.
#
#   pbx       lan (VLAN 1) 10.1.0.10, wan (VLAN 2) 203.0.113.10
#   provider  wan 203.0.113.5 (SIP), 203.0.113.53 (DNS, sip.provider.example)
#   phones    lan 10.1.0.21
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = ["201" "202" "203" "204"];

  onlyAddresses = interface: addresses: {
    networking.interfaces.${interface}.ipv4.addresses = lib.mkForce (map (address: {
        inherit address;
        prefixLength = 24;
      })
      addresses);
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-faults-trunk";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {sip-trunk = "trunk-password";}
              // lib.listToAttrs (map (e: lib.nameValuePair "sip-${e}" "pw-${e}") extensions);
          })
          (onlyAddresses "lan" ["10.1.0.10"])
          (onlyAddresses "wan" ["203.0.113.10"])
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          wan.vlan = 2;
        };
        # Asterisk resolves SIP hosts with DNS only
        # (res/res_pjsip/pjsip_resolver.c:698, main/dns.c:296)
        networking.nameservers = ["203.0.113.53"];

        pbx = {
          enable = true;
          extensions = lib.genAttrs extensions (extension: {password = secret "sip-${extension}";});
          inbound."5551000" = {
            trunk = "provider";
            destination.extension = "202";
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };
        };

        services.asterisk = {
          openFirewall = true;
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
          pjsip = {
            transports.udp = {};
            # 201 and 203 ask for session timers, which alone end their calls
            # when they lose power
            endpoints = lib.genAttrs ["201" "203"] (_: {rtpTimeout = 0;});
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "sip-trunk";
              allow = [
                "alaw"
                "ulaw"
              ];
              registration.contactUser = "5551000";
              # beside the provider's name, which does not resolve at first
              identify.match = ["203.0.113.5"];
              # short intervals keep the outages short; the test measures
              # recovery against them
              registration.retryInterval = 5;
              qualifyFrequency = 10;
            };
          };
        };
      };

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {fixed.customer = "trunk-password";})
          (onlyAddresses "eth1" [
            "203.0.113.5"
            "203.0.113.53"
          ])
        ];
        virtualisation.vlans = [2];

        # the provider's name, from a file the test rewrites when it moves
        services.dnsmasq = {
          enable = true;
          settings = {
            no-resolv = true;
            no-hosts = true;
            addn-hosts = "/run/provider-hosts";
            # names of the domain missing from the file do not exist
            local = "/provider.example/";
          };
        };
        # empty when the office starts
        systemd.tmpfiles.rules = ["f /run/provider-hosts 0644 root root -"];
        networking.firewall.allowedUDPPorts = [53];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
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
            # calls from the office hear a 1500 Hz tone, no phone's
            carrier.extensions."_X." = [
              "Answer()"
              "Playtones(1500)"
              "Wait(600)"
              "Hangup()"
            ];
            feed.extensions.s = [
              "Playtones(1500)"
              "Wait(600)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddresses "eth1" ["10.1.0.21"])
        ];
        virtualisation.vlans = [1];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        PROVIDER_TONE = 1500
        DROP_OFFICE = ["INPUT -s 203.0.113.10 -p udp ! --dport 53 -j DROP", "OUTPUT -d 203.0.113.10 -p udp ! --sport 53 -j DROP"]

        def registration(status):
            return f"asterisk -rx 'pjsip show registrations' | grep -qE '^ provider/sip:sip.provider.example .* {status} '"

        def power_off(phone):
            """The phone stops: it sends nothing more, not even a BYE, and
            what reaches it goes unanswered, without an ICMP error."""
            phone.machine.succeed(f"systemctl kill --signal=STOP sip-phone-{phone.name}")

        provider.start()
        provider.wait_for_unit("asterisk.service")
        provider.wait_for_unit("dnsmasq.service")
        start_all()
        pbx.wait_for_unit("asterisk.service")

        with subtest("the provider's name does not resolve for more than ten registration attempts: the trunk keeps trying, its listed address identifies the provider, and it registers once the name resolves"):
            # the attempts since boot; each fails as soon as the name does not resolve
            pbx.wait_until_succeeds(
                "test $(journalctl -u asterisk.service | grep -cE 'on registration attempt to|Maximum retries reached') -ge 11", timeout=120
            )
            # Asterisk left out the identify section of the name, which did not
            # resolve when it loaded, and only that one
            identifies = asterisk(pbx, "pjsip show identifies")
            assert re.search(r"^ *Identify: +provider/provider", identifies, re.M), identifies
            assert not re.search(r"^ *Identify: +provider-host/provider", identifies, re.M), identifies
            provider.succeed("echo '203.0.113.5 sip.provider.example' > /run/provider-hosts", "systemctl kill --signal=HUP dnsmasq.service")
            # the next attempt comes retryInterval (5 s) later
            pbx.wait_until_succeeds(registration("Registered"), timeout=15)
            # calls go out once the next qualify, qualifyFrequency (10 s) later,
            # finds the provider reachable
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Avail '", timeout=15)

        timers = "--timer-se=90 --timer-min-se=90"
        a = Phone(phones, "201", "201", "pw-201", "10.1.0.10", sip_port=5060, cli_port=2300, options=timers)
        b = Phone(phones, "202", "202", "pw-202", "10.1.0.10", sip_port=5061, cli_port=2301)
        c = Phone(phones, "203", "203", "pw-203", "10.1.0.10", sip_port=5062, cli_port=2302, options=timers)
        # a phone without session timers, as some desk phones and adapters are
        d = Phone(phones, "204", "204", "pw-204", "10.1.0.10", sip_port=5063, cli_port=2303, options="--use-timer=0")
        with subtest("phones register"):
            start_phones([a, b, c, d])
            wait_registrations({a: 200, b: 200, c: 200, d: 200})

        with subtest("the provider gone mid-call: new calls fail with congestion, and once it is back the call goes on and calls go out again"):
            a.call("95559001")
            wait_hears(a, [PROVIDER_TONE])
            provider.succeed(*[f"iptables -I {rule}" for rule in DROP_OFFICE])
            # while the provider still counts as reachable, a call waits for
            # the INVITE's 32 s timeout
            c.call("95559002")
            c.wait_disconnected(timeout=40)
            # and immediately once qualify marks the provider unreachable
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Unavail '", timeout=15)
            d.call("95559003")
            d.wait_disconnected(timeout=5)
            # both get congestion, which phones play as a fast busy
            for phone in (c, d):
                status = re.findall(r"is DISCONNECTED \[reason=(\d+) ", phone.log_text())
                assert status == ["503"], f"{phone.name}: {status}"
            provider.succeed(*[f"iptables -D {rule}" for rule in DROP_OFFICE])
            # the next qualify, qualifyFrequency (10 s) later
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Avail '", timeout=15)
            wait_hears(a, [PROVIDER_TONE])
            c.call("95559004")
            wait_hears(c, [PROVIDER_TONE])
            pbx.succeed(registration("Registered"))
            a.hangup()
            c.hangup()
            wait_idle(pbx)

        with subtest("the trunk link down and up in a call: the call goes on, and calls go out again"):
            a.call("95559005")
            wait_hears(a, [PROVIDER_TONE])
            # wan is the pbx's second interface on a vlan
            pbx.send_monitor_command("set_link vlan2 off")
            pbx.succeed("ip link show wan | grep -q NO-CARRIER")
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Unavail '", timeout=15)
            pbx.send_monitor_command("set_link vlan2 on")
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Avail '", timeout=15)
            wait_hears(a, [PROVIDER_TONE])
            c.call("95559006")
            wait_hears(c, [PROVIDER_TONE])
            pbx.succeed(registration("Registered"))
            a.hangup()
            c.hangup()
            wait_idle(pbx)

        with subtest("the provider moves to a new address: calls go both ways without a restart"):
            # the provider's server has only the new address, which it sends
            # from, and its name server comes back beside it
            provider.succeed(
                "echo '203.0.113.6 sip.provider.example' > /run/provider-hosts",
                "systemctl kill --signal=HUP dnsmasq.service",
                "ip address flush dev eth1 scope global",
                "ip address add 203.0.113.6/24 dev eth1",
                "ip address add 203.0.113.53/24 dev eth1",
            )
            c.call("95559007")
            wait_hears(c, [PROVIDER_TONE])
            c.hangup()
            wait_idle(pbx)
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/.* Avail '", timeout=15)
            # the provider qualifies the office's contact as well, and calls
            # it only once that answered since the outage
            provider.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +5551000/.* Avail '", timeout=70)
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            b.wait_confirmed(timeout=30)
            wait_hears(b, [PROVIDER_TONE])
            b.hangup()
            wait_idle(pbx)

        with subtest("a phone that loses power in a call is hung up by its session timer, on a call to a phone and on a trunk call"):
            a.call("202")
            wait_bridged(pbx, "201", "202")
            c.call("95559008")
            wait_hears(c, [PROVIDER_TONE])
            byes = b.requests("BYE")
            power_off(a)
            power_off(c)
            # the phones asked for 90 s: a third of that before the session
            # expires, 60 s after the last refresh, Asterisk sends the phone a
            # BYE, and hangs up the other leg once that times out 32 s later
            b.wait_request("BYE", after=byes, timeout=100)
            wait_idle(provider, timeout=100)
            wait_idle(pbx)

        with subtest("a phone without session timers that loses power in a trunk call is hung up by its RTP timeout"):
            d.call("95559009")
            wait_hears(d, [PROVIDER_TONE])
            cursor = journal_cursor(pbx)
            power_off(d)
            # 60 s without RTP from the phone, then the trunk leg ends with it
            wait_idle(provider, timeout=100)
            wait_idle(pbx)
            wait_journal(pbx, cursor, r"Disconnecting channel 'PJSIP/204-[0-9a-f]+' for lack of audio RTP activity", timeout=10)
      '';
  }
