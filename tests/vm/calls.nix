# Calls between phones, which hear each other: a message reaches an SMTP
# server with its recording attached, the mailbox owner's lamp lights within
# 2 s, also on a phone that subscribes to it, and stays lit across a restart,
# the owner records a busy greeting after entering a PIN from a secret as
# DTMF but cannot change the PIN, call forwarding is kept in astdb across a
# restart, and a call is recorded to the spool. The SIP ACL refuses a source
# and its contact rules a Contact, pairwise, with 403, calls as well.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # extension -> caller ID name; 209 never registers
  names = {
    "201" = "Anna";
    "202" = "Ben";
    "203" = "Cara";
    "204" = "Dan";
    "206" = "Finn";
    "209" = "Ivy";
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-calls";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              lib.concatMapAttrs (extension: _: {
                "sip-${extension}" = "pw-${extension}";
                "vm-${extension}" = "9${extension}";
              })
              names
              // {sip-218 = "pw-218";};
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
            # sources from the first half of the vlan, where every node is;
            # the phones' second address, 192.168.1.200, is a source outside
            # it but may be a Contact
            acls.lan = {
              deny = [
                "0.0.0.0/0.0.0.0"
                "::/0"
              ];
              permit = ["192.168.1.0/25"];
              contactDeny = [
                "0.0.0.0/0.0.0.0"
                "::/0"
              ];
              contactPermit = ["192.168.1.0/24"];
            };
            endpoints =
              lib.mapAttrs (extension: name: {
                context = "office";
                callerId = ''"${name}" <${extension}>'';
                auth.password = secret "/run/test-secrets/sip-${extension}";
                mailboxes = ["${extension}@default"];
              })
              names
              # the ACL subtest's phones
              // {
                "218" = {
                  context = "office";
                  auth.password = secret "/run/test-secrets/sip-218";
                };
              };
          };

          voicemail = {
            mailboxes = lib.mkMerge [
              (lib.mapAttrs (extension: name: {
                  fullName = name;
                  pin = secret "/run/test-secrets/vm-${extension}";
                })
                names)
              {"209".email = "ivy@example.org";}
            ];
            # the e-mail attaches the first format, and the test measures a
            # recording by its raw sln copy
            format = ["wav49" "sln"];
            email = {
              command = "${pkgs.msmtp}/bin/msmtp --read-envelope-from -t";
              fromAddress = "voicemail@example.org";
            };
          };

          dialplan.contexts.office.extensions = {
            "_2XX" = [
              "GotoIf(\${DB_EXISTS(forward/\${EXTEN})}?forward)"
              "Dial(PJSIP/\${EXTEN},10)"
              "VoiceMail(\${EXTEN}@default,u)"
              "Hangup()"
              {
                label = "forward";
                app = "Dial";
                args = [
                  "PJSIP/\${DB_RESULT}"
                  20
                ];
              }
              "Hangup()"
            ];
            "700" = [
              "MixMonitor(call-\${UNIQUEID}.wav)"
              "Dial(PJSIP/202,20)"
              "Hangup()"
            ];
            # *72 and an extension forward the caller's calls there, *73 stops it
            "_*72X." = [
              "Set(DB(forward/\${CALLERID(num)})=\${EXTEN:3})"
              "Playback(beep)"
              "Hangup()"
            ];
            "*73" = [
              "NoOp(\${DB_DELETE(forward/\${CALLERID(num)})})"
              "Playback(beep)"
              "Hangup()"
            ];
            "*97" = [
              "Answer()"
              "VoiceMailMain(\${CALLERID(num)}@default)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        # after the test's own address, which stays the one phones send from
        networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
          {
            address = "192.168.1.200";
            prefixLength = 24;
          }
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

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        import email

        start_all()
        pbx.wait_for_unit("asterisk.service")
        mail.wait_for_open_port(25)

        # callers reach the voicemail of 203, which is busy, and of 204, which rings
        answers = {"203": 486, "204": 180}
        # 204 subscribes to message-summary for its mailbox; Asterisk refuses
        # that with 404 (modules/pjsip.nix), so it gets the NOTIFYs it did not
        # ask for, like the others
        options = {"204": "--mwi"}
        registered = ["201", "202", "203", "204", "206"]
        phone = {
            ext: Phone(
                phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i,
                auto_answer=answers.get(ext, 200), options=options.get(ext, ""),
            )
            for i, ext in enumerate(registered)
        }

        def leave_message(caller, callee):
            """Call `callee`, who does not pick up, and leave a message after the
            beep. Returns when the caller hung up, which saves the message."""
            cursor = journal_cursor(pbx)
            caller.call(callee)
            wait_journal(pbx, cursor, "Playing 'beep\\.")
            time.sleep(3)
            bye = (r"\ABYE ", rf"^From: .*sip:{caller.user}@")
            byes = len(sip_times(pbx, *bye))
            caller.hangup()
            pbx.wait_until_succeeds(f"test -f /var/lib/asterisk/spool/voicemail/default/{callee}/INBOX/msg0000.txt")
            wait_idle(pbx)
            # its first copy, as one sent again comes later
            return sip_times(pbx, *bye)[byes]

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(registered))

        with subtest("the callee sees the caller's name and number, and they hear each other"):
            phone["201"].call("202")
            wait_bridged(pbx, "201", "202")
            invite = phone["202"].received("INVITE")[-1]
            assert 'From: "Anna" <sip:201@' in invite, invite
            print(wait_for_media_both_ways(pbx, [phone["201"], phone["202"]]))
            wait_hears(phone["201"], [phone["202"].tone])
            wait_hears(phone["202"], [phone["201"].tone])
            # the first half second, read while 201 goes on recording
            assert len(heard(phone["201"], 0, 16000)) == 5
            phone["201"].hangup()
            wait_idle(pbx)

        with subtest("a message lights the lamp of its mailbox's phone within 2 s, also of one that subscribes"):
            left = {callee: leave_message(phone["201"], callee) for callee in ("203", "204")}
            for owner in (phone["203"], phone["204"]):
                owner.wait_count("Messages-Waiting: yes", 1)
                within(2, left[owner.user], sip_times(pbx, rf"\ANOTIFY sip:{owner.user}@", "^Messages-Waiting: yes"))

        with subtest("the message reaches an SMTP server with the recording attached"):
            leave_message(phone["201"], "209")
            mail.wait_until_succeeds("test $(ls /var/lib/smtp-sink/maildir/new | wc -l) -eq 1", timeout=60)
            message = email.message_from_string(mail.succeed("cat /var/lib/smtp-sink/maildir/new/*"))
            assert message["X-MailFrom"] == "voicemail@example.org", message
            assert message["X-RcptTo"] == "ivy@example.org", message
            # the first format, wav49, is attached, and stored as .WAV
            attachment = next(part for part in message.walk() if part.get_filename() == "msg0000.WAV")
            recording = pbx.succeed("base64 -w0 /var/lib/asterisk/spool/voicemail/default/209/INBOX/msg0000.WAV")
            assert attachment.get_payload(decode=True) == base64.b64decode(recording)

        with subtest("the mailbox owner records a busy greeting, but cannot change the PIN"):
            cara = phone["203"]
            greeting = "/var/lib/asterisk/spool/voicemail/default/203/busy"
            cursor = journal_cursor(pbx)
            cara.call("*97")
            wait_journal(pbx, cursor, "Playing 'vm-password\\.")
            cara.dtmf("9203#")
            wait_journal(pbx, cursor, "Playing 'vm-youhave\\.")
            cara.dtmf("0")
            wait_journal(pbx, cursor, "Playing 'vm-options\\.")
            cara.dtmf("2")
            wait_journal(pbx, cursor, "Playing 'beep\\.")
            # 3 s of Cara's tone, in the raw 8 kHz copy
            pbx.wait_until_succeeds(f"test $(stat -c %s {greeting}.tmp.sln) -ge 48000")
            cara.dtmf("#")
            wait_journal(pbx, cursor, "Playing 'vm-review\\.")
            cara.dtmf("1")
            wait_journal(pbx, cursor, "Playing 'vm-msgsaved\\.")
            # back in the options, whose prompt takes digits again
            wait_journal(pbx, cursor, "Playing 'vm-options\\.", count=2)
            cursor = journal_cursor(pbx)
            cara.dtmf("5")
            # Asterisk cannot save a new PIN, and would drop one it took at the next reload
            wait_journal(pbx, cursor, "Playing 'vm-no\\.")
            cara.hangup()
            wait_idle(pbx)

        with subtest("call forwarding is kept in astdb, also across a restart"):
            ben = phone["202"]
            ben.call("*72206")
            pbx.wait_until_succeeds("asterisk -rx 'database get forward 202' | grep -q 'Value: 206'")
            wait_idle(pbx)
            lit = phone["204"].count("Messages-Waiting: yes")
            pbx.succeed("systemctl restart asterisk.service")
            pbx.wait_for_unit("asterisk.service")
            assert "Value: 206" in asterisk(pbx, "database get forward 202")
            # the contacts are restored from astdb as well
            wait_contacts(pbx, len(registered))
            invites = ben.requests("INVITE")
            phone["201"].call("202")
            wait_bridged(pbx, "201", "206")
            assert ben.requests("INVITE") == invites, "202 rang although its calls are forwarded"
            phone["201"].hangup()
            wait_idle(pbx)
            ben.call("*73")
            pbx.wait_until_succeeds("asterisk -rx 'database get forward 202' | grep -q 'not found'")
            wait_idle(pbx)
            phone["201"].call("202")
            wait_bridged(pbx, "201", "202")
            phone["201"].hangup()
            wait_idle(pbx)

        with subtest("the lamp of a mailbox with a message stays lit across the restart, also for a phone that subscribes"):
            # Asterisk tells every phone again once it started
            phone["204"].wait_count("Messages-Waiting: yes", lit + 1)
            out = [moment for moment in sip_times(pbx, r"\ANOTIFY sip:204@", "^Messages-Waiting: no") if moment > left["204"]]
            assert not out, f"204's lamp went out at {out}"

        with subtest("a recorded call is written to the spool"):
            phone["201"].call("700")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [phone["201"], phone["202"]], minimum=150)
            phone["201"].hangup()
            wait_idle(pbx)
            # 16-bit samples at 8 kHz: 3 seconds are about 48 kB
            pbx.succeed("find /var/lib/asterisk/spool/monitor -name 'call-*.wav' -size +20k | grep -q .")

        with subtest("the SIP ACL refuses a source and its contact rules a Contact, pairwise, with 403, a call as well"):
            cursor = journal_cursor(pbx)
            outer = "192.168.1.200"
            # (source, Contact): (permitted, permitted), (permitted, off the
            # vlan), (outside the SIP ACL, permitted) and (outside, off the vlan)
            inside = Phone(phones, "218-inside", "218", "pw-218", "pbx", sip_port=5111, cli_port=2342)
            hidden = Phone(phones, "218-hidden", "218", "pw-218", "pbx", sip_port=5112, cli_port=2343)
            outside = Phone(phones, "218-outside", "218", "pw-218", "pbx", sip_port=5113, cli_port=2344)
            nowhere = Phone(phones, "218-nowhere", "218", "pw-218", "pbx", sip_port=5114, cli_port=2345)
            # once registered, pjsua would replace a Contact other than the
            # address Asterisk sees it at
            inside.start(f"--contact=sip:218@{outer}:5111 --auto-update-nat=0")
            hidden.start("--contact=sip:218@10.99.0.5:5112")
            outside.start(f"--bound-addr={outer} --ip-addr={outer}")
            nowhere.start(f"--bound-addr={outer} --ip-addr={outer} --contact=sip:218@10.99.0.5:5114")
            wait_registrations({inside: 200, hidden: 403, outside: 403, nowhere: 403})
            assert inside.contact_status(pbx), "218-inside holds no contact"
            # the contact rules also refuse the calls of a phone they refused
            hidden.call("201")
            hidden.wait_disconnected()
            assert hidden.count(r"DISCONNECTED \[reason=403 ") == 1
            # the REGISTER and the INVITE
            wait_journal(pbx, cursor, r"SIP Contact ACL: Rejecting '10\.99\.0\.5'", count=2)
            # the SIP ACL goes first, so a Contact is not looked at
            for port in (5113, 5114):
                wait_journal(pbx, cursor, rf"Incoming SIP message from 192\.168\.1\.200:{port} did not pass ACL test")
      '';
  }
