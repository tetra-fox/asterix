# Transfers and parking: blind transfers by REFER from the phone to an
# extension, a ring group (the member who answers gets the call, the other
# stops ringing), a queue (music until the agent answers), voicemail (the
# message holds the caller's voice) and an outside number through a trunk; an
# attended transfer by REFER, with music on hold for the caller while the
# transferring phone consults; a blind transfer by DTMF feature code, and an
# attended one to an outside number that the transferring phone completes by
# hanging up; a call parked on 700 and picked up by dialing its parking space,
# and one parked on 750 that comes back to the phone that parked it when its
# 5 s run out. Wherever a call ends up with a phone, the caller and that phone
# hear each other. Busy lamp keys that subscribe to dialog state (RFC 4235)
# show an extension ringing, with its caller, and in a call, and a parking
# space holding a call, each within 2 s, and go out within 2 s.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # 304 is a second member of the ring group, which rings but never answers
  extensions = [
    "301"
    "302"
    "303"
    "304"
  ];

  # the outside number is a pjsua on the phones' machine that does not
  # register, and that the pbx calls through a trunk on this port
  carrierPort = 5099;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-transfers";

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions)
              // {
                vm-303 = "9303";
                trunk = "trunk-5551000";
              };
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
            endpoints = lib.genAttrs extensions (extension: {
              context = "office";
              auth.password = secret "/run/test-secrets/sip-${extension}";
            });
            trunks.carrier = {
              # Asterisk resolves SIP host names without /etc/hosts
              host = nodes.phones.networking.primaryIPAddress;
              port = carrierPort;
              username = "5551000";
              password = secret "/run/test-secrets/trunk";
              context = "office";
              register = false;
              # the phones send from the carrier's address too, so the address
              # does not tell the carrier apart
              matchProviderHost = false;
              # Asterisk skips a contact whose last qualify failed, and the
              # carrier starts after the pbx first qualifies it
              qualifyFrequency = 5;
            };
          };

          features = {
            featureMap = {
              blindxfer = "#1";
              atxfer = "*2";
            };
            general.transferdigittimeout = 3;
          };

          queues.queues.desk.members = ["PJSIP/303"];

          voicemail.mailboxes."303".pin = secret "/run/test-secrets/vm-303";

          # no typed option: 700 parks a call, 701 to 720 pick it up again
          modules.load = ["res_parking.so"];
          settings."res_parking.conf" = {
            default = {
              parkext = 700;
              parkpos = "701-720";
              context = "parkedcalls";
              # a hint for each space, for busy lamps
              parkinghints = true;
            };
            # a call parked on 750 rings the phone that parked it after 5 s
            brief = {
              parkext = 750;
              parkext_exclusive = true;
              parkpos = "751-759";
              context = "parkedcalls";
              parkingtime = 5;
              comebacktoorigin = true;
            };
          };

          dialplan.contexts.office = {
            includes = ["parkedcalls"];
            hints = lib.genAttrs extensions (extension: "PJSIP/${extension}");
            extensions = {
              # t: the called phone may transfer with the feature codes
              "_30X" = [
                "Dial(PJSIP/\${EXTEN},20,t)"
                "Hangup()"
              ];
              # ring group
              "310" = [
                "Dial(PJSIP/303&PJSIP/304,20)"
                "Hangup()"
              ];
              "320" = [
                "Queue(desk)"
                "Hangup()"
              ];
              # s: no instructions after the greeting
              "_*30X" = [
                "VoiceMail(\${EXTEN:1}@default,su)"
                "Hangup()"
              ];
              "_9X." = [
                "Dial(PJSIP/\${EXTEN:1}@carrier,30)"
                "Hangup()"
              ];
            };
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          ./sip-probe.nix
        ];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        import types
        import xml.etree.ElementTree as ElementTree

        PHONES = "${nodes.phones.networking.primaryIPAddress}"

        start_all()
        pbx.wait_for_unit("asterisk.service")

        caller, transferrer, target = (
            Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["301", "302", "303"])
        )
        ringer = Phone(phones, "304", "304", "pw-304", "pbx", sip_port=5063, cli_port=2303, auto_answer=180)
        carrier = Phone(phones, "carrier", "carrier", "none", "pbx", sip_port=${toString carrierPort}, cli_port=2399, register=False)

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def wait_runs(cursor, exten, app):
            """Wait until the caller's channel runs `app` at `exten` of the office context."""
            wait_journal(pbx, cursor, rf'Executing \[{re.escape(exten)}@office:1\] {app}\("PJSIP/301-')

        def transfer_from_callee(target_number):
            """Call 302 from 301, and have 302 transfer the call to `target_number` by REFER."""
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.transfer(target_number)

        DIALOG_INFO = {"d": "urn:ietf:params:xml:ns:dialog-info"}

        def lamp(extension):
            """What each NOTIFY for the busy lamp of `extension` said, without
            retransmissions: the state, direction and remote identity of its
            dialog. Each NOTIFY's version is one more than the last's."""
            shown, seen = [], set()
            for line in phones.succeed(f"cat /tmp/lamp-{extension}.json").splitlines():
                message = json.loads(line)
                cseq = dict(message["headers"]).get("CSeq")
                if message.get("method") != "NOTIFY" or cseq in seen:
                    continue
                seen.add(cseq)
                info = ElementTree.fromstring(message["body"])
                assert info.get("version") == str(len(shown)) and info.get("state") == "full", message["body"]
                assert info.get("entity", "").startswith(f"sip:{extension}@"), message["body"]
                (dialog,) = info.findall("d:dialog", DIALOG_INFO)
                remote = dialog.findtext("d:remote/d:identity", namespaces=DIALOG_INFO)
                shown.append((dialog.findtext("d:state", namespaces=DIALOG_INFO), dialog.get("direction"), remote))
            return shown

        def wait_lamp(extension, count):
            """Wait until the lamp of `extension` got `count` NOTIFYs, and return what they said."""
            deadline = time.time() + 30
            while len(shown := lamp(extension)) < count:
                assert time.time() < deadline, phones.succeed(f"cat /tmp/lamp-{extension}.json")
                time.sleep(0.5)
            return shown

        def lit(extension, state):
            """Capture times of the NOTIFYs the pbx sent with `state` for the lamp of `extension`."""
            return sip_times(pbx, r"\ANOTIFY ", rf'entity="sip:{extension}@', rf"<state>{state}</state>")

        def sent_by(phone, *patterns):
            """The SIP messages `phone` sent the pbx whose text matches each of
            `patterns`; pjsua's answers name no user in their Contact."""
            return [
                m for m in sip_messages(pbx)
                if m["source"] == f"{PHONES}:{phone.sip_port}" and all(re.search(p, m["text"], re.M) for p in patterns)
            ]

        IDLE = ("terminated", None, None)

        with subtest("phones register"):
            start_phones([caller, transferrer, target, ringer, carrier])
            # and the carrier's static contact, once it answers the pbx
            wait_contacts(pbx, 5)
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +carrier/sip:.* Avail'", timeout=30)

        with subtest("busy lamp keys on 303 subscribe to the dialog state of 302, 304 and parking space 701, and show each idle"):
            for extension in ["302", "304", "701"]:
                phones.succeed(
                    f"systemd-run --unit=lamp-{extension} --collect -E PATH sh -c "
                    + shlex.quote(f"sip-probe pbx SUBSCRIBE 303 pw-303 --to {extension} > /tmp/lamp-{extension}.json")
                )
            for extension in ["302", "304", "701"]:
                assert wait_lamp(extension, 1) == [IDLE], lamp(extension)

        with subtest("the lamp of a ringing extension shows who calls within 2 s, and goes out within 2 s of the caller giving up"):
            rang = len(sent_by(ringer, r"\ASIP/2\.0 180 "))
            caller.call("304")
            wait_channel(pbx, "304", state="Ringing")
            [early] = wait_lamp("304", 2)[1:]
            assert early[:2] == ("early", "recipient") and early[2].startswith("sip:301@"), early
            within(2, sent_by(ringer, r"\ASIP/2\.0 180 ")[rang]["time"], lit("304", "early"))
            caller.hangup()
            wait_idle(pbx)
            assert wait_lamp("304", 3)[2:] == [IDLE], lamp("304")
            within(2, sip_times(pbx, r"\ACANCEL sip:304@")[-1], lit("304", "terminated"))

        with subtest("blind transfer: the called phone sends the caller on with REFER, and its lamp shows the call within 2 s of its answer and goes out within 2 s of the REFER"):
            answers = (r"\ASIP/2\.0 200 ", r"^CSeq: \d+ INVITE")
            answered = len(sent_by(transferrer, *answers))
            ended = transferrer.disconnects()
            transfer_from_callee("303")
            wait_bridged(pbx, "301", "303")
            transferrer.wait_disconnected(after=ended)
            hear_each_other(caller, target)
            assert wait_lamp("302", 3)[1:] == [("confirmed", None, None), IDLE], lamp("302")
            within(2, sent_by(transferrer, *answers)[answered]["time"], lit("302", "confirmed"))
            # the transfer takes 302's channel out of the call, before 302's BYE
            within(2, sent_by(transferrer, r"\AREFER ")[-1]["time"], lit("302", "terminated"))
            caller.hangup()
            wait_idle(pbx)

        with subtest("a blind transfer to a ring group stays with the member who answers, and the other stops ringing"):
            cursor = journal_cursor(pbx)
            cancels = ringer.requests("CANCEL")
            transfer_from_callee("310")
            wait_runs(cursor, "310", "Dial")
            wait_bridged(pbx, "301", "303")
            ringer.wait_request("CANCEL", after=cancels)
            hear_each_other(caller, target)
            caller.hangup()
            wait_idle(pbx)

        with subtest("a blind transfer to a queue plays music to the caller until the agent answers"):
            cursor = journal_cursor(pbx)
            transfer_from_callee("320")
            wait_runs(cursor, "320", "Queue")
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/301-")
            wait_bridged(pbx, "301", "303")
            hear_each_other(caller, target)
            caller.hangup()
            wait_idle(pbx)

        with subtest("a blind transfer to voicemail greets the caller and records its message"):
            cursor = journal_cursor(pbx)
            transfer_from_callee("*303")
            wait_runs(cursor, "*303", "VoiceMail")
            wait_journal(pbx, cursor, "<PJSIP/301-[0-9a-f]+> Playing 'vm-isunavail\\.")
            wait_journal(pbx, cursor, "<PJSIP/301-[0-9a-f]+> Playing 'beep\\.")
            # two seconds of the message: 16 bit samples at 8 kHz after the header
            pbx.wait_until_succeeds("test $(cat /var/lib/asterisk/spool/voicemail/default/303/tmp/*.wav | wc -c) -ge 32044")
            caller.hangup()
            wait_idle(pbx)
            # the message, read like a phone's recording
            message = types.SimpleNamespace(machine=pbx, recording="/var/lib/asterisk/spool/voicemail/default/303/INBOX/msg0000.wav")
            windows = heard(message, 0)
            assert sum(same(window, [caller.tone]) for window in windows) >= 10, windows

        with subtest("a blind transfer to an outside number calls it through the trunk"):
            cursor = journal_cursor(pbx)
            invites = carrier.requests("INVITE")
            transfer_from_callee("95550123")
            wait_runs(cursor, "95550123", "Dial")
            wait_bridged(pbx, "301", "carrier")
            carrier.wait_request("INVITE", after=invites)
            # without the 9 that leads to the trunk
            invite = carrier.received("INVITE")[-1]
            assert "INVITE sip:5550123@" in invite, invite
            hear_each_other(caller, carrier)
            caller.hangup()
            wait_idle(pbx)

        with subtest("attended transfer: the caller hears music on hold until it is handed over"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            held = transferrer.current_call()
            transferrer.hold()
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/301-")
            transferrer.call("303")
            wait_bridged(pbx, "302", "303")
            transferrer.transfer_replaces(held)
            wait_bridged(pbx, "301", "303")
            wait_journal(pbx, cursor, "Stopped music on hold on PJSIP/301-")
            pbx.wait_until_fails("asterisk -rx 'core show channels concise' | grep -q '^PJSIP/302-'")
            hear_each_other(caller, target)
            caller.hangup()
            wait_idle(pbx)

        with subtest("blind transfer by DTMF feature code"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.dtmf("#1")
            wait_journal(pbx, cursor, "Playing 'pbx-transfer\\.")
            transferrer.dtmf("303")
            wait_bridged(pbx, "301", "303")
            hear_each_other(caller, target)
            caller.hangup()
            wait_idle(pbx)

        with subtest("attended transfer by DTMF: the called phone consults an outside number and hangs up to hand the caller over"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.dtmf("*2")
            wait_journal(pbx, cursor, "Playing 'pbx-transfer\\.")
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/301-")
            # the number could go on, so Asterisk dials it after transferdigittimeout
            transferrer.dtmf("95550123")
            hear_each_other(transferrer, carrier)
            transferrer.hangup()
            wait_bridged(pbx, "301", "carrier")
            wait_journal(pbx, cursor, "Stopped music on hold on PJSIP/301-")
            hear_each_other(caller, carrier)
            caller.hangup()
            wait_idle(pbx)

        with subtest("a call transferred to the parking extension is picked up from its space, whose lamp shows the call within 2 s of the transfer and goes out within 2 s of the pickup"):
            cursor = journal_cursor(pbx)
            transfer_from_callee("700")
            wait_journal(pbx, cursor, "Parking 'PJSIP/301-[0-9a-f]+' in 'default' at space 701")
            assert wait_lamp("701", 2)[1:] == [("confirmed", None, None)], lamp("701")
            within(2, sip_times(pbx, r"\AREFER ", r"^Refer-To: <?sip:700@")[-1], lit("701", "confirmed"))
            target.call("701")
            wait_bridged(pbx, "301", "303")
            hear_each_other(caller, target)
            assert wait_lamp("701", 3)[2:] == [IDLE], lamp("701")
            # the second INVITE, which answers the pbx's challenge
            within(2, sip_times(pbx, r"\AINVITE sip:701@")[-1], lit("701", "terminated"))
            caller.hangup()
            wait_idle(pbx)

        with subtest("a call parked on 750 that nobody picks up rings the phone that parked it after 5 s"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            parked = time.time()
            transferrer.transfer("750")
            wait_journal(pbx, cursor, "Parking 'PJSIP/301-[0-9a-f]+' in 'brief' at space 751")
            wait_journal(pbx, cursor, 'Executing \\[PJSIP_302@park-dial:1\\] Dial\\("PJSIP/301-')
            # after the lot's 5 s, not the 45 s res_parking has by default
            waited = time.time() - parked
            assert 5 <= waited < 30, waited
            wait_bridged(pbx, "301", "302")
            hear_each_other(caller, transferrer)
            caller.hangup()
            wait_idle(pbx)
      '';
  }
