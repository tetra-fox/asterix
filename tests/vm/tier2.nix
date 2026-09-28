# Tier-2 typed options on a running Asterisk: voicemail with e-mail
# notification, AMI, ARI, CDR and CEL backends, ConfBridge profiles, queues,
# music on hold from a Nix-built directory and call features.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-tier2";

  nodes.pbx = {
    config,
    pkgs,
    ...
  }: let
    inherit (config.lib.asterisk) secret;

    # records every message Asterisk "sends", and the password an SMTP client
    # would read from its credential
    fakeSendmail = pkgs.writeShellScript "fake-sendmail" ''
      cat > "/var/lib/asterisk/sent-mail-$(date +%s%N).eml"
      cat "$CREDENTIALS_DIRECTORY/smtp-password" > /var/lib/asterisk/smtp-password-seen
    '';

    officeMusic = pkgs.linkFarm "office-moh" [
      {
        name = "hold.wav";
        path = "${config.services.asterisk.package}/var/lib/asterisk/moh/macroform-cold_day.wav";
      }
    ];
  in {
    imports = [
      self.nixosModules.default
      ./common.nix
      ./phone.nix
      (import ./secrets.nix {
        fixed = {
          sip-101 = "pw-101";
          vm-101 = "9876";
          ami = "ami-secret";
          ari = "ari-secret";
          smtp = "smtp-secret";
        };
      })
    ];

    environment.systemPackages = [
      pkgs.curl
      pkgs.sqlite
    ];

    services.asterisk = {
      enable = true;

      credentials.smtp-password = "/run/test-secrets/smtp";

      pjsip = {
        transports.udp = {};
        endpoints."101" = {
          context = "internal";
          auth.password = secret "/run/test-secrets/sip-101";
          mailboxes = ["101@default"];
        };
      };

      dialplan.contexts.internal.extensions = {
        "700" = [
          "Answer()"
          "VoiceMail(101@default,s)"
          "Hangup()"
        ];
        "800" = [
          "Answer()"
          "ConfBridge(800,board,chair)"
        ];
      };

      voicemail = {
        mailboxes."101" = {
          pin = secret "/run/test-secrets/vm-101";
          fullName = "Alice";
          email = "alice@example.org";
        };
        email = {
          command = "${fakeSendmail}";
          fromAddress = "pbx@example.org";
        };
      };

      confbridge = {
        bridges.board.maxMembers = 5;
        users.chair = {
          admin = true;
          marked = true;
        };
        menus.chair_menu."*1" = "toggle_mute";
      };

      queues.queues.support = {
        strategy = "rrmemory";
        timeout = 15;
        members = [
          "PJSIP/101"
          {
            interface = "PJSIP/102";
            penalty = 1;
            name = "Bob";
          }
        ];
      };

      musicOnHold.classes.office = {
        directory = officeMusic;
        sort = "alpha";
      };

      features = {
        featureMap.blindxfer = "#1";
        applications.monkeys = {
          dtmf = "*9";
          app = "Playback";
          args = "tt-monkeys";
        };
      };

      ami = {
        enable = true;
        users.monitor = {
          secret = secret "/run/test-secrets/ami";
          write = ["system"];
        };
      };

      http.enable = true;
      ari = {
        enable = true;
        users.app.password = secret "/run/test-secrets/ari";
      };

      cdr = {
        csv.enable = true;
        sqlite.enable = true;
      };
      cel = {
        enable = true;
        sqlite.enable = true;
      };
    };
  };

  testScript =
    builtins.readFile ./phone.py
    + ''
      pbx.wait_for_unit("asterisk.service")
      pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|Error loading module|declined to load'")

      def ami(username, secret):
          request = (
              f"Action: Login\\r\\nUsername: {username}\\r\\nSecret: {secret}\\r\\n\\r\\n"
              "Action: Ping\\r\\n\\r\\nAction: Logoff\\r\\n\\r\\n"
          )
          return pbx.succeed(
              "exec 3<>/dev/tcp/127.0.0.1/5038; "
              f"printf {shlex.quote(request)} >&3; timeout 5 cat <&3 || true"
          )

      with subtest("voicemail records a message and sends a notification"):
          assert "Alice" in asterisk(pbx, "voicemail show users")
          phone = Phone(pbx, "alice", "101", "pw-101", "127.0.0.1")
          phone.start()
          phone.wait_registered()
          phone.call("700")
          pbx.wait_until_succeeds("asterisk -rx 'core show channels' | grep -q 'VoiceMail'")
          pbx.sleep(8)
          phone.hangup()
          pbx.wait_until_succeeds("test -f /var/lib/asterisk/spool/voicemail/default/101/INBOX/msg0000.txt")
          pbx.wait_until_succeeds("ls /var/lib/asterisk/sent-mail-*.eml")
          mail = pbx.succeed("cat /var/lib/asterisk/sent-mail-*.eml")
          assert "alice@example.org" in mail and "pbx@example.org" in mail, mail[:2000]
          assert pbx.succeed("cat /var/lib/asterisk/smtp-password-seen").strip() == "smtp-secret"
          pbx.fail("grep -R 9876 /etc/asterisk/")

      with subtest("AMI accepts its user and rejects a wrong secret"):
          good = ami("monitor", "ami-secret")
          assert "Response: Success" in good and "Ping: Pong" in good, good
          bad = ami("monitor", "wrong")
          assert "Authentication failed" in bad, bad
          pbx.fail("ss -Hltn 'sport = :5038' | grep -v 127.0.0.1")

      with subtest("ARI accepts its user and rejects a wrong password"):
          info = pbx.succeed("curl -sf -u app:ari-secret http://127.0.0.1:8088/ari/asterisk/info")
          assert '"system"' in info, info
          status = pbx.succeed("curl -s -o /dev/null -w '%{http_code}' -u app:wrong http://127.0.0.1:8088/ari/asterisk/info")
          assert status.strip() == "401", status

      with subtest("CDR and CEL records are written"):
          pbx.wait_until_succeeds("grep -q '\"700\"' /var/log/asterisk/cdr-csv/Master.csv")
          pbx.wait_until_succeeds("sqlite3 /var/log/asterisk/master.db 'select dst from cdr' | grep -qx 700")
          # the fields of each event, not only the variables CEL sets
          start = pbx.succeed(
              "sqlite3 /var/log/asterisk/master.db "
              "\"select exten, context, channame, uniqueid, linkedid from cel where eventtype = 'CHAN_START'\""
          ).strip()
          assert re.fullmatch(r"700\|internal\|PJSIP/101-[0-9a-f]+\|[0-9.]+\|[0-9.]+", start), start
          answer = pbx.succeed("sqlite3 /var/log/asterisk/master.db \"select appname from cel where eventtype = 'ANSWER'\"")
          assert answer.strip() == "Answer", answer

      with subtest("conference profiles, queue, music on hold and features are loaded"):
          assert "board" in asterisk(pbx, "confbridge show profile bridges")
          assert "chair" in asterisk(pbx, "confbridge show profile users")
          assert "chair_menu" in asterisk(pbx, "confbridge show menus")
          queue = asterisk(pbx, "queue show support")
          assert "rrmemory" in queue and "PJSIP/101" in queue and "Bob" in queue, queue
          classes = asterisk(pbx, "moh show classes")
          assert "Class: office" in classes and "office-moh" in classes, classes
          assert "hold" in asterisk(pbx, "moh show files")
          features = asterisk(pbx, "features show")
          assert "#1" in features and "monkeys" in features, features
    '';
}
