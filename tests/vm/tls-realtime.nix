# The sandbox does not break TLS, SRTP or realtime scheduling: a TLS
# transport whose certificate and key are root-only files, SRTP (SDES) media,
# Asterisk running with SCHED_RR, and a call over them.
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
    }: {
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

      # a self-signed certificate created at boot, readable by root only
      systemd.services.test-certificate = {
        wantedBy = ["multi-user.target"];
        before = ["asterisk.service"];
        requiredBy = ["asterisk.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [pkgs.openssl];
        script = ''
          install -d -m 0700 /run/tls
          openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
            -subj /CN=pbx -addext subjectAltName=DNS:pbx,IP:192.168.1.1 \
            -keyout /run/tls/key.pem -out /run/tls/cert.pem
          chmod 0400 /run/tls/key.pem /run/tls/cert.pem
        '';
      };

      services.asterisk = {
        enable = true;
        realtime = true;
        openFirewall = true;

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
          print(wait_for_media_both_ways(pbx))
          invite = bob.received_invites()[-1]
          assert "RTP/SAVP" in invite and "a=crypto:" in invite, invite
          alice.hangup()
    '';
}
