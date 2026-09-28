# The sandbox does not break TLS, SRTP or realtime scheduling: a TLS
# transport whose certificate and key are root-only files, SRTP (SDES) media,
# Asterisk running with SCHED_RR, and a call over them. TLS is negotiated up
# to 1.3, and a renewed certificate is served after a reload.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-tls-realtime";

  nodes = {
    pbx = {
      config,
      lib,
      ...
    }: let
      # a self-signed certificate, readable by root only; run again to renew it
      makeCertificate = pkgs.writeShellApplication {
        name = "make-test-certificate";
        runtimeInputs = [pkgs.openssl];
        text = ''
          install -d -m 0700 /run/tls
          openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
            -subj /CN=pbx -addext subjectAltName=DNS:pbx,IP:192.168.1.1 \
            -keyout /run/tls/key.pem -out /run/tls/cert.pem
          chmod 0400 /run/tls/key.pem /run/tls/cert.pem
        '';
      };
    in {
      imports = [
        self.nixosModules.default
        ./common.nix
        (import ./secrets.nix {
          fixed = {
            sip-101 = "pw-101";
            sip-102 = "pw-102";
          };
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
            certFile = "/run/tls/cert.pem";
            keyFile = "/run/tls/key.pem";
          };
        };

        pjsip = {
          transports.tls = {
            protocol = "tls";
            tls = {
              certFile = "/run/tls/cert.pem";
              keyFile = "/run/tls/key.pem";
            };
          };
          endpoints = lib.genAttrs ["101" "102"] (extension: {
            context = "phones";
            transport = "tls";
            auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            settings.media_encryption = "sdes";
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
          certificate = pbx.succeed("cat /run/tls/cert.pem")
          phones.succeed(f"printf '%s' {shlex.quote(certificate)} > /tmp/ca.pem")
          tls = "--use-tls --tls-ca-file=/tmp/ca.pem --tls-verify-server --use-srtp=2 --srtp-secure=0"
          server = "pbx:5061;transport=tls"
          alice = Phone(phones, "alice", "101", "pw-101", server, sip_port=5070, cli_port=2300)
          bob = Phone(phones, "bob", "102", "pw-102", server, sip_port=5080, cli_port=2301)
          alice.start(tls)
          bob.start(tls)
          alice.wait_registered()
          bob.wait_registered()
          assert "transport=tls" in asterisk(pbx, "pjsip show contacts").lower()
          alice.call("102")
          print(wait_for_media_both_ways(pbx, [alice, bob]))
          invite = bob.received("INVITE")[-1]
          assert "RTP/SAVP" in invite and "a=crypto:" in invite, invite
          alice.hangup()

      with subtest("TLS is negotiated up to 1.3, and versions before 1.2 are refused"):
          # pjsua offers TLS 1.0 to 1.2 whatever its method, openssl offers 1.3
          session = phones.succeed("openssl s_client -connect pbx:5061 -brief < /dev/null 2>&1")
          assert "Protocol version: TLSv1.3" in session, session
          status, session = phones.execute(
              "openssl s_client -connect pbx:5061 -brief -tls1_1 -cipher DEFAULT@SECLEVEL=0 < /dev/null 2>&1"
          )
          assert status != 0 and "alert protocol version" in session, session

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
