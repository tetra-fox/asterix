# NAT on both ends of a call, on one end, and phones behind NAT of other
# kinds. The office PBX sits behind a router that forwards SIP and RTP to it
# (its transport has the router's public address as external address and the
# office LAN as local network) and routes all its traffic; a softphone at home
# sits behind a router that masquerades it and advertises its private address
# (`behindNat` on its endpoint). Calls between it and a desk phone in the
# office have audio both ways, each phone is only given PBX addresses it can
# reach, in the From header of Asterisk's requests too, since the endpoints
# of the phones outside name the transport, and hanging up at home ends the
# call in the office. A phone on the internet calls the office the same way.
# Two phones behind the home router, both on port 5060, one of them learning
# its public address from STUN, register with a PBX on a public address and
# call each other;
# then the home router maps each connection to a random port, as a symmetric
# NAT does, so the port STUN gives isn't where the phone's RTP comes from,
# and Asterisk answers where it comes from. When the router gives a call's
# RTP a new port mid-call, strictRtp on (Asterisk's default) leaves both
# phones in silence without a word in the log, and off follows the new port.
# A softphone at home with ICE, STUN and TURN reaches the office PBX, which
# gathers its candidates from the same STUN and TURN server and offers its
# own private addresses among them.
#
#   office LAN  VLAN 1  10.1.0.0/24      pbx .10, deskphone .21, officerouter .1
#   internet    VLAN 2  198.51.100.0/24  officerouter .10, homerouter .20, cloud .40
#   home LAN    VLAN 3  192.168.1.0/24   homerouter .1, remote .50 .51 .52
#
# cloud is the PBX on a public address, a STUN and TURN server (coturn) and
# the phone on the internet (303 of the office PBX).
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

  # the test VMs' default route is QEMU's user network, so the routers are
  # only used for the internet's addresses
  internetVia = interface: via: {
    networking.interfaces.${interface}.ipv4.routes = [
      {
        address = "198.51.100.0";
        prefixLength = 24;
        inherit via;
      }
    ];
  };

  router = lan: wan: {
    imports = [
      ./common.nix
      (address "lan" lan)
      (address "wan" wan)
    ];
    networking.nat = {
      enable = true;
      internalInterfaces = ["lan"];
      externalInterface = "wan";
    };
  };

  secrets = extensions:
    import ./secrets.nix {
      fixed =
        lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions)
        // {turn = "pw-turn";};
    };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-nat";

    nodes = {
      pbx = {config, ...}: let
        endpoint = extension: settings:
          {
            context = "office";
            auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
          }
          // settings;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (secrets ["301" "302" "303" "304"])
          (address "lan" "10.1.0.10")
        ];
        virtualisation.interfaces.lan.vlan = 1;
        # the PBX's default route is the office router, as on an office LAN;
        # Asterisk takes the address it names itself by from there
        networking.defaultGateway = {
          address = "10.1.0.1";
          interface = "lan";
        };

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {
              externalSignalingAddress = "198.51.100.10";
              externalMediaAddress = "198.51.100.10";
              localNet = ["10.1.0.0/24"];
            };
            # the phones outside name the transport, whose external address
            # their endpoints then put in From
            endpoints = {
              # desk phone in the office
              "301" = endpoint "301" {};
              # softphone at home
              "302" = endpoint "302" {
                behindNat = true;
                transport = "udp";
              };
              # phone on the internet, not behind NAT
              "303" = endpoint "303" {transport = "udp";};
              # softphone at home with ICE
              "304" = endpoint "304" {
                behindNat = true;
                transport = "udp";
                settings.ice_support = true;
              };
            };
          };

          rtp = {
            stunServer = "198.51.100.40:3478";
            turn = {
              server = "198.51.100.40:3478";
              username = "turn";
              password = config.lib.asterisk.secret "/run/test-secrets/turn";
            };
          };

          dialplan.contexts.office.extensions."_30X" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
        };
      };

      officerouter = {
        imports = [(router "10.1.0.1" "198.51.100.10")];
        virtualisation.interfaces = {
          lan.vlan = 1;
          wan.vlan = 2;
        };
        # SIP and the PBX's RTP range
        networking.nat.forwardPorts = [
          {
            proto = "udp";
            sourcePort = 5060;
            destination = "10.1.0.10:5060";
          }
          {
            proto = "udp";
            sourcePort = "10000:20000";
            destination = "10.1.0.10:10000-20000";
          }
        ];
      };

      homerouter = {
        imports = [(router "192.168.1.1" "198.51.100.20")];
        virtualisation.interfaces = {
          lan.vlan = 3;
          wan.vlan = 2;
        };
        # to change how it maps ports during the test
        environment.systemPackages = [pkgs.conntrack-tools];
      };

      remote = {
        imports = [
          ./common.nix
          ./phone.nix
          (internetVia "eth1" "192.168.1.1")
        ];
        virtualisation.vlans = [3];
        # one address per phone behind the home router
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce (map (address: {
          inherit address;
          prefixLength = 24;
        }) ["192.168.1.50" "192.168.1.51" "192.168.1.52"]);
      };

      deskphone = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.1.0.21")
        ];
        virtualisation.vlans = [1];
      };

      cloud = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          ./phone.nix
          (secrets ["401" "402"])
          (address "eth1" "198.51.100.40")
        ];
        virtualisation.vlans = [2];

        services.coturn = {
          enable = true;
          listening-ips = ["198.51.100.40"];
          relay-ips = ["198.51.100.40"];
          lt-cred-mech = true;
          realm = "turn.test";
          no-tls = true;
          no-dtls = true;
          no-cli = true;
          # Asterisk asks for its address in RFC 3489 requests, which coturn
          # otherwise ignores
          extraConfig = ''
            user=turn:pw-turn
            rfc3489-compatibility
          '';
        };

        services.asterisk = {
          enable = true;
          # the test waits for strict RTP through verbose messages
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 4;
          pjsip = {
            transports.udp = {};
            # two softphones at home
            endpoints = lib.genAttrs ["401" "402"] (extension: {
              context = "cloud";
              behindNat = true;
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };
          dialplan.contexts.cloud.extensions."_40X" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
        };

        specialisation.strict-off.configuration.services.asterisk.rtp.strictRtp = false;
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        cloud.wait_for_unit("asterisk.service")
        cloud.wait_for_unit("coturn.service")
        cloud_system = cloud.succeed("readlink -f /run/current-system").strip()
        # the firewall service sets up NAT and port forwarding
        for router in [officerouter, homerouter]:
            router.wait_for_unit("firewall.service")
        for machine, gateway in [(pbx, "10.1.0.1"), (remote, "192.168.1.1")]:
            machine.wait_until_succeeds(f"ip route get 198.51.100.20 | grep -q 'via {gateway}'")
        deskphone.wait_until_succeeds("ip -o address show to 10.1.0.21 | grep -q .")
        remote.wait_until_succeeds("ip -o address show to 192.168.1.52 | grep -q .")
        cloud.wait_until_succeeds("ip -o address show to 198.51.100.40 | grep -q .")

        desk = Phone(deskphone, "301", "301", "pw-301", "10.1.0.10", sip_port=5060, cli_port=2300)
        home = Phone(remote, "302", "302", "pw-302", "198.51.100.10", sip_port=5060, cli_port=2300)
        public = Phone(cloud, "303", "303", "pw-303", "198.51.100.10", sip_port=5070, cli_port=2300)

        def header(message, name):
            """Values of a SIP header, or of an SDP line such as `c`, in a message."""
            return [
                line[len(name) + 1 :].strip()
                for line in message.splitlines()
                if line.startswith(f"{name}:") or line.startswith(f"{name}=")
            ]

        def received_with(phone, text):
            """Lines of the SIP messages a phone received that contain `text`"""
            messages = re.findall(r"RX \d+ bytes .*?\n--end msg--", phone.log_text(), re.S)
            return [
                line
                for message in messages
                for line in message.splitlines()[1:]
                # pjsua logs other lines in between, which start with the time
                if text in line and not re.match(r"\d\d:\d\d:\d\d\.\d{3} ", line)
            ]

        def contact_ports(machine):
            return re.findall(r"^ *Contact: +\d+/sip:\d+@198\.51\.100\.20:(\d+)", asterisk(machine, "pjsip show contacts"), re.M)

        with subtest("the phone at home registers through both routers"):
            desk.start()
            # no help from the phone: it keeps its private address in Contact and SDP
            home.start("--auto-update-nat=0 --bound-addr=192.168.1.50")
            wait_contacts(pbx, 2)
            contacts = asterisk(pbx, "pjsip show contacts")
            # rewritten to where the registration came from: the home router
            assert "302/sip:302@198.51.100.20:" in contacts, contacts
            assert "192.168.1.50" not in contacts, contacts

        with subtest("the office calls home: audio both ways, only public PBX addresses at home"):
            desk.call("302")
            wait_bridged(pbx, "301", "302")
            print(wait_for_media_both_ways(pbx, [desk, home]))
            invite = home.received("INVITE")[-1]
            assert set(header(invite, "c")) == {"IN IP4 198.51.100.10"}, invite
            assert all("198.51.100.10" in value for value in header(invite, "Via") + header(invite, "Contact") + header(invite, "From")), invite
            desk.hangup()
            wait_idle(pbx)

        with subtest("home calls the office: the desk phone gets the local address, hanging up at home ends the call"):
            home.call("301")
            wait_bridged(pbx, "301", "302")
            print(wait_for_media_both_ways(pbx, [desk, home]))
            invite = desk.received("INVITE")[-1]
            assert set(header(invite, "c")) == {"IN IP4 10.1.0.10"}, invite
            assert all("10.1.0.10" in value for value in header(invite, "Via") + header(invite, "Contact")), invite
            # the BYE has to find its way back through both routers
            home.hangup()
            wait_idle(pbx)
            assert received_with(home, "10.1.0.") == [], received_with(home, "10.1.0.")
            assert received_with(desk, "192.168.1.") == [], received_with(desk, "192.168.1.")

        with subtest("a phone on the internet calls the office: audio both ways, only public PBX addresses"):
            public.start()
            wait_registrations({public: 200})
            public.call("301")
            wait_bridged(pbx, "301", "303")
            wait_hears(public, [desk.tone])
            wait_hears(desk, [public.tone])
            public.hangup()
            wait_idle(pbx)
            assert received_with(public, "10.1.0.") == [], received_with(public, "10.1.0.")

        with subtest("two phones behind one NAT, one with STUN, register with a public PBX and call each other"):
            anna = Phone(remote, "401", "401", "pw-401", "198.51.100.40", sip_port=5060, cli_port=2301)
            ben = Phone(remote, "402", "402", "pw-402", "198.51.100.40", sip_port=5060, cli_port=2302)
            anna.start("--bound-addr=192.168.1.51 --ip-addr=192.168.1.51 --auto-update-nat=0")
            ben.start("--bound-addr=192.168.1.52 --stun-srv=198.51.100.40:3478")
            wait_registrations({anna: 200, ben: 200})
            wait_contacts(cloud, 2)
            # both registered from the router, which gave them ports of their own
            ports = contact_ports(cloud)
            assert len(set(ports)) == 2, asterisk(cloud, "pjsip show contacts")
            anna.call("402")
            wait_bridged(cloud, "401", "402")
            wait_hears(anna, [ben.tone])
            wait_hears(ben, [anna.tone])
            anna.hangup()
            wait_idle(cloud)
            # STUN gave ben the router's address for its SDP
            assert ben.rtp_address()[0] == "198.51.100.20", ben.rtp_address()
            # neither was given the other's private address
            assert received_with(anna, "192.168.1.52") == [] and received_with(ben, "192.168.1.51") == []

        with subtest("behind a symmetric NAT, a phone's RTP comes from another port than STUN gave it, and Asterisk answers there"):
            homerouter.succeed(
                "iptables -t nat -I nixos-nat-post 1 -o wan -j MASQUERADE --random-fully",
                "conntrack -F",
            )
            for phone in [anna, ben]:
                phone.cli("acc reg")
            cloud.wait_until_succeeds(
                f"asterisk -rx 'pjsip show contacts' | grep -c '@198.51.100.20:' | grep -qx 2"
                f" && ! asterisk -rx 'pjsip show contacts' | grep -qE '@198.51.100.20:({'|'.join(ports)})[;>]'"
            )
            cursor = journal_cursor(cloud)
            anna.call("402")
            wait_bridged(cloud, "401", "402")
            wait_hears(anna, [ben.tone])
            wait_hears(ben, [anna.tone])
            host, port = ben.rtp_address()
            logged = journal_since(cloud, cursor)
            # the RTP instance whose remote address the SDP set learns another one
            instance = re.search(rf"(0x[0-9a-f]+) -- Strict RTP learning after remote address set to: {host}:{port}\n", logged)
            assert instance, logged
            learned = re.findall(rf"{instance.group(1)} -- Strict RTP switching source address to {host}:(\d+)", logged)
            assert learned and str(port) not in learned, (port, logged)
            anna.hangup()
            wait_idle(cloud)

        # strictRtp as Asterisk has it (yes), and off
        for mode in [None, "strict-off"]:
            follows = mode == "strict-off"
            with subtest(f"when the home router gives a call's RTP a new port, strictRtp {'off follows it' if follows else 'on leaves both phones in silence without a word'}"):
                if mode:
                    cloud.succeed(f"{cloud_system}/specialisation/{mode}/bin/switch-to-configuration test")
                cursor = journal_cursor(cloud)
                anna.call("402")
                wait_bridged(cloud, "401", "402")
                wait_hears(anna, [ben.tone])
                wait_hears(ben, [anna.tone])
                _, port = anna.rtp_address()
                if not follows:
                    wait_journal(cloud, cursor, "Strict RTP learning complete - Locking on source address 198.51.100.20", count=2)
                cursor = journal_cursor(cloud)
                rule = f"nixos-nat-post -o wan -s 192.168.1.51 -p udp --sport {port} -j MASQUERADE --to-ports 40000"
                homerouter.succeed(
                    f"iptables -t nat -I {rule}",
                    f"conntrack -D -s 192.168.1.51 -p udp --sport {port}",
                )
                # what the phones hear from here on
                for phone in [anna, ben]:
                    wait_recorded(phone, recorded(phone), 1)
                wait_hears(anna, [ben.tone] if follows else [])
                wait_hears(ben, [anna.tone] if follows else [])
                logged = journal_since(cloud, cursor)
                assert not re.search("NOTICE|WARNING|ERROR", logged), logged
                homerouter.succeed(f"iptables -t nat -D {rule}")
                anna.hangup()
                wait_idle(cloud)

        with subtest("ICE with STUN and TURN: audio both ways, and the PBX offers its private addresses too"):
            ice = Phone(remote, "304", "304", "pw-304", "198.51.100.10", sip_port=5062, cli_port=2303)
            ice.start("--use-ice --stun-srv=198.51.100.40:3478 --use-turn --turn-srv=198.51.100.40:3478 --turn-user=turn --turn-passwd=pw-turn")
            wait_registrations({ice: 200})
            ice.call("301")
            wait_bridged(pbx, "301", "304")
            wait_hears(ice, [desk.tone])
            wait_hears(desk, [ice.tone])
            assert ice.count("ICE negotiation success") == 1
            candidates = received_with(ice, "a=candidate:")
            # the router's address from STUN, a relay on the TURN server, and the
            # addresses of the PBX's own interfaces
            for address, kind in [("198.51.100.10", "srflx"), ("198.51.100.40", "relay"), ("10.1.0.10", "host")]:
                assert any(re.search(rf" {re.escape(address)} \d+ typ {kind}\b", line) for line in candidates), (address, kind, candidates)
            ice.hangup()
            wait_idle(pbx)
      '';
  }
