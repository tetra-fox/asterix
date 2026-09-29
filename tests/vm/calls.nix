# Calls between phones, which hear each other: busy, unanswered and
# unreachable callees send the caller to voicemail with the matching greeting,
# a message reaches an SMTP server with its recording attached and reads back
# in every format, the mailbox owner learns about the message, hears it and
# deletes it after entering a PIN from a secret as DTMF, records a busy
# greeting callers then hear but cannot change the PIN, a message stops at
# maxSeconds and a full mailbox takes none, a hint lights a busy lamp, a ring
# group cancels the phones that did not answer, one extension rings on two
# devices, call forwarding is kept in astdb across a restart, a ringing call
# is picked up from another phone, an IVR reads RFC 4733 and SIP INFO DTMF, a
# call survives a lossy network, codecs with different sample rates are
# transcoded, a call is recorded to the spool, and a baresip phone calls a
# pjsua one. Registrations get the status Asterisk documents: a wrong password
# or user, an aor that takes none, a device past maxContacts refused or
# replacing the contact that expires soonest, qualify on and off, a refresh,
# an unregistration and an expiry.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # extension -> caller ID name; 209 never registers, 212 is baresip
  names = {
    "201" = "Anna";
    "202" = "Ben";
    "203" = "Cara";
    "204" = "Dan";
    "205" = "Eve";
    "206" = "Finn";
    "207" = "Gus";
    "208" = "Hana";
    "209" = "Ivy";
    "210" = "Jo";
    "211" = "Kim";
    "212" = "Lou";
  };

  # extension -> aor of the endpoints only the registration subtests use.
  # minimum_expiration lets a phone ask for 10 second registrations, which
  # it refreshes every 5 seconds
  registrationAors = {
    "213".maxContacts = 0;
    # the typed defaults: one contact, which a new device takes over
    "214".settings.minimum_expiration = 10;
    "215".removeExisting = false;
    "216" = {
      qualifyFrequency = 0;
      settings.minimum_expiration = 10;
    };
    "217".maxContacts = 2;
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
              // lib.mapAttrs' (extension: _: lib.nameValuePair "sip-${extension}" "pw-${extension}") registrationAors;
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
            endpoints = lib.mkMerge [
              (lib.mapAttrs (extension: name: {
                  context = "office";
                  callerId = ''"${name}" <${extension}>'';
                  auth.password = secret "/run/test-secrets/sip-${extension}";
                  mailboxes = ["${extension}@default"];
                })
                names)
              (lib.mapAttrs (extension: aor: {
                  context = "office";
                  auth.password = secret "/run/test-secrets/sip-${extension}";
                  inherit aor;
                })
                registrationAors)
              {
                "207".allow = ["alaw"];
                "208".allow = ["g722"];
                # a desk phone and a softphone
                "210".aor.maxContacts = 2;
                "211".dtmfMode = "info";
              }
            ];
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
            # 10 formats, the most Asterisk takes: each format module and codec
            # the default modules load, and two of the sln rates
            format = ["wav49" "wav" "wav16" "gsm" "ulaw" "alaw" "g722" "au" "sln" "sln16"];
            maxMessages = 1;
            maxSeconds = 5;
            email = {
              command = "${pkgs.msmtp}/bin/msmtp --read-envelope-from -t";
              fromAddress = "voicemail@example.org";
            };
          };
          # `file convert` reads stored messages back
          modules.load = ["res_convert.so"];

          dialplan.contexts = {
            office = {
              hints = lib.mapAttrs (extension: _: "PJSIP/${extension}") names;
              extensions = {
                "_2XX" = [
                  "GotoIf(\${DB_EXISTS(forward/\${EXTEN})}?forward)"
                  "Dial(PJSIP/\${EXTEN},10)"
                  "Verbose(1,dialstatus \${EXTEN} \${DIALSTATUS})"
                  "GotoIf($[\"\${DIALSTATUS}\" = \"BUSY\"]?busy)"
                  "VoiceMail(\${EXTEN}@default,u)"
                  "Hangup()"
                  {
                    label = "busy";
                    app = "VoiceMail";
                    args = [
                      "\${EXTEN}@default"
                      "b"
                    ];
                  }
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
                # PJSIP/210 alone would only ring one of the two devices
                "210" = [
                  "Dial(\${PJSIP_DIAL_CONTACTS(210)},20)"
                  "Hangup()"
                ];
                # ring group
                "600" = [
                  "Dial(PJSIP/204&PJSIP/206,20)"
                  "Hangup()"
                ];
                "500" = ["Goto(ivr,s,1)"];
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
                # *8 and an extension answer that extension's ringing call
                "_*8X." = [
                  "Pickup(\${EXTEN:2}@office)"
                  "Hangup()"
                ];
                "*97" = [
                  "Answer()"
                  "VoiceMailMain(\${CALLERID(num)}@default)"
                  "Hangup()"
                ];
              };
            };

            ivr.extensions = {
              s = [
                "Answer()"
                "Background(demo-instruct)"
                "WaitExten(10)"
              ];
              "1" = [
                "Dial(PJSIP/202,20)"
                "Hangup()"
              ];
              i = [
                "Playback(invalid)"
                "Goto(s,1)"
              ];
              t = ["Hangup()"];
            };
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          ./baresip.nix
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

        answers = {"203": 486, "204": 180, "205": 180}
        registered = ["201", "202", "203", "204", "205", "206", "207", "208", "211"]
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i, auto_answer=answers.get(ext, 200))
            for i, ext in enumerate(registered)
        }
        # 210 on a desk phone that answers and a softphone that only rings
        desk = Phone(phones, "210-desk", "210", "pw-210", "pbx", sip_port=5080, cli_port=2320)
        mobile = Phone(phones, "210-mobile", "210", "pw-210", "pbx", sip_port=5081, cli_port=2321, auto_answer=180)

        def leave_message(caller, callee, status, greeting):
            """Call `callee`, who does not pick up, and leave a message after the greeting."""
            cursor = journal_cursor(pbx)
            caller.call(callee)
            wait_journal(pbx, cursor, f"dialstatus {callee} {status}")
            wait_journal(pbx, cursor, f"Playing '{greeting}\\.")
            wait_journal(pbx, cursor, "Playing 'beep\\.")
            time.sleep(3)
            caller.hangup()
            pbx.wait_until_succeeds(f"test -f /var/lib/asterisk/spool/voicemail/default/{callee}/INBOX/msg0000.txt")
            wait_idle(pbx)

        def assert_tone(path, tone):
            """Asterisk reads the audio file `path` back as `tone`, too loud to
            count as silence."""
            converted = "/var/lib/asterisk/spool/tmp/check.sln"
            answer = asterisk(pbx, f"file convert {path} {converted}")
            assert "Converted" in answer, answer
            raw = base64.b64decode(pbx.succeed(f"base64 -w0 {converted}"))
            windows = tones_in(numpy.frombuffer(raw, dtype="<i2").astype(float), 8000)
            # the first and last 100 ms hold the start and the end of the tone.
            # GSM adds weaker tones beside it, so the loudest is the one to check.
            inner = windows[1:-1]
            assert len(inner) >= 20 and all(window and abs(window[0] - tone) <= TOLERANCE for window in inner), f"{path}: {windows}"

        with subtest("phones register"):
            start_phones(list(phone.values()) + [desk, mobile])
            # 209 is not registered, 210 is registered twice
            wait_contacts(pbx, 11)
            # a busy lamp for 202 on 201
            phone["201"].watch("202")

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

        with subtest("a busy callee's voicemail plays the busy greeting"):
            leave_message(phone["201"], "203", "BUSY", "vm-isonphone")

        with subtest("unanswered and unregistered callees' voicemail plays the unavailable greeting"):
            leave_message(phone["201"], "204", "NOANSWER", "vm-isunavail")
            leave_message(phone["201"], "209", "CHANUNAVAIL", "vm-isunavail")

        with subtest("the message reaches an SMTP server with the recording attached"):
            mail.wait_until_succeeds("test $(ls /var/lib/smtp-sink/maildir/new | wc -l) -eq 1", timeout=60)
            message = email.message_from_string(mail.succeed("cat /var/lib/smtp-sink/maildir/new/*"))
            assert message["X-MailFrom"] == "voicemail@example.org", message
            assert message["X-RcptTo"] == "ivy@example.org", message
            # the first format, wav49, is attached, and stored as .WAV
            attachment = next(part for part in message.walk() if part.get_filename() == "msg0000.WAV")
            recording = pbx.succeed("base64 -w0 /var/lib/asterisk/spool/voicemail/default/209/INBOX/msg0000.WAV")
            assert attachment.get_payload(decode=True) == base64.b64decode(recording)

        with subtest("the message reads back in every format as the caller's tone"):
            stored = "/var/lib/asterisk/spool/voicemail/default/209/INBOX/msg0000"
            for extension in ["WAV", "wav", "wav16", "gsm", "ulaw", "alaw", "g722", "au", "sln", "sln16"]:
                assert_tone(f"{stored}.{extension}", phone["201"].tone)
            # the rates of the sln format beyond one configuration's 10 formats,
            # written from the stored message by the same module
            # TODO: add sln44 once Asterisk keeps the level of 44.1 kHz audio; its
            # copy of the speex resampler halves it (codecs/speex/resample.c:478)
            for extension in ["sln12", "sln24", "sln32", "sln48", "sln96", "sln192"]:
                copy = f"/var/lib/asterisk/spool/tmp/copy.{extension}"
                answer = asterisk(pbx, f"file convert {stored}.sln16 {copy}")
                assert "Converted" in answer, answer
                assert_tone(copy, phone["201"].tone)

        with subtest("the mailbox owner is notified and deletes the message after entering the PIN"):
            cara = phone["203"]
            # unsolicited NOTIFY: the endpoint lists the mailbox
            cara.wait_count("Messages-Waiting: yes", 1)
            cleared = cara.count("Messages-Waiting: no")
            cursor = journal_cursor(pbx)
            cara.call("*97")
            wait_journal(pbx, cursor, "Playing 'vm-password\\.")
            cara.dtmf("0000#")
            wait_journal(pbx, cursor, "Playing 'vm-incorrect\\.")
            # digits sent while the error message plays are dropped
            wait_journal(pbx, cursor, "Playing 'vm-password\\.", count=2)
            cara.dtmf("9203#")
            wait_journal(pbx, cursor, "Playing 'vm-youhave\\.")
            cara.dtmf("1")
            wait_journal(pbx, cursor, "Playing '/var/lib/asterisk/spool/voicemail/default/203/INBOX/msg0000\\.")
            # Anna left it
            wait_hears(cara, [phone["201"].tone])
            cara.dtmf("7")
            wait_journal(pbx, cursor, "Playing 'vm-deleted\\.")
            cara.hangup()
            cara.wait_count("Messages-Waiting: no", cleared + 1)
            pbx.fail("test -f /var/lib/asterisk/spool/voicemail/default/203/INBOX/msg0000.txt")
            wait_idle(pbx)

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

        with subtest("a caller hears the busy greeting the owner recorded, and a message stops at maxSeconds"):
            ben = phone["202"]
            cursor = journal_cursor(pbx)
            disconnects = ben.disconnects()
            ben.call("203")
            wait_journal(pbx, cursor, "Playing '/var/lib/asterisk/spool/voicemail/default/203/busy\\.")
            wait_hears(ben, [phone["203"].tone])
            # pound skips the instructions after the greeting
            wait_journal(pbx, cursor, "Playing 'vm-intro\\.")
            ben.dtmf("#")
            wait_journal(pbx, cursor, "Playing 'beep\\.")
            # Ben's phone goes on sending its tone until Asterisk ends the message and the call
            wait_journal(pbx, cursor, "Took too long, cutting it short")
            ben.wait_disconnected(after=disconnects)
            wait_idle(pbx)
            info = pbx.succeed("cat /var/lib/asterisk/spool/voicemail/default/203/INBOX/msg0000.txt")
            # Asterisk compares whole seconds of the clock, so it stops up to a second late
            assert re.search("^duration=[56]$", info, re.M), info

        with subtest("a full mailbox takes no message"):
            ben = phone["202"]
            cursor = journal_cursor(pbx)
            ben.call("209")
            wait_journal(pbx, cursor, "Playing 'vm-isunavail\\.")
            # pound skips the instructions after the greeting
            ben.dtmf("#")
            # the message from the unregistered callee's subtest fills maxMessages
            wait_journal(pbx, cursor, "Playing 'vm-mailboxfull\\.")
            wait_idle(pbx)
            pbx.fail("test -e /var/lib/asterisk/spool/voicemail/default/209/INBOX/msg0001.txt")

        with subtest("a phone watching a hint sees the extension busy"):
            anna = phone["201"]
            anna.wait_count("<note>Ready</note>", 1)
            busy = anna.count("<note>On the phone</note>")
            phone["211"].call("202")
            wait_bridged(pbx, "211", "202")
            anna.wait_count("<note>On the phone</note>", busy + 1)
            phone["211"].hangup()
            wait_idle(pbx)

        with subtest("a ring group rings every member and cancels the rest when one answers"):
            dan = phone["204"]
            invites, cancels = dan.requests("INVITE"), dan.requests("CANCEL")
            phone["201"].call("600")
            wait_bridged(pbx, "201", "206")
            dan.wait_request("CANCEL", after=cancels)
            assert dan.requests("INVITE") > invites
            phone["201"].hangup()
            wait_idle(pbx)

        with subtest("one extension rings on both of its devices"):
            invites = {device.name: device.requests("INVITE") for device in (desk, mobile)}
            cancels = mobile.requests("CANCEL")
            phone["202"].call("210")
            wait_bridged(pbx, "202", "210")
            for device in (desk, mobile):
                device.wait_request("INVITE", after=invites[device.name])
            mobile.wait_request("CANCEL", after=cancels)
            phone["202"].hangup()
            wait_idle(pbx)

        with subtest("call forwarding is kept in astdb, also across a restart"):
            ben = phone["202"]
            ben.call("*72206")
            pbx.wait_until_succeeds("asterisk -rx 'database get forward 202' | grep -q 'Value: 206'")
            wait_idle(pbx)
            pbx.succeed("systemctl restart asterisk.service")
            pbx.wait_for_unit("asterisk.service")
            assert "Value: 206" in asterisk(pbx, "database get forward 202")
            # the contacts are restored from astdb as well
            wait_contacts(pbx, 11)
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

        with subtest("a ringing call is picked up from another phone"):
            eve = phone["205"]
            cancels = eve.requests("CANCEL")
            phone["201"].call("205")
            wait_channel(pbx, "205", state="Ringing")
            phone["202"].call("*8205")
            wait_bridged(pbx, "201", "202")
            eve.wait_request("CANCEL", after=cancels)
            phone["201"].hangup()
            wait_idle(pbx)

        with subtest("an IVR reads RFC 4733 and SIP INFO DTMF"):
            for caller, send in [(phone["201"], phone["201"].dtmf), (phone["211"], phone["211"].dtmf_info)]:
                caller.call("500")
                wait_channel(pbx, caller.user, app="BackGround")
                send("1")
                wait_bridged(pbx, caller.user, "202")
                caller.hangup()
                wait_idle(pbx)

        with subtest("a call survives loss and delay on the phones' network"):
            # both ways: netem only shapes what leaves an interface
            for machine in (pbx, phones):
                netem(machine, "eth1", "delay", "150ms", "20ms", "loss", "10%")
            phone["201"].call("202")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [phone["201"], phone["202"]])
            phone["201"].hangup()
            wait_idle(pbx)
            for machine in (pbx, phones):
                netem(machine, "eth1")

        with subtest("phones without a common codec are transcoded, 8 kHz to 16 kHz"):
            phone["207"].call("208")
            wait_bridged(pbx, "207", "208")
            stats = wait_for_media_both_ways(pbx, [phone["207"], phone["208"]])
            codecs = {endpoint_of(channel): s["codec"] for channel, s in stats.items()}
            assert codecs == {"207": "alaw", "208": "g722"}, codecs
            wait_hears(phone["207"], [phone["208"].tone])
            wait_hears(phone["208"], [phone["207"].tone])
            phone["207"].hangup()
            wait_idle(pbx)

        with subtest("a recorded call is written to the spool"):
            phone["201"].call("700")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [phone["201"], phone["202"]], minimum=150)
            phone["201"].hangup()
            wait_idle(pbx)
            # 16-bit samples at 8 kHz: 3 seconds are about 48 kB
            pbx.succeed("find /var/lib/asterisk/spool/monitor -name 'call-*.wav' -size +20k | grep -q .")

        with subtest("a phone on another SIP stack and a pjsua phone hear each other"):
            lou = Baresip(phones, "212", "212", "pw-212", "pbx")
            lou.start()
            lou.wait_registered()
            lou.call("201")
            wait_bridged(pbx, "212", "201")
            wait_hears(lou, [phone["201"].tone])
            wait_hears(phone["201"], [lou.tone])
            lou.hangup()
            wait_idle(pbx)

        with subtest("registrations get the status Asterisk documents for their credentials and aor"):
            cursor = journal_cursor(pbx)
            wrong = Phone(phones, "214-wrong", "214", "not-the-password", "pbx", sip_port=5100, cli_port=2330)
            stranger = Phone(phones, "299", "299", "pw-299", "pbx", sip_port=5101, cli_port=2331)
            closed = Phone(phones, "213", "213", "pw-213", "pbx", sip_port=5102, cli_port=2332)
            first = Phone(phones, "215-first", "215", "pw-215", "pbx", sip_port=5103, cli_port=2333)
            old = Phone(phones, "214-old", "214", "pw-214", "pbx", sip_port=5104, cli_port=2334)
            lasting = Phone(phones, "217-lasting", "217", "pw-217", "pbx", sip_port=5105, cli_port=2335)
            quiet = Phone(phones, "216", "216", "pw-216", "pbx", sip_port=5106, cli_port=2336)
            start_phones([wrong, stranger, closed, first, old])
            lasting.start("--reg-timeout=3600")
            quiet.start("--reg-timeout=10")
            # refused credentials get a 401 after the challenge, an unknown user too
            wait_registrations({wrong: 401, stranger: 401, closed: 403, first: 200, old: 200, lasting: 200, quiet: 200})
            # one device too many on 215 and on 214, and 217's second one
            second = Phone(phones, "215-second", "215", "pw-215", "pbx", sip_port=5107, cli_port=2337)
            brief = Phone(phones, "217-brief", "217", "pw-217", "pbx", sip_port=5108, cli_port=2338)
            new = Phone(phones, "214-new", "214", "pw-214", "pbx", sip_port=5109, cli_port=2339)
            start_phones([second, brief])
            new.start("--reg-timeout=10")
            wait_registrations({second: 403, brief: 200, new: 200})
            for line in [
                r"from '<sip:214@pbx>' failed for '[0-9.]+:5100' .* - Failed to authenticate",
                r"from '<sip:299@pbx>' failed for '[0-9.]+:5101' .* - No matching endpoint found",
                r"AOR '213' has no configured max_contacts",
                r"endpoint '215' \([0-9.]+:5107\) to AOR '215' will exceed max contacts of 1",
                r"Removed contact 'sip:214@[0-9.]+:5104;ob' from AOR '214' due to remove existing",
                r"Added contact 'sip:214@[0-9.]+:5109;ob' to AOR '214' with expiration of 10 seconds",
                r"Added contact 'sip:216@[0-9.]+:5106;ob' to AOR '216' with expiration of 10 seconds",
            ]:
                wait_journal(pbx, cursor, line)
            for holder in (first, new, lasting, brief, desk, mobile):
                assert holder.contact_status(pbx), f"{holder.name} holds no contact"
            for refused in (wrong, closed, second, old):
                assert refused.contact_status(pbx) is None, f"{refused.name} holds a contact"
            # 215 does not take a restarted phone for one device too many: its
            # Contact is the same, so the registration updates it
            first.stop()
            again = Phone(phones, "215-again", "215", "pw-215", "pbx", sip_port=first.sip_port, cli_port=2341)
            again.start()
            wait_registrations({again: 200})
            assert again.contact_status(pbx)

        with subtest("a device past maxContacts replaces the contact that expires soonest, not the oldest"):
            # lasting registered first for an hour, brief after it for 300 seconds
            cursor = journal_cursor(pbx)
            third = Phone(phones, "217-third", "217", "pw-217", "pbx", sip_port=5110, cli_port=2340)
            third.start()
            wait_registrations({third: 200})
            wait_journal(pbx, cursor, r"Removed contact 'sip:217@[0-9.]+:5108;ob' from AOR '217' due to remove existing")
            assert lasting.contact_status(pbx) and third.contact_status(pbx)
            assert brief.contact_status(pbx) is None

        with subtest("a qualified contact answers OPTIONS and is available, an unqualified one is never qualified"):
            # Asterisk qualifies a new contact at once, and only an answered
            # OPTIONS makes it Avail. quiet registered before new.
            retry(lambda _: new.contact_status(pbx) == "Avail", timeout_seconds=30)
            assert quiet.contact_status(pbx) == "NonQual"

        with subtest("a phone refreshes and ends its registration, another goes away without ending it"):
            cursor = journal_cursor(pbx)
            # its last refresh was at most 5 seconds ago
            quiet.stop()
            assert quiet.contact_status(pbx) == "NonQual"
            # pjsua cannot unregister while a refresh is in progress, so do it
            # right after one, 5 seconds before the next
            refreshes = new.count(": registration success")
            new.wait_count(": registration success", refreshes + 1, timeout=30)
            new.cli("acc unreg")
            wait_journal(pbx, cursor, r"Removed contact 'sip:214@[0-9.]+:5109;ob' from AOR '214' due to request")
            assert new.contact_status(pbx) is None

        with subtest("the registration of the phone that went away expires"):
            retry(lambda _: quiet.contact_status(pbx) is None, timeout_seconds=30)
      '';
  }
