# The sandbox does not break TLS, SRTP or realtime scheduling: a TLS
# transport whose certificate and key are root-only files, SRTP (SDES) media,
# which Asterisk relays although both endpoints have directMedia, Asterisk
# running with SCHED_RR, and a call over them. A renewed certificate is
# served after a reload.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  certificates = import ./certificates.nix {inherit pkgs;};
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
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") ["101" "102"]);
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
            transports.tls = {
              protocol = "tls";
              port = 5061;
              # Asterisk's default method takes only TLS 1.0
              tls = files // {method = "sslv23";};
            };

            endpoints = lib.genAttrs ["101" "102"] (extension: {
              context = "phones";
              transport = "tls";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
              settings.media_encryption = "sdes";
              # Asterisk relays encrypted media all the same
              directMedia = true;
            });
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
            # directMedia would have re-invited both to each other
            assert (alice.requests("INVITE"), bob.requests("INVITE")) == (0, 1)
            alice.hangup()
            wait_idle(pbx)

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
