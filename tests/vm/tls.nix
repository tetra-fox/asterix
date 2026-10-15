# A TLS transport and HTTPS whose certificate and key are root-only files,
# which reach Asterisk through credentials, and a renewed certificate served
# on both after a reload, without a restart.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  certificates = import ./certificates.nix {inherit pkgs;};
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-tls";

    nodes.pbx = let
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
        self.nixosModules.asterisk
        ./common.nix
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

        # HTTPS with the same certificate
        http = {
          enable = true;
          tls = {
            enable = true;
            inherit (files) certFile keyFile;
          };
        };

        pjsip.transports.tls = {
          protocol = "tls";
          port = 5061;
          # Asterisk's default method takes only TLS 1.0
          tls = files // {method = "sslv23";};
        };
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        def serial(port):
            """The serial number of the certificate served on `port`."""
            return pbx.succeed(
                f"openssl s_client -connect 127.0.0.1:{port} < /dev/null 2>/dev/null | openssl x509 -noout -serial"
            ).strip()

        with subtest("the TLS transport uses the root-only key through a credential"):
            pbx.succeed("ss -Hltn 'sport = :5061' | grep -q 5061")
            pbx.succeed("test \"$(stat -c '%U %a' /run/tls/key.pem)\" = 'root 400'")
            transport = asterisk(pbx, "pjsip show transport tls")
            assert "/run/credentials/asterisk.service/pjsip-tls-key" in transport, transport

        with subtest("a renewed certificate is served on SIP and HTTPS after a reload, without a restart"):
            sip, https = serial(5061), serial(8089)
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
            renewed = serial(5061)
            assert renewed != sip, (sip, renewed)
            assert serial(8089) == renewed
      '';
  }
