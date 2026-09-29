# The sandbox does not break TLS, SRTP or realtime scheduling: a TLS
# transport whose certificate and key are root-only files, SRTP (SDES) media,
# Asterisk running with SCHED_RR, and a call over them. Each TLS method
# accepts the versions it names, and the client and Asterisk's log say why
# the others are refused; `sslv23` negotiates up to 1.3. With verifyServer,
# Asterisk connects only to a server with a valid certificate its CA list
# signed for that address and logs why it refuses the others, which a
# transport without it accepts. With verifyClient, it admits only phones with
# a certificate its CA list signed. A renewed certificate is served after a
# reload.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  certificates = import ./certificates.nix {inherit pkgs;};

  # the transports the test probes: name, port, TLS method (null is
  # Asterisk's own default) and the versions a client may connect with
  methods = [
    {
      name = "tls";
      port = 5061;
      method = "sslv23";
      accepts = ["tls1_2" "tls1_3"];
    }
    {
      name = "tlsv1";
      port = 5062;
      method = "tlsv1";
      accepts = ["tls1"];
    }
    {
      name = "tlsv1_1";
      port = 5063;
      method = "tlsv1_1";
      accepts = ["tls1_1"];
    }
    {
      name = "tlsv1_2";
      port = 5064;
      method = "tlsv1_2";
      accepts = ["tls1_2"];
    }
    {
      name = "tlsv1_3";
      port = 5065;
      method = "tlsv1_3";
      accepts = ["tls1_3"];
    }
    {
      name = "default-method";
      port = 5066;
      method = null;
      accepts = ["tls1"];
    }
  ];

  # SIP servers on the phones node that Asterisk connects to over TLS: the
  # certificate each presents and its TLS port (pjsua's SIP port + 1)
  servers = {
    good = {
      certificate = "phone";
      port = 5101;
    };
    self-signed = {
      certificate = "self-signed";
      port = 5111;
    };
    expired = {
      certificate = "expired";
      port = 5121;
    };
    wrong-host = {
      certificate = "wrong-host";
      port = 5131;
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-tls-realtime";

    nodes = {
      pbx = {config, ...}: let
        # a certificate from the test CA, readable by root only; run again to
        # renew it
        makeCertificate = pkgs.writeShellApplication {
          name = "make-test-certificate";
          runtimeInputs = [pkgs.openssl];
          text = ''
            install -d -m 0700 /run/tls
            openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
              -subj /CN=pbx -keyout /run/tls/key.pem |
              openssl x509 -req -CA ${certificates}/ca.pem -CAkey ${certificates}/ca.key -days 2 \
                -extfile <(echo "subjectAltName = DNS:pbx,IP:192.168.1.1") -out /run/tls/cert.pem
            chmod 0400 /run/tls/key.pem /run/tls/cert.pem
          '';
        };
        files = {
          certFile = "/run/tls/cert.pem";
          keyFile = "/run/tls/key.pem";
        };
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") ["101" "102" "103" "104" "105"]);
          })
        ];

        systemd.services.test-certificate = {
          wantedBy = ["multi-user.target"];
          before = ["asterisk.service"];
          requiredBy = ["asterisk.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe makeCertificate;
          };
        };
        environment.systemPackages = [
          makeCertificate
          pkgs.openssl
        ];

        services.asterisk = {
          enable = true;
          realtime = true;
          openFirewall = true;

          # HTTPS with the same certificate
          http = {
            enable = true;
            tls = {
              enable = true;
              inherit (files) certFile keyFile;
            };
          };

          pjsip = {
            transports =
              lib.listToAttrs (map (t:
                lib.nameValuePair t.name {
                  protocol = "tls";
                  inherit (t) port;
                  tls = files // {inherit (t) method;};
                })
              methods)
              // {
                # checks the certificate of each server it connects to
                verify = {
                  protocol = "tls";
                  port = 5067;
                  tls =
                    files
                    // {
                      caListFile = "${certificates}/ca.pem";
                      verifyServer = true;
                    };
                };
                # admits phones with a certificate from the test CA
                clientauth = {
                  protocol = "tls";
                  port = 5068;
                  tls =
                    files
                    // {
                      caListFile = "${certificates}/ca.pem";
                      verifyClient = true;
                    };
                };
              };

            endpoints =
              lib.genAttrs ["101" "102"] (extension: {
                context = "phones";
                transport = "tls";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
                settings.media_encryption = "sdes";
              })
              // lib.genAttrs ["103" "104" "105"] (extension: {
                context = "phones";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
              })
              // lib.mapAttrs (_: server: {
                context = "phones";
                transport = "verify";
                aor.contacts = ["sip:192.168.1.2:${toString server.port};transport=tls"];
              })
              servers
              // {
                # the self-signed server through a transport that does not check it
                unverified = {
                  context = "phones";
                  transport = "tls";
                  aor.contacts = ["sip:192.168.1.2:${toString servers.self-signed.port};transport=tls"];
                };
              };
          };

          dialplan.contexts.phones.extensions."_10X" = [
            "Dial(PJSIP/\${EXTEN},30)"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        environment.systemPackages = [pkgs.openssl];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        methods = json.loads('${builtins.toJSON methods}')
        servers = json.loads('${builtins.toJSON servers}')
        certificates = "${certificates}"

        start_all()
        pbx.wait_for_unit("asterisk.service")

        with subtest("asterisk runs with realtime priority"):
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            policy = pbx.succeed(f"chrt -p {pid}")
            assert "SCHED_RR" in policy, policy

        with subtest("the TLS transport uses the root-only key through a credential"):
            pbx.succeed("ss -Hltn 'sport = :5061' | grep -q 5061")
            pbx.succeed("test \"$(stat -c '%U %a' /run/tls/key.pem)\" = 'root 400'")
            transport = asterisk(pbx, "pjsip show transport tls")
            assert "/run/credentials/asterisk.service/pjsip-tls-key" in transport, transport

        with subtest("phones register over TLS and call each other with SRTP"):
            server = "pbx:5061;transport=tls"
            alice = Phone(phones, "alice", "101", "pw-101", server, sip_port=5070, cli_port=2300)
            bob = Phone(phones, "bob", "102", "pw-102", server, sip_port=5080, cli_port=2301)
            srtp = "--use-srtp=2 --srtp-secure=0"
            alice.start(f"{pjsua_tls(certificates, 'phone')} {srtp}")
            bob.start(f"{pjsua_tls(certificates, 'phone')} {srtp}")
            for extension in ["101", "102"]:
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -q ' {extension}/sip:.*;transport=TLS'")
            alice.call("102")
            print(wait_for_media_both_ways(pbx, [alice, bob]))
            bob.wait_confirmed(timeout=30)
            invite = bob.received("INVITE")[-1]
            assert "RTP/SAVP" in invite and "a=crypto:" in invite, invite
            alice.hangup()
            wait_idle(pbx)

        with subtest("each TLS method accepts the versions it names, and a refusal says why"):
            names = {"tls1": "TLSv1", "tls1_1": "TLSv1.1", "tls1_2": "TLSv1.2", "tls1_3": "TLSv1.3"}
            cursor = journal_cursor(pbx)
            refused = 0
            for transport in methods:
                for version, name in names.items():
                    # SECLEVEL=0 lets the client offer TLS 1.0 and 1.1
                    status, session = phones.execute(
                        f"openssl s_client -connect pbx:{transport['port']} -{version} -cipher DEFAULT@SECLEVEL=0 -brief < /dev/null 2>&1"
                    )
                    if version in transport["accepts"]:
                        assert status == 0 and f"Protocol version: {name}\n" in session, (transport, version, session)
                    else:
                        assert status != 0 and re.search("alert protocol version|unsupported protocol", session), (transport, version, session)
                        refused += 1
            # Asterisk logs the reason for each refusal too
            wait_journal(pbx, cursor, "SSL_ERROR_SSL \\(Handshake\\).*(unsupported protocol|wrong version number)", count=refused)
            # without a version, a client gets the highest one both support
            session = phones.succeed("openssl s_client -connect pbx:5061 -brief < /dev/null 2>&1")
            assert "Protocol version: TLSv1.3" in session, session

        with subtest("with verifyServer, asterisk connects only to a valid certificate for the server's address, and logs why not"):
            server_phones = {}
            for index, (name, server) in enumerate(servers.items()):
                server_phones[name] = Phone(phones, name, name, "none", "pbx", sip_port=server["port"] - 1, cli_port=2302 + index, register=False)
                server_phones[name].start(
                    f"--use-tls --tls-cert-file={certificates}/{server['certificate']}.pem --tls-privkey-file={certificates}/{server['certificate']}.key"
                )
                phones.wait_for_open_port(server["port"])
            cursor = journal_cursor(pbx)
            for name in [*servers, "unverified"]:
                asterisk(pbx, f"pjsip qualify {name}")
            for name, status in [("good", "Avail"), ("self-signed", "Unavail"), ("expired", "Unavail"), ("wrong-host", "Unavail"), ("unverified", "Avail")]:
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE ' {name}/sip:[^ ]+ +[^ ]+ +{status} '")
            for name, level, reason in [
                ("good", "NOTICE", "OK"),
                ("self-signed", "ERROR", "The certificate is untrusted"),
                ("expired", "ERROR", "The certificate has expired or not yet valid"),
                ("wrong-host", "ERROR", "The server identity does not match to any identities specified in the certificate"),
            ]:
                wait_journal(pbx, cursor, f"{level}.* Transport 'verify' to remote '192\\.168\\.1\\.2' - 192\\.168\\.1\\.2:{servers[name]['port']} - {reason}$")
            # nothing is sent over a connection verifyServer refuses
            assert server_phones["good"].requests("OPTIONS") > 0
            assert server_phones["expired"].requests("OPTIONS") == 0
            assert server_phones["wrong-host"].requests("OPTIONS") == 0
            # without verifyServer, Asterisk connects and says what it did not check
            wait_journal(pbx, cursor, f"NOTICE.* Transport 'tls' to remote '192\\.168\\.1\\.2' - 192\\.168\\.1\\.2:{servers['self-signed']['port']} - The certificate is untrusted$")

        with subtest("with verifyClient, only a phone with a certificate from the CA list registers"):
            server = "pbx:5068;transport=tls"
            trusted = Phone(phones, "trusted", "103", "pw-103", server, sip_port=5140, cli_port=2310)
            stranger = Phone(phones, "stranger", "104", "pw-104", server, sip_port=5150, cli_port=2311)
            anonymous = Phone(phones, "anonymous", "105", "pw-105", server, sip_port=5160, cli_port=2312)
            cursor = journal_cursor(pbx)
            trusted.start(pjsua_tls(certificates, "phone"))
            stranger.start(pjsua_tls(certificates, "self-signed"))
            anonymous.start(pjsua_tls(certificates))
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q ' 103/sip:'")
            # Asterisk closes the connection of a certificate it does not trust
            stranger.wait_registration_failed("registration failed, status=503")
            # and refuses a phone without one in the handshake, saying why
            pbx.wait_until_succeeds(
                "asterisk -rx 'pjsip show contacts' | grep -q ' 105/sip:' || "
                f"journalctl -u asterisk.service --after-cursor={shlex.quote(cursor)} | grep -q 'peer did not return a certificate'"
            )
            contacts = asterisk(pbx, "pjsip show contacts")
            assert " 104/sip:" not in contacts, contacts
            assert " 105/sip:" not in contacts, f"a phone without a certificate registered: {contacts}"
            anonymous.wait_registration_failed("registration failed, status=503 \\(ssl/tls alert handshake failure\\)")

        with subtest("a renewed certificate is served after a reload, without a restart"):
            def serial(host, port):
                return phones.succeed(
                    f"openssl s_client -connect {host}:{port} < /dev/null 2>/dev/null | openssl x509 -noout -serial"
                ).strip()

            def https_serial():
                return pbx.succeed(
                    "openssl s_client -connect 127.0.0.1:8089 < /dev/null 2>/dev/null | openssl x509 -noout -serial"
                ).strip()

            sip, https = serial("pbx", 5061), https_serial()
            assert sip == https, (sip, https)
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            cursor = journal_cursor(pbx)
            pbx.succeed("make-test-certificate")
            # what security.acme.certs.<name>.reloadServices does after a renewal
            pbx.succeed("systemctl reload asterisk.service")
            journal = journal_since(pbx, cursor)
            assert "asterisk-config: module reload res_pjsip.so" in journal, journal
            assert "asterisk-config: module reload http" in journal, journal
            assert pid == pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            renewed = serial("pbx", 5061)
            assert renewed != sip, (sip, renewed)
            assert https_serial() == renewed
      '';
  }
