# Voicemail on a running system: a message left for a busy phone lights the
# lamp of its mailbox's phone and reaches an SMTP server with its recording
# attached.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-calls";

  nodes = {
    pbx = {config, ...}: let
      inherit (config.lib.asterisk) secret;
    in {
      imports = [
        self.nixosModules.asterisk
        ./common.nix
        (import ./secrets.nix {
          fixed = {
            sip-201 = "pw-201";
            sip-203 = "pw-203";
            vm-203 = "9203";
          };
        })
      ];

      # voicemail e-mails go to the mail node
      programs.msmtp = {
        enable = true;
        accounts.default = {
          host = "mail";
          port = 25;
          auth = false;
          tls = false;
        };
      };

      services.asterisk = {
        enable = true;
        openFirewall = true;

        # the test follows calls through verbose messages in the journal
        logger.channels.console = [
          "notice"
          "warning"
          "error"
          "verbose"
        ];
        settings."asterisk.conf".options.verbose = 3;

        pjsip = {
          transports.udp = {};
          endpoints = {
            "201" = {
              context = "office";
              auth.password = secret "/run/test-secrets/sip-201";
            };
            "203" = {
              context = "office";
              auth.password = secret "/run/test-secrets/sip-203";
              mailboxes = ["203@default"];
            };
          };
        };

        voicemail = {
          mailboxes."203" = {
            fullName = "Cara";
            pin = secret "/run/test-secrets/vm-203";
            email = "cara@example.org";
          };
          email = {
            command = "${pkgs.msmtp}/bin/msmtp --read-envelope-from -t";
            fromAddress = "voicemail@example.org";
          };
        };

        dialplan.contexts.office.extensions."_2XX" = [
          "Dial(PJSIP/\${EXTEN},10)"
          "VoiceMail(\${EXTEN}@default,u)"
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

    # an SMTP server that keeps every message it receives in a Maildir
    mail = {
      imports = [./common.nix];
      networking.firewall.allowedTCPPorts = [25];
      systemd.services.smtp-sink = {
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          # Python's mailbox module creates a Maildir's subdirectories only
          # along with the Maildir itself, so it cannot be the state directory
          ExecStart = "${pkgs.python3Packages.aiosmtpd}/bin/aiosmtpd --nosetuid --listen 0.0.0.0:25 --class aiosmtpd.handlers.Mailbox /var/lib/smtp-sink/maildir";
          StateDirectory = "smtp-sink";
        };
      };
    };
  };

  testScript =
    builtins.readFile ./phone.py
    + ''
      import base64
      import email

      start_all()
      pbx.wait_for_unit("asterisk.service")
      mail.wait_for_open_port(25)

      caller = Phone(phones, "201", "201", "pw-201", "pbx", sip_port=5060, cli_port=2300)
      # answers busy, so its calls go to its mailbox
      owner = Phone(phones, "203", "203", "pw-203", "pbx", sip_port=5061, cli_port=2301, auto_answer=486)
      inbox = "/var/lib/asterisk/spool/voicemail/default/203/INBOX"

      with subtest("phones register"):
          start_phones([caller, owner])
          wait_contacts(pbx, 2)

      with subtest("a message lights the lamp of its mailbox's phone"):
          # a message after the beep, which hanging up saves
          cursor = journal_cursor(pbx)
          caller.call("203")
          wait_journal(pbx, cursor, "Playing 'beep\\.")
          time.sleep(3)
          caller.hangup()
          pbx.wait_until_succeeds(f"test -f {inbox}/msg0000.txt")
          owner.wait_count("Messages-Waiting: yes", 1)

      with subtest("the message reaches an SMTP server with the recording attached"):
          mail.wait_until_succeeds("test $(ls /var/lib/smtp-sink/maildir/new | wc -l) -eq 1", timeout=60)
          message = email.message_from_string(mail.succeed("cat /var/lib/smtp-sink/maildir/new/*"))
          assert message["X-MailFrom"] == "voicemail@example.org", message
          assert message["X-RcptTo"] == "cara@example.org", message
          # the first format, wav49, is attached, and stored as .WAV
          attachment = next(part for part in message.walk() if part.get_filename() == "msg0000.WAV")
          recording = pbx.succeed(f"base64 -w0 {inbox}/msg0000.WAV")
          assert attachment.get_payload(decode=True) == base64.b64decode(recording)
    '';
}
