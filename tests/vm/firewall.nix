# openFirewall on a running system, read from the firewall's ruleset and
# probed on the wire. One PBX has the iptables firewall and opens, on one
# interface only, typed UDP transports with their TCP listeners, TCP and TLS
# ones, a UDP port below 1024 and its TCP listener, freeform ones (a protocol
# in capitals, one inheriting from a template, an IPv6 one), AMI on a port
# settings chose and HTTP and HTTPS with their own openFirewall, and its RTP
# range. The other has the nftables firewall and opens its transports and RTP
# range on every interface, but neither AMI nor HTTP, which it runs without
# their openFirewall. The rulesets hold exactly these ports, for IPv4 and
# IPv6. A prober on both networks finds them open
# (answering or refusing) and every other port dropped: every port of each
# PBX's first address, over TCP and UDP, and the ports of either PBX and
# their neighbours on the other addresses. Each PBX also relaxes the sandbox
# in one way: the port below 1024 gives the first CAP_NET_BIND_SERVICE,
# the second runs with realtime scheduling, and each relaxation adds only its
# own items to what systemd-analyze counts against the unit.
#
#   VLAN 1  iptables 192.168.1.1  nftables 192.168.1.2  prober 192.168.1.3  (2001:db8:1::N)
#   VLAN 2  iptables 192.168.2.1  nftables 192.168.2.2  prober 192.168.2.3  (2001:db8:2::N)
{
  pkgs,
  self,
}: let
  certificates = import ./certificates.nix {inherit pkgs;};
  tls = {
    certFile = "${certificates}/pbx.pem";
    keyFile = "${certificates}/pbx.key";
  };

  # what each PBX opens, on which interfaces
  opened = {
    iptables = {
      interfaces = ["eth1"];
      tcp = [506 5039 5060 5061 5070 5090 5100 8088 8089];
      udp = [506 5060 5080 5110];
      rtp = {
        from = 10000;
        to = 10019;
      };
    };
    nftables = {
      interfaces = [
        "eth1"
        "eth2"
      ];
      tcp = [5060 5070];
      udp = [5060];
      rtp = {
        from = 20000;
        to = 20019;
      };
    };
  };

  pbx = {
    imports = [
      self.nixosModules.default
      ./common.nix
    ];
    virtualisation.vlans = [
      1
      2
    ];
    # a closed UDP port answers every probe with an ICMP error, instead of
    # one a second per prober
    boot.kernel.sysctl = {
      "net.ipv4.icmp_ratelimit" = 0;
      "net.ipv6.icmp.ratelimit" = 0;
    };
    services.asterisk = {
      enable = true;
      openFirewall = true;
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-firewall";

    nodes = {
      iptables = {
        imports = [pbx];
        services.asterisk = {
          firewallInterfaces = ["eth1"];
          pjsip.transports = {
            udp = {};
            low.port = 506;
            tcp = {
              protocol = "tcp";
              port = 5070;
            };
            tls = {
              protocol = "tls";
              inherit tls;
            };
          };
          settings."pjsip.conf" = {
            udp-freeform = {
              type = "transport";
              protocol = "udp";
              bind = "0.0.0.0:5080";
            };
            # Asterisk reads the protocol in any case
            capitals = {
              type = "transport";
              protocol = "TCP";
              bind = "0.0.0.0:5090";
            };
            stream = {
              template = true;
              type = "transport";
              protocol = "tcp";
            };
            inherited = {
              inherits = ["stream"];
              bind = "0.0.0.0:5100";
            };
            udp6 = {
              type = "transport";
              protocol = "udp";
              bind = "[::]:5110";
            };
          };
          ami = {
            enable = true;
            openFirewall = true;
            settings.port = 5039;
          };
          http = {
            enable = true;
            openFirewall = true;
            tls =
              tls
              // {
                enable = true;
              };
          };
          rtp.portRange = opened.iptables.rtp;
        };
      };

      nftables = {
        imports = [pbx];
        networking.nftables.enable = true;
        services.asterisk = {
          # the other relaxation of the sandbox
          realtime = true;
          pjsip.transports.udp = {};
          settings."pjsip.conf".tcp6 = {
            type = "transport";
            protocol = "tcp";
            bind = "[::]:5070";
          };
          ami.enable = true;
          http.enable = true;
          rtp.portRange = opened.nftables.rtp;
        };
      };

      prober = {
        imports = [./common.nix];
        virtualisation.vlans = [
          1
          2
        ];
        networking.firewall.enable = false;
        environment.systemPackages = [pkgs.nmap];
      };
    };

    testScript = ''
      import json
      import re

      opened = json.loads('${builtins.toJSON opened}')
      pbxs = {"iptables": iptables, "nftables": nftables}
      number = {"iptables": 1, "nftables": 2}

      def expected(name, protocol):
          ports = set(opened[name][protocol])
          if protocol == "udp":
              ports |= set(range(opened[name]["rtp"]["from"], opened[name]["rtp"]["to"] + 1))
          return ports

      def addresses(name, interface):
          vlan = interface.removeprefix("eth")
          return [f"192.168.{vlan}.{number[name]}", f"2001:db8:{vlan}::{number[name]}"]

      # a SIP OPTIONS request, which Asterisk answers on every UDP port it
      # listens on; rport sends the answer to the port nmap sent it from
      options = (
          "OPTIONS sip:probe@pbx SIP/2.0\r\n"
          "Via: SIP/2.0/UDP prober:5060;rport;branch=z9hG4bK-probe\r\n"
          "Max-Forwards: 70\r\n"
          "From: <sip:probe@prober>;tag=probe\r\n"
          "To: <sip:probe@pbx>\r\n"
          "Call-ID: probe@prober\r\n"
          "CSeq: 1 OPTIONS\r\n"
          "Content-Length: 0\r\n\r\n"
      ).encode().hex()

      def answering(address, protocol, ports, retries=1, rate="--min-rate 20000"):
          """Ports of `ports` (nmap's -p syntax) at `address` that answer,
          with a connection or a refusal, so the firewall lets them in."""
          flags = "-sS" if protocol == "tcp" else f"-sU --data {options}"
          family = "-6" if ":" in address else ""
          output = prober.succeed(f"nmap {family} -n -Pn {flags} -p {ports} --max-retries {retries} {rate} -oG - {address}")
          found = set()
          for entry in re.findall(r"(\d+)/(\w[\w|]*)/(tcp|udp)/", output):
              if entry[1] in ("open", "closed"):
                  found.add(int(entry[0]))
          return found

      def wire(name, address, protocol, ports, want):
          """The ports of `ports` at `address` that the firewall lets in are
          `want`. A lost probe only hides a port, so a port found missing is
          asked again, slowly, before it counts."""
          found = answering(address, protocol, ports)
          missing = want - found
          if missing:
              found |= answering(address, protocol, ",".join(map(str, sorted(missing))), retries=6, rate="")
          assert found == want, (name, address, protocol, sorted(found - want), sorted(want - found))

      start_all()
      for node in [iptables, nftables]:
          node.wait_for_unit("asterisk.service")
      # IPv6 addresses answer once duplicate address detection is done
      for node in [iptables, nftables, prober]:
          node.wait_until_succeeds("test -z \"$(ip -6 address show tentative)\"")

      with subtest("the iptables ruleset opens the ports on eth1 only, for IPv4 and IPv6"):
          for command in ["iptables", "ip6tables"]:
              rules = set()
              for line in iptables.succeed(f"{command} -S nixos-fw").splitlines():
                  match = re.fullmatch(r"-A nixos-fw (?:-i (\S+) )?(?:-d (\S+) )?-p (tcp|udp) -m \3 --dport (\d+)(?::(\d+))? -j nixos-fw-accept", line)
                  if match:
                      interface, destination, protocol, start, end = match.groups()
                      rules.add((interface, destination, protocol, int(start), int(end or start)))
              want: set[tuple] = {("eth1", None, "tcp", port, port) for port in opened["iptables"]["tcp"]}
              want |= {("eth1", None, "udp", port, port) for port in opened["iptables"]["udp"]}
              want.add(("eth1", None, "udp", opened["iptables"]["rtp"]["from"], opened["iptables"]["rtp"]["to"]))
              if command == "ip6tables":
                  # the firewall's own rule for DHCPv6 replies
                  want.add((None, "fe80::/64", "udp", 546, 546))
              assert rules == want, (command, sorted(rules - want), sorted(want - rules))

      with subtest("the nftables ruleset opens the ports on every interface, for IPv4 and IPv6"):
          rules = set()
          for line in nftables.succeed("nft list chain inet nixos-fw input-allow").splitlines():
              match = re.fullmatch(r'\s*(?:iifname "?(\S+?)"? )?(tcp|udp) dport (?:\{ (.*) \}|(\S+)) accept', line)
              if match:
                  interface, protocol, elements, element = match.groups()
                  for part in (elements or element).split(", "):
                      start, _, end = part.partition("-")
                      rules.add((interface, protocol, int(start), int(end or start)))
          want = {(None, "tcp", port, port) for port in opened["nftables"]["tcp"]}
          want |= {(None, "udp", port, port) for port in opened["nftables"]["udp"]}
          want.add((None, "udp", opened["nftables"]["rtp"]["from"], opened["nftables"]["rtp"]["to"]))
          assert rules == want, (sorted(rules - want), sorted(want - rules))
          assert "elements" not in nftables.succeed("nft list set inet nixos-fw temp-ports")

      with subtest("the prober finds exactly these ports open on every address of the opened interfaces"):
          # every port on each PBX's first address
          for name in pbxs:
              address = addresses(name, "eth1")[0]
              for protocol in ["tcp", "udp"]:
                  wire(name, address, protocol, "-", expected(name, protocol))
          # the ports of both PBXs and their neighbours everywhere else
          nearby = set()
          for name in pbxs:
              for protocol in ["tcp", "udp"]:
                  for port in expected(name, protocol):
                      nearby |= {port - 1, port, port + 1}
          nearby |= {22, 80, 443, 546, 5038, 5039, 8088, 8089}
          ports = ",".join(map(str, sorted(nearby)))
          for name in pbxs:
              for interface in ["eth1", "eth2"]:
                  for address in addresses(name, interface):
                      for protocol in ["tcp", "udp"]:
                          want = expected(name, protocol) & nearby if interface in opened[name]["interfaces"] else set()
                          wire(name, address, protocol, ports, want)

      with subtest("each relaxation of the sandbox appears only where it is needed, and costs only its own items"):
          relaxed = {
              # a port below 1024
              "iptables": {
                  "CapabilityBoundingSet": "cap_net_bind_service",
                  "AmbientCapabilities": "cap_net_bind_service",
                  "RestrictRealtime": "yes",
                  "CPUSchedulingPolicy": "0",
                  "LimitRTPRIO": "0",
              },
              # realtime scheduling
              "nftables": {
                  "CapabilityBoundingSet": "",
                  "AmbientCapabilities": "",
                  "RestrictRealtime": "no",
                  "CPUSchedulingPolicy": "2",
                  "LimitRTPRIO": "10",
              },
          }
          exposed = {}
          for name, node in pbxs.items():
              properties = dict(
                  line.split("=", 1)
                  for line in node.succeed(f"systemctl show {' '.join('-p ' + p for p in relaxed[name])} asterisk.service").splitlines()
              )
              assert properties == relaxed[name], (name, properties)
              pid = node.succeed("systemctl show -P MainPID asterisk.service").strip()
              mask = "0000000000000400" if relaxed[name]["AmbientCapabilities"] else "0000000000000000"
              for field in ["CapEff", "CapBnd", "CapAmb"]:
                  node.succeed(f"grep -qx '{field}:\\s*{mask}' /proc/{pid}/status")
              # what systemd-analyze counts against the sandbox
              items = json.loads(node.succeed("systemd-analyze security --json=short asterisk.service"))
              exposed[name] = {item["name"] for item in items if item["set"] is False}
              print(name, node.succeed("systemd-analyze security asterisk.service").splitlines()[-1])
          iptables.succeed("ss -Hlun 'sport = :506' | grep -q 506")
          assert exposed["iptables"] - exposed["nftables"] == {
              "AmbientCapabilities=",
              "CapabilityBoundingSet=~CAP_NET_(BIND_SERVICE|BROADCAST|RAW)",
          }, exposed
          assert exposed["nftables"] - exposed["iptables"] == {"RestrictRealtime="}, exposed
    '';
  }
