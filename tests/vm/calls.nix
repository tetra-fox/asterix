# Calls between phones, which hear each other: busy, unanswered and
# unreachable callees send the caller to voicemail with the matching greeting,
# the mailbox owner learns about the message and deletes it after entering a
# PIN from a secret as DTMF, a hint lights a busy lamp, a ring group cancels
# the phones that did not answer, one extension rings on two devices, call
# forwarding is kept in astdb across a restart, a ringing call is picked up
# from another phone, an IVR reads RFC 4733 and SIP INFO DTMF, a call
# survives a lossy network, codecs with different sample rates are transcoded,
# a call is recorded to the spool, and a baresip phone calls a pjsua one
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
              names;
          })
        ];

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
              {
                "207".allow = ["alaw"];
                "208".allow = ["g722"];
                # a desk phone and a softphone
                "210".aor.maxContacts = 2;
                "211".dtmfMode = "info";
              }
            ];
          };

          voicemail.mailboxes =
            lib.mapAttrs (extension: name: {
              fullName = name;
              pin = secret "/run/test-secrets/vm-${extension}";
            })
            names;

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
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

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
            phone["201"].hangup()
            wait_idle(pbx)

        with subtest("a busy callee's voicemail plays the busy greeting"):
            leave_message(phone["201"], "203", "BUSY", "vm-isonphone")

        with subtest("unanswered and unregistered callees' voicemail plays the unavailable greeting"):
            leave_message(phone["201"], "204", "NOANSWER", "vm-isunavail")
            leave_message(phone["201"], "209", "CHANUNAVAIL", "vm-isunavail")

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
            cara.dtmf("7")
            wait_journal(pbx, cursor, "Playing 'vm-deleted\\.")
            cara.hangup()
            cara.wait_count("Messages-Waiting: no", cleared + 1)
            pbx.fail("test -f /var/lib/asterisk/spool/voicemail/default/203/INBOX/msg0000.txt")
            wait_idle(pbx)

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
      '';
  }
