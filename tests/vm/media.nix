# Where the audio of a call flows, and what a caller notices when it can't.
# Two phones on one network with directMedia, which send RTP where the SDP
# says as desk phones do, send it to each other once the call is up and
# nothing passes the PBX. The PBX's RTP range has four even ports and one of
# them is the SIP port, which Asterisk skips, so three call legs fill it: a
# caller whose callee's leg gets no port is declined (603), one whose own leg
# gets none is refused (488), the journal says why, and the calls holding the
# ports go on. The range ends on an
# even port, whose leg has its RTCP one port past the range, and the firewall
# lets that in. When a phone's RTP source port changes during a call, as it
# does behind a NAT that rebinds, strictRtp on (Asterisk's default) or seqno
# stops passing its audio and logs nothing, and off follows the new port.
#
#   VLAN 1  10.3.1.0/24  pbx .10, lan1 .21 (201, 202 with directMedia; 211 behind NAT)
#   VLAN 2  10.3.2.0/24  pbx .10, lan2 .21 (212)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  address = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };

  phones = vlan: {
    imports = [
      ./common.nix
      ./phone.nix
      (address "eth1" "10.3.${toString vlan}.21")
    ];
    virtualisation.vlans = [vlan];
  };

  extensions = ["201" "202" "211" "212"];
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-media";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
          (address "eth1" "10.3.1.10")
          (address "eth2" "10.3.2.10")
        ];
        virtualisation.vlans = [
          1
          2
        ];
        # the kernel logs what the firewall drops
        networking.firewall.logRefusedPackets = true;

        services.asterisk = {
          enable = true;
          openFirewall = true;
          # the test follows strict RTP and RTCP through verbose messages
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 4;
          pjsip = {
            transports.udp = {};
            endpoints = lib.genAttrs extensions (extension: {
              context = "phones";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
              directMedia = builtins.elem extension ["201" "202"];
              behindNat = extension == "211";
            });
          };
          # 5056, 5058 and 5062 for RTP; 5060 is the SIP transport's
          rtp.portRange = {
            from = 5056;
            to = 5062;
          };
          dialplan.contexts.phones.extensions = {
            "_2XX" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "Hangup()"
            ];
            # a call of one leg, which hears itself
            "600" = [
              "Answer()"
              "Echo()"
            ];
          };
        };

        specialisation = {
          strict-seqno.configuration.services.asterisk.rtp.strictRtp = "seqno";
          strict-off.configuration.services.asterisk.rtp.strictRtp = false;
        };
      };

      lan1 = {
        imports = [(phones 1)];
        # to move a phone's RTP source during a call, as a NAT would
        environment.systemPackages = [pkgs.nftables];
      };

      lan2 = phones 2;
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        lan1.wait_until_succeeds("ip -o address show to 10.3.1.21 | grep -q .")
        lan2.wait_until_succeeds("ip -o address show to 10.3.2.21 | grep -q .")

        # the phones with directMedia send RTP only where the SDP says
        anna = Phone(lan1, "anna", "201", "pw-201", "10.3.1.10", sip_port=5070, cli_port=2300, symmetric_rtp=False)
        ben = Phone(lan1, "ben", "202", "pw-202", "10.3.1.10", sip_port=5072, cli_port=2301, symmetric_rtp=False)
        dan = Phone(lan1, "dan", "211", "pw-211", "10.3.1.10", sip_port=5074, cli_port=2302)
        eve = Phone(lan2, "eve", "212", "pw-212", "10.3.2.10", sip_port=5072, cli_port=2301)
        everyone = [anna, ben, dan, eve]
        start_phones(everyone)
        wait_registrations({phone: 200 for phone in everyone})

        def wait_peers(expected, timeout=30):
            """Wait until each phone receives its RTP from the address in `expected`"""
            deadline = time.time() + timeout
            while True:
                found = media_peers(list(expected))
                if all(found[phone.name] == address for phone, address in expected.items()):
                    return
                if time.time() > deadline:
                    raise Exception(f"RTP came from {found}")
                time.sleep(1)

        def bound_ports():
            """UDP ports Asterisk has bound"""
            output = pbx.succeed("ss -Hulnp | grep asterisk")
            return sorted(int(line.split()[3].rsplit(":", 1)[1]) for line in output.splitlines())

        def disconnect_reason(phone):
            return re.findall(r"is DISCONNECTED \[reason=(\d+)", phone.log_text())[-1]

        with subtest("two phones on one network with directMedia send RTP to each other, not through the PBX"):
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            wait_peers({anna: "%s:%d" % ben.rtp_address(), ben: "%s:%d" % anna.rtp_address()})
            relayed = channel_stats(pbx)
            wait_hears(anna, [ben.tone])
            wait_hears(ben, [anna.tone])
            assert channel_stats(pbx) == relayed, (relayed, channel_stats(pbx))
            anna.hangup()
            wait_idle(pbx)

        with subtest("a call the RTP range has no port for fails, and the log says why"):
            cursor = journal_cursor(pbx)
            dan.call("212")
            wait_bridged(pbx, "211", "212")
            # one port is left: the caller's leg takes it, the callee's gets none
            invites = anna.requests("INVITE")
            ben.call("201")
            ben.wait_disconnected()
            assert disconnect_reason(ben) == "603", ben.log_text()[-2000:]
            assert anna.requests("INVITE") == invites
            wait_journal(pbx, cursor, "couldn't allocate a port for RTP instance")
            # the last port goes to a call of one leg, then a caller finds none
            anna.call("600")
            wait_channel(pbx, "201", app="Echo")
            ben.call("600")
            ben.wait_disconnected(after=1)
            assert disconnect_reason(ben) == "488", ben.log_text()[-2000:]
            wait_journal(pbx, cursor, "couldn't allocate a port for RTP instance", count=2)
            # the calls that hold the ports go on
            wait_hears(dan, [eve.tone])
            wait_hears(eve, [dan.tone])
            wait_hears(anna, [anna.tone])

        with subtest("RTP skips the SIP port in its range, and RTCP above the range's even end gets through"):
            ports = bound_ports()
            # SIP on 5060, RTP on the other even ports and RTCP one above each
            assert ports.count(5060) == 1 and {5056, 5057, 5058, 5059, 5062, 5063} <= set(ports), ports
            peers = media_peers([dan, eve, anna])
            top = [phone for phone in [dan, eve, anna] if peers[phone.name].endswith(":5062")][0]
            host, port = top.rtp_address()
            since = journal_cursor(pbx)
            asterisk(pbx, f"rtcp set debug ip {host}:{port + 1}")
            wait_journal(pbx, since, f"RTCP from {host}:{port + 1}")
            asterisk(pbx, "rtcp set debug off")
            # the phones send RTCP from the start of their calls
            _, refused = pbx.execute(f"journalctl -k --after-cursor={shlex.quote(cursor)} | grep 'refused packet.* DPT=5063 '")
            assert refused == "", refused
            for phone in [dan, anna]:
                phone.hangup()
            wait_idle(pbx)

        # strictRtp as Asterisk has it (yes), seqno, and off
        for mode, value in [(None, "on"), ("strict-seqno", "seqno"), ("strict-off", "off")]:
            follows = mode == "strict-off"
            with subtest(f"when dan's RTP source moves during a call, strictRtp {value} {'follows it' if follows else 'drops it without a word'}"):
                if mode:
                    pbx.succeed(f"{base}/specialisation/{mode}/bin/switch-to-configuration test")
                cursor = journal_cursor(pbx)
                dan.call("212")
                wait_bridged(pbx, "211", "212")
                _, port = dan.rtp_address()
                wait_hears(dan, [eve.tone])
                wait_hears(eve, [dan.tone])
                if not follows:
                    wait_journal(pbx, cursor, f"Strict RTP learning complete - Locking on source address 10.3.1.21:{port}")
                cursor = journal_cursor(pbx)
                # dan's RTP leaves from port + 100 from now on, and what comes
                # back to that port reaches dan, as through a NAT that rebinds
                lan1.succeed(
                    "nft add table ip move",
                    "nft 'add chain ip move out { type filter hook output priority raw; }'",
                    "nft 'add chain ip move in { type filter hook prerouting priority raw; }'",
                    f"nft add rule ip move out udp sport {port} udp sport set {port + 100}",
                    f"nft add rule ip move in udp dport {port + 100} udp dport set {port}",
                )
                # what the phones hear from here on
                for phone in [dan, eve]:
                    wait_recorded(phone, recorded(phone), 1)
                wait_hears(dan, [eve.tone])
                wait_hears(eve, [dan.tone] if follows else [])
                logged = journal_since(pbx, cursor)
                assert not re.search("NOTICE|WARNING|ERROR", logged), logged
                lan1.succeed("nft delete table ip move")
                dan.hangup()
                wait_idle(pbx)
      '';
  }
