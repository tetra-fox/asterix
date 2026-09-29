# Phones on UDP, TCP and TLS over IPv4 from a dual-stack machine and over
# IPv6 from a machine without IPv4, and on WebSocket (ws, wss) over both
# families, to a PBX that offers every transport on both families: its UDP,
# TCP and TLS transports come in pairs, one per family, and its HTTP server,
# which carries WebSocket, listens on `::` for both. The IPv6 UDP transport is
# bound to the PBX's address, which Asterisk can only bind once duplicate
# address detection is done with it. Some phones' endpoints are pinned to
# their transport. Every phone registers on its transport and family. The UDP,
# TCP and TLS phones each call a phone of the other family and are called by
# another, hear each other and are only given PBX addresses of their own
# family. The WebSocket phones are baresip, as pjsua has no WebSocket
# transport, and only register: over WebSocket, Asterisk offers the address
# of its default route in SDP, here QEMU's user network, and IPv4 to IPv6
# phones too.
#
#   VLAN 1  pbx      192.168.1.1, 2001:db8:1::1
#           phones   192.168.1.2  401 UDP, 402 TCP, 405 TLS, 407 ws, 409 wss
#           v6phone  2001:db8:1::3 only, 403 UDP, 404 TCP, 406 TLS, 408 ws, 410 wss
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  certificates = import ./certificates.nix {inherit pkgs;};

  extensions = map toString (lib.range 401 410);
  # extension -> the transport its endpoint is pinned to; the others have
  # none, so Asterisk picks the one that matches the contact
  pinned = {
    "404" = "tcp6";
    "406" = "tls6";
    "408" = "ws";
    "409" = "wss";
  };
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

          http = {
            enable = true;
            address = "::";
            openFirewall = true;
            tls = {
              enable = true;
              certFile = "${certificates}/pbx.pem";
              keyFile = "${certificates}/pbx.key";
            };
          };

          pjsip = {
            transports = let
              tls = {
                certFile = "${certificates}/pbx.pem";
                keyFile = "${certificates}/pbx.key";
              };
            in {
              udp = {};
              udp6.address = "2001:db8:1::1";
              tcp.protocol = "tcp";
              tcp6 = {
                protocol = "tcp";
                address = "::";
              };
              tls = {
                protocol = "tls";
                inherit tls;
              };
              tls6 = {
                protocol = "tls";
                address = "::";
                inherit tls;
              };
              ws.protocol = "ws";
              wss.protocol = "wss";
            };
            endpoints = lib.genAttrs extensions (extension: {
              context = "phones";
              transport = pinned.${extension} or null;
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          dialplan.contexts.phones.extensions."_4XX" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          ./baresip.nix
        ];
      };

      v6phone = {
        imports = [
          ./common.nix
          ./phone.nix
          ./baresip.nix
        ];
        # no IPv4 at all, so pjsua offers IPv6 media on its own calls too
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [];
        virtualisation.qemu.networkingOptions = lib.mkForce [];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        import ipaddress

        start_all()
        pbx.wait_for_unit("asterisk.service")

        certificates = "${certificates}"
        v4, v6 = "pbx", "[2001:db8:1::1]"
        pjsua = {
            "401": Phone(phones, "401", "401", "pw-401", v4, sip_port=5060, cli_port=2300),
            "402": Phone(phones, "402", "402", "pw-402", f"{v4};transport=tcp", sip_port=5061, cli_port=2301),
            "405": Phone(phones, "405", "405", "pw-405", f"{v4}:5061;transport=tls", sip_port=5070, cli_port=2302),
            "403": Phone(v6phone, "403", "403", "pw-403", v6, sip_port=5060, cli_port=2300),
            "404": Phone(v6phone, "404", "404", "pw-404", f"{v6};transport=tcp", sip_port=5080, cli_port=2301),
            "406": Phone(v6phone, "406", "406", "pw-406", f"{v6}:5061;transport=tls", sip_port=5100, cli_port=2302),
        }
        websocket = {
            "407": Baresip(phones, "407", "407", "pw-407", f"{v4}:8088;transport=ws", sip_port=5090, ctrl_port=4444),
            "409": Baresip(phones, "409", "409", "pw-409", f"{v4}:8089;transport=wss", sip_port=5100, ctrl_port=4445, ca_file=f"{certificates}/ca.pem"),
            "408": Baresip(v6phone, "408", "408", "pw-408", f"{v6}:8088;transport=ws", sip_port=5130, ctrl_port=4444),
            "410": Baresip(v6phone, "410", "410", "pw-410", f"{v6}:8089;transport=wss", sip_port=5140, ctrl_port=4445, ca_file=f"{certificates}/ca.pem"),
        }

        with subtest("asterisk listens on every transport and family"):
            udp = pbx.succeed("ss -Hlun 'sport = :5060'")
            assert "0.0.0.0:5060" in udp and "[2001:db8:1::1]:5060" in udp, udp
            for port in [5060, 5061]:
                tcp = pbx.succeed(f"ss -Hltn 'sport = :{port}'")
                assert f"0.0.0.0:{port}" in tcp and f"[::]:{port}" in tcp, tcp
            # the HTTP server's sockets take both families
            for port in [8088, 8089]:
                http = pbx.succeed(f"ss -Hltn 'sport = :{port}'")
                assert f"*:{port}" in http, http

        with subtest("each phone registers on its transport and family"):
            v6phone.wait_until_succeeds("ip -o address show dev eth1 to 2001:db8:1::3 -tentative | grep -q .")
            start_phones([pjsua[ext] for ext in ["401", "402", "403", "404"]])
            for ext in ["405", "406"]:
                pjsua[ext].start(pjsua_tls(certificates, "phone"))
            for phone in websocket.values():
                phone.start()
            wait_contacts(pbx, 10)
            # pjsua registers the connection it opened, and Asterisk marks a
            # contact on either WebSocket transport with transport=ws
            contacts = asterisk(pbx, "database show registrar/contact")
            for contact in [
                r"sip:401@192\.168\.1\.2:5060;ob",
                r"sip:402@192\.168\.1\.2:[0-9]+;transport=TCP;ob",
                r"sip:405@192\.168\.1\.2:[0-9]+;transport=TLS;ob",
                r"sip:407@192\.168\.1\.2:[0-9]+;transport=ws;[^\"]*",
                r"sip:409@192\.168\.1\.2:[0-9]+;transport=ws;[^\"]*",
                r"sip:403@\[2001:db8:1::3\]:5070;ob",
                r"sip:404@\[2001:db8:1::3\]:[0-9]+;transport=TCP;ob",
                r"sip:406@\[2001:db8:1::3\]:[0-9]+;transport=TLS;ob",
                r"sip:408@\[2001:db8:1::3\]:[0-9]+;transport=ws;[^\"]*",
                r"sip:410@\[2001:db8:1::3\]:[0-9]+;transport=ws;[^\"]*",
            ]:
                assert re.search(f'"uri":"{contact}"', contacts), (contact, contacts)
            # baresip logs the transport and family it registered over
            for ext, over in [("407", "WS/v4"), ("409", "WSS/v4"), ("408", "WS/v6"), ("410", "WSS/v6")]:
                websocket[ext].machine.succeed(f"grep -qF '{{0/{over}}} 200 OK' {websocket[ext].log}")

        def call_round(pairs):
            """Calls between (caller, callee) pairs at the same time: both
            hear each other, and the callee gets the ACK for its answer."""
            confirmed = {callee: pjsua[callee].confirmed() for _, callee in pairs}
            cli_parallel([(pjsua[caller], f"call new {pjsua[caller].uri(callee)}") for caller, callee in pairs])
            for caller, callee in pairs:
                wait_bridged(pbx, caller, callee)
                pjsua[callee].wait_confirmed(after=confirmed[callee], timeout=30)
                wait_hears(pjsua[caller], [pjsua[callee].tone])
                wait_hears(pjsua[callee], [pjsua[caller].tone])
            cli_parallel([(pjsua[caller], "call hangup_all") for caller, _ in pairs])
            wait_idle(pbx)

        with subtest("each UDP, TCP and TLS phone calls one of the other family"):
            call_round([("401", "403"), ("402", "404"), ("405", "406")])

        with subtest("each UDP, TCP and TLS phone is called by one of the other family"):
            call_round([("403", "402"), ("404", "405"), ("406", "401")])

        with subtest("each UDP, TCP and TLS phone is only given PBX addresses of its own family"):
            def pbx_addresses(phone):
                """(IP4 or IP6, address) of the Contact and the SDP o= and c=
                lines of what `phone` received, except REGISTER responses,
                whose Contact is the phone's own."""
                found = set()
                for message in re.findall(r"RX \d+ bytes (?:Request|Response) msg .*?\n--end msg--", phone.log_text(), re.S):
                    if re.search(r"^CSeq: \d+ REGISTER", message, re.M):
                        continue
                    for host in re.findall(r"^Contact: <sips?:(?:[^@>]*@)?(\[[^]]+\]|[^:;>]+)", message, re.M):
                        host = host.strip("[]")
                        try:
                            found.add((f"IP{ipaddress.ip_address(host).version}", host))
                        except ValueError:
                            found.add(("name", host))
                    found.update(re.findall(r"^[oc]=.* IN (IP[46]) (\S+)", message, re.M))
                return found

            for ext, address in [
                ("401", ("IP4", "192.168.1.1")),
                ("402", ("IP4", "192.168.1.1")),
                ("405", ("IP4", "192.168.1.1")),
                ("403", ("IP6", "2001:db8:1::1")),
                ("404", ("IP6", "2001:db8:1::1")),
                ("406", ("IP6", "2001:db8:1::1")),
            ]:
                found = pbx_addresses(pjsua[ext])
                assert found == {address}, (ext, found)
      '';
  }
