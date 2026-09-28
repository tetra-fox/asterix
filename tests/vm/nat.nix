# NAT on both ends of a call. The office PBX sits behind a router that
# forwards SIP and RTP to it (its transport has the router's public address as
# external address and the office LAN as local network); a softphone at home
# sits behind a router that masquerades it and advertises its private address
# (`behindNat` on its endpoint). Calls between it and a desk phone in the
# office have audio both ways, each phone is only given PBX addresses it can
# reach, and hanging up at home ends the call in the office.
#
#   office LAN  VLAN 1  10.1.0.0/24      pbx .10, deskphone .21, officerouter .1
#   internet    VLAN 2  198.51.100.0/24  officerouter .10, homerouter .20
#   home LAN    VLAN 3  192.168.1.0/24   homerouter .1, remote .50
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
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-nat";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = {
              sip-301 = "pw-301";
              sip-302 = "pw-302";
            };
          })
          (address "lan" "10.1.0.10")
          (internetVia "lan" "10.1.0.1")
        ];
        virtualisation.interfaces.lan.vlan = 1;

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {
              externalSignalingAddress = "198.51.100.10";
              externalMediaAddress = "198.51.100.10";
              localNet = ["10.1.0.0/24"];
            };
            endpoints = {
              # desk phone in the office
              "301" = {
                context = "office";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-301";
              };
              # softphone at home
              "302" = {
                context = "office";
                behindNat = true;
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-302";
              };
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
      };

      remote = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "192.168.1.50")
          (internetVia "eth1" "192.168.1.1")
        ];
        virtualisation.vlans = [3];
      };

      deskphone = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.1.0.21")
        ];
        virtualisation.vlans = [1];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        # the firewall service sets up NAT and port forwarding
        for router in [officerouter, homerouter]:
            router.wait_for_unit("firewall.service")
        for machine, gateway in [(pbx, "10.1.0.1"), (remote, "192.168.1.1")]:
            machine.wait_until_succeeds(f"ip route show 198.51.100.0/24 | grep -q 'via {gateway}'")
        deskphone.wait_until_succeeds("ip -o address show to 10.1.0.21 | grep -q .")

        desk = Phone(deskphone, "301", "301", "pw-301", "10.1.0.10", sip_port=5060, cli_port=2300)
        home = Phone(remote, "302", "302", "pw-302", "198.51.100.10", sip_port=5060, cli_port=2300)

        def header(message, name):
            """Values of a SIP header, or of an SDP line such as `c`, in a message."""
            return [
                line[len(name) + 1 :].strip()
                for line in message.splitlines()
                if line.startswith(f"{name}:") or line.startswith(f"{name}=")
            ]

        with subtest("the phone at home registers through both routers"):
            desk.start()
            # no help from the phone: it keeps its private address in Contact and SDP
            home.start("--auto-update-nat=0")
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
            assert all("198.51.100.10" in value for value in header(invite, "Via") + header(invite, "Contact")), invite
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
      '';
  }
