# Calls whose SIP dialog changes after it starts, and both ends keep the same
# view of it: hold with sendonly (pjsua) and with inactive (SIPp) plays music
# to the other party, from a Nix-built directory and from the program of a
# custom class that runs in Asterisk's unit and sandbox, and nothing to the
# phone that holds, until the call is taken back; an UPDATE with a new offer;
# early media in a 183; reliable provisional responses (100rel) with PRACK on
# both legs; a 200 that crosses a CANCEL on either leg; re-INVITEs that cross
# (glare), each answered with 491, and the retry of the side that does not
# own the Call-ID; and session timers of 90 s refreshed by the phone on one
# leg and the pbx on the other, with the call going on past them. Each case
# checks the channels on the pbx, the phones' call state and the dialog in
# the capture at both ends, and that the call, where it goes on, is heard
# both ways.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # 507 calls 508 at the start and keeps the call for the whole test; the
  # others take part one case at a time
  extensions = map toString (lib.range 501 508);

  # held parties hear these tones instead of music, so a test can tell what
  # they hear: they are none of the phones' tones, nor half or twice one.
  # holdTone plays from files, streamTone from a program sox runs as the
  # custom class's application
  holdTone = 2500;
  holdMusic = pkgs.runCommand "hold-tone" {nativeBuildInputs = [pkgs.sox];} ''
    mkdir $out
    sox -n -r 8000 -b 16 -c 1 $out/tone.wav synth 5 sine ${toString holdTone} vol 0.05
  '';
  streamTone = 2900;
  # a sine without end, as signed linear audio at 8 kHz on standard output
  streamCommand = "${pkgs.sox}/bin/sox -q -n -r 8000 -c 1 -b 16 -e signed-integer -t raw - synth sine ${toString streamTone} vol 0.05";

  # SIPp calls in as the endpoint sipp from this port, and answers calls to
  # 590 as the endpoint uas on the next one
  sippPort = 5096;
  uasPort = 5097;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-dialogs";

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
              // {sip-sipp = "pw-sipp";};
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

          musicOnHold.classes = {
            default.directory = holdMusic;
            stream = {
              mode = "custom";
              application = streamCommand;
            };
          };

          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.genAttrs (extensions ++ ["sipp"]) (extension: {
                context = "dialogs";
                auth.password = secret "/run/test-secrets/sip-${extension}";
              }))
              # pjsua offers again to settle on one codec whenever an answer
              # lists several, also during hold. Any offer during hold makes
              # Asterisk bridge the held call's RTP natively again, so the held
              # party gets the holder's audio along with the music, and the
              # holder the other party's (res/res_pjsip_sdp_rtp.c:2338-2341,
              # bridges/bridge_native_rtp.c:590-596).
              # TODO: drop this once Asterisk keeps a held call out of it
              (lib.genAttrs extensions (_: {
                settings.preferred_codec_only = true;
              }))
              {
                # the pbx refreshes the session of calls to 508 every 45 s
                "508".settings.timers_sess_expires = 90;
                # the party SIPp holds hears the custom class
                sipp.settings.moh_suggest = "stream";
                uas = {
                  context = "dialogs";
                  aor = {
                    contacts = ["sip:uas@${nodes.phones.networking.primaryIPAddress}:${toString uasPort}"];
                    maxContacts = 0;
                    # SIPp takes nothing but the calls of its scenario
                    qualifyFrequency = 0;
                  };
                };
              }
            ];
          };

          dialplan.contexts.dialogs.extensions = {
            "_50X" = [
              "Dial(PJSIP/\${EXTEN},30)"
              "Hangup()"
            ];
            "590" = [
              "Dial(PJSIP/uas,30)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          ./sipp.nix
        ];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        HOLD_TONE = ${toString holdTone}
        STREAM_TONE = ${toString streamTone}
        PHONES = "${nodes.phones.networking.primaryIPAddress}"
        PBX_IP = "${nodes.pbx.networking.primaryIPAddress}"
        PBX = f"{PBX_IP}:5060"
        SIPP_UAC = f"{PHONES}:${toString sippPort}"
        SIPP_UAS = f"{PHONES}:${toString uasPort}"
        SIPP = ["-i", PHONES, "-mi", PHONES]

        start_all()
        pbx.wait_for_unit("asterisk.service")

        answers = {"504": 183, "506": 183}
        options = {
            "505": "--use-100rel",
            "506": "--use-100rel",
            "507": "--timer-se=90 --timer-min-se=90",
        }
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i, auto_answer=answers.get(ext, 200), options=options.get(ext, ""))
            for i, ext in enumerate(${builtins.toJSON extensions})
        }

        def at(p):
            return f"{PHONES}:{p.sip_port}"

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        def field(pattern, text):
            match = re.search(pattern, text, re.M)
            assert match, text
            return match.group(1)

        def call_id(message):
            return field(r"^Call-ID: (.*?)\r$", message["text"])

        def cseq(message):
            """The method of the message's CSeq."""
            return field(r"^CSeq: \d+ (\w+)\r$", message["text"])

        def direction(message):
            """The media direction of the message's SDP, None without SDP."""
            if "\r\n\r\nv=0" not in message["text"]:
                return None
            found = re.search(r"^a=(sendrecv|sendonly|recvonly|inactive)\r$", message["text"], re.M)
            return found.group(1) if found else "sendrecv"

        def summary(messages):
            """Each message as `sender > receiver: first line [direction]`."""
            return [
                f"{m['source']} > {m['destination']}: {m['text'].splitlines()[0]}" + (f" [{direction(m)}]" if direction(m) else "")
                for m in messages
            ]

        def leg(mark, address):
            """The messages of the first dialog between the pbx and `address`
            (host:port) after the first `mark` messages of the pbx's capture.
            The phones' machine has to have captured the same; a frame on its
            way between the two captures is in one of them for a moment."""
            deadline = time.time() + 5
            while True:
                at_pbx = sip_messages(pbx)
                first = next((m for m in at_pbx[mark:] if address in (m["source"], m["destination"])), None)
                assert first, f"no dialog with {address} after message {mark}"
                messages = [m for m in at_pbx if call_id(m) == call_id(first)]
                at_phones = [m for m in sip_messages(phones) if call_id(m) == call_id(first)]
                if summary(messages) == summary(at_phones):
                    return messages
                assert time.time() < deadline, (summary(messages), summary(at_phones))
                time.sleep(0.5)

        def sent(messages, sender, start, media=None):
            """The messages `sender` sent whose first line starts with `start`
            and, if `media` is given, whose SDP has that direction."""
            return [
                m for m in messages
                if m["source"] == sender and m["text"].startswith(start) and (media is None or direction(m) == media)
            ]

        def firsts(messages):
            """The messages without retransmissions, which repeat a message as
            it was. Asterisk answers each copy of an INVITE a phone sent again
            with a challenge of its own, which differs only in its nonce and
            opaque."""

            def plain(text):
                return re.sub(r'(nonce|opaque)="[^"]*"', r'\1=""', text)

            return [m for i, m in enumerate(messages) if not any(plain(earlier["text"]) == plain(m["text"]) for earlier in messages[:i])]

        def dialogue(messages, name):
            """Each message of a dialog as (who sent it: `name` or pbx, the
            request method or the response code and method, the direction of
            its SDP or None)."""
            found = []
            for m in firsts(messages):
                words = m["text"].split(" ", 2)
                what = f"{words[1]} {cseq(m)}" if words[0] == "SIP/2.0" else words[0]
                found.append(("pbx" if m["source"] == PBX else name, what, direction(m)))
            return found

        def calling(name):
            """How a phone's call to the pbx starts: the pbx challenges the
            first INVITE and takes the second."""
            return [
                (name, "INVITE", "sendrecv"), ("pbx", "401 INVITE", None), (name, "ACK", None),
                (name, "INVITE", "sendrecv"), ("pbx", "100 INVITE", None),
            ]

        def media(messages, sender):
            """host:port where `sender` takes RTP, from the last SDP it sent."""
            text = [m for m in messages if m["source"] == sender and direction(m)][-1]["text"]
            host = field(r"^c=IN IP4 (\S+)\r$", text)
            port = field(r"^m=audio (\d+) ", text)
            return f"{host}:{port}"

        def rtp_to(destination, start, end):
            """(SSRC, sequence number) of each RTP packet the pbx sent to
            `destination` between two times of its capture."""
            return [
                (p["ssrc"], p["sequence"])
                for p in rtp_packets(pbx)
                if p["source"].startswith(f"{PBX_IP}:") and p["destination"] == destination and start < p["time"] < end
            ]

        def one_stream(packets):
            """The packets make one RTP stream: one SSRC, each numbered after
            the one before."""
            return len({ssrc for ssrc, _ in packets}) == 1 and all((b - a) % 65536 == 1 for (_, a), (_, b) in zip(packets, packets[1:]))

        def check_hold(holding, holder, held_leg, held, answer):
            """While the call was held, the pbx sent the holder nothing and the
            held party one stream: the music. The pbx stops sending once it
            applied the answer it just sent, and the music takes over from
            the holder's audio a moment after that."""
            start = sent(holding, PBX, "SIP/2.0 200", answer)[0]["time"]
            end = sent(holding, holder, "INVITE", "sendrecv")[-1]["time"]
            assert not rtp_to(media(holding, holder), start + 0.1, end), "the pbx sent RTP to the phone that holds"
            music = rtp_to(media(held_leg, held), start + 0.5, end)
            assert len(music) >= 25 and one_stream(music), music

        def channel(endpoint):
            return next(c["name"] for c in channels(pbx) if endpoint_of(c["name"]) == endpoint)

        def wait_ended(*endpoints):
            """Wait until the pbx has no channel of `endpoints`; the call with
            session timers goes on meanwhile."""
            pbx.wait_until_succeeds(
                "! asterisk -rx 'core show channels concise' | grep -qE '^PJSIP/(" + "|".join(endpoints) + ")-'", timeout=60
            )

        def uas_listening():
            phones.wait_until_succeeds("ss -Hlun 'sport = :${toString uasPort}' | grep -q .")

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_registrations({p: 200 for p in phone.values()})

        with subtest("the custom class's program runs in Asterisk's unit, as its user and in its sandbox"):
            def confinement(pid):
                """The unit, user, mount namespace, seccomp mode and capabilities of a process."""
                status = dict(line.split(":\t", 1) for line in pbx.succeed(f"cat /proc/{pid}/status").splitlines())
                return {
                    "cgroup": pbx.succeed(f"cat /proc/{pid}/cgroup").strip(),
                    "mounts": pbx.succeed(f"readlink /proc/{pid}/ns/mnt").strip(),
                    **{key: status[key] for key in ["Uid", "Gid", "NoNewPrivs", "Seccomp", "CapEff", "CapBnd"]},
                }

            main = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            stream = pbx.succeed("pgrep -f 'synth sine ${toString streamTone}'").split()
            assert len(stream) == 1, stream
            confined = confinement(main)
            assert confined["cgroup"] == "0::/system.slice/asterisk.service" and confined["Seccomp"] == "2", confined
            assert confinement(stream[0]) == confined, (confinement(stream[0]), confined)

        with subtest("session timers: a call with sessions of 90 s starts, refreshed by the phone on one leg and by the pbx on the other"):
            timed_mark = len(sip_messages(pbx))
            phone["507"].call("508")
            wait_bridged(pbx, "507", "508")
            timed_start = time.time()
            hear_each_other(phone["507"], phone["508"])

        with subtest("hold with sendonly: the pbx answers recvonly and plays music to the other party, and nothing to the phone that holds, until the call is taken back"):
            holder, held = phone["501"], phone["502"]
            mark = len(sip_messages(pbx))
            holder.call("502")
            wait_bridged(pbx, "501", "502")
            hear_each_other(holder, held)
            cursor = journal_cursor(pbx)
            holder.hold()
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/502-")
            wait_hears(held, [HOLD_TONE])
            holder.cli("call reinvite")
            wait_journal(pbx, cursor, "Stopped music on hold on PJSIP/502-")
            hear_each_other(holder, held)
            wait_bridged(pbx, "501", "502")
            assert holder.count("status is Local hold") == 1 and held.count("status is Local hold") == 0
            ended = holder.disconnects(), held.disconnects()
            holder.hangup()
            holder.wait_disconnected(after=ended[0])
            held.wait_disconnected(after=ended[1])
            wait_ended("501", "502")
            holding = leg(mark, at(holder))
            assert dialogue(holding, "501") == calling("501") + [
                ("pbx", "200 INVITE", "sendrecv"), ("501", "ACK", None),
                ("501", "INVITE", "sendonly"), ("pbx", "200 INVITE", "recvonly"), ("501", "ACK", None),
                ("501", "INVITE", "sendrecv"), ("pbx", "200 INVITE", "sendrecv"), ("501", "ACK", None),
                ("501", "BYE", None), ("pbx", "200 BYE", None),
            ], summary(holding)
            assert dialogue(leg(mark, at(held)), "502") == [
                ("pbx", "INVITE", "sendrecv"), ("502", "100 INVITE", None), ("502", "200 INVITE", "sendrecv"), ("pbx", "ACK", None),
                ("pbx", "BYE", None), ("502", "200 BYE", None),
            ]
            check_hold(holding, at(holder), leg(mark, at(held)), at(held), "recvonly")

        with subtest("hold with inactive: the pbx answers inactive and plays the custom class SIPp's endpoint suggests to the other party, and nothing to the phone that holds, until the call is taken back"):
            held = phone["502"]
            mark = len(sip_messages(pbx))
            # the pbx answers late while SIPp calls and changes the call, and
            # some answers come after SIPp went on
            with stalled(pbx):
                sipp_start(phones, "hold-inactive", *SIPP, "-p", "${toString sippPort}", "-mp", "6000", "-rtp_echo", "-s", "502", "-au", "sipp", "-ap", "pw-sipp", PBX_IP)
                wait_bridged(pbx, "sipp", "502")
            # SIPp echoes what it gets
            wait_hears(held, [held.tone])
            cursor = journal_cursor(pbx)
            # each NOTIFY lets the scenario send its next re-INVITE
            with stalled(pbx):
                asterisk(pbx, f"pjsip send notify clear-mwi channel {channel('sipp')}")
                wait_journal(pbx, cursor, "Started music on hold, class 'stream', on channel 'PJSIP/502-")
            wait_hears(held, [STREAM_TONE])
            with stalled(pbx):
                asterisk(pbx, f"pjsip send notify clear-mwi channel {channel('sipp')}")
                wait_journal(pbx, cursor, "Stopped music on hold on PJSIP/502-")
            wait_hears(held, [held.tone])
            wait_bridged(pbx, "sipp", "502")
            ended = held.disconnects()
            held.hangup()
            held.wait_disconnected(after=ended)
            sipp_wait(phones, "hold-inactive")
            wait_ended("sipp", "502")
            holding = leg(mark, SIPP_UAC)
            assert dialogue(holding, "sipp") == calling("sipp") + [
                ("pbx", "200 INVITE", "sendrecv"), ("sipp", "ACK", None),
                ("pbx", "NOTIFY", None), ("sipp", "200 NOTIFY", None),
                ("sipp", "INVITE", "inactive"), ("pbx", "200 INVITE", "inactive"), ("sipp", "ACK", None),
                ("pbx", "NOTIFY", None), ("sipp", "200 NOTIFY", None),
                ("sipp", "INVITE", "sendrecv"), ("pbx", "200 INVITE", "sendrecv"), ("sipp", "ACK", None),
                ("pbx", "BYE", None), ("sipp", "200 BYE", None),
            ], summary(holding)
            check_hold(holding, SIPP_UAC, leg(mark, at(held)), at(held), "inactive")

        with subtest("an UPDATE with a new offer is answered, and both go on hearing each other"):
            a, b = phone["501"], phone["502"]
            mark = len(sip_messages(pbx))
            a.call("502")
            wait_bridged(pbx, "501", "502")
            hear_each_other(a, b)
            answered = a.count("RX [0-9]+ bytes Response msg 200/UPDATE/")
            a.cli("call update")
            a.wait_count("RX [0-9]+ bytes Response msg 200/UPDATE/", answered + 1)
            hear_each_other(a, b)
            wait_bridged(pbx, "501", "502")
            ended = a.disconnects(), b.disconnects()
            b.hangup()
            a.wait_disconnected(after=ended[0])
            b.wait_disconnected(after=ended[1])
            wait_ended("501", "502")
            updating = leg(mark, at(a))
            assert dialogue(updating, "501") == calling("501") + [
                ("pbx", "200 INVITE", "sendrecv"), ("501", "ACK", None),
                ("501", "UPDATE", "sendrecv"), ("pbx", "200 UPDATE", "sendrecv"),
                ("pbx", "BYE", None), ("501", "200 BYE", None),
            ], summary(updating)

        with subtest("early media: the callee's 183 with SDP reaches the caller, who hears the callee before the answer"):
            caller, callee = phone["503"], phone["504"]
            mark = len(sip_messages(pbx))
            confirmed = caller.confirmed(), callee.confirmed()
            caller.call("504")
            wait_hears(caller, [callee.tone])
            assert (caller.confirmed(), callee.confirmed()) == confirmed
            assert caller.count("state changed to EARLY") == 1
            wait_channel(pbx, "503", app="Dial", state="Ring")
            callee.cli("call answer 200")
            caller.wait_confirmed(after=confirmed[0])
            callee.wait_confirmed(after=confirmed[1])
            wait_bridged(pbx, "503", "504")
            hear_each_other(caller, callee)
            ended = caller.disconnects(), callee.disconnects()
            caller.hangup()
            caller.wait_disconnected(after=ended[0])
            callee.wait_disconnected(after=ended[1])
            wait_ended("503", "504")
            early = leg(mark, at(caller))
            assert dialogue(early, "503") == calling("503") + [
                ("pbx", "183 INVITE", "sendrecv"), ("pbx", "200 INVITE", "sendrecv"), ("503", "ACK", None),
                ("503", "BYE", None), ("pbx", "200 BYE", None),
            ], summary(early)
            early = leg(mark, at(callee))
            assert dialogue(early, "504") == [
                ("pbx", "INVITE", "sendrecv"), ("504", "100 INVITE", None),
                ("504", "183 INVITE", "sendrecv"), ("504", "200 INVITE", "sendrecv"), ("pbx", "ACK", None),
                ("pbx", "BYE", None), ("504", "200 BYE", None),
            ], summary(early)

        with subtest("100rel: a caller and a callee that require it get the 183 reliably and acknowledge it with PRACK"):
            caller, callee = phone["505"], phone["506"]
            mark = len(sip_messages(pbx))
            confirmed = caller.confirmed(), callee.confirmed()
            caller.call("506")
            wait_hears(caller, [callee.tone])
            callee.cli("call answer 200")
            caller.wait_confirmed(after=confirmed[0])
            callee.wait_confirmed(after=confirmed[1])
            wait_bridged(pbx, "505", "506")
            hear_each_other(caller, callee)
            ended = caller.disconnects(), callee.disconnects()
            caller.hangup()
            caller.wait_disconnected(after=ended[0])
            callee.wait_disconnected(after=ended[1])
            wait_ended("505", "506")
            # the answer came with the reliable 183, so the 200 has no SDP
            reliable = leg(mark, at(caller))
            assert dialogue(reliable, "505") == calling("505") + [
                ("pbx", "183 INVITE", "sendrecv"), ("505", "PRACK", None), ("pbx", "200 PRACK", None),
                ("pbx", "200 INVITE", None), ("505", "ACK", None),
                ("505", "BYE", None), ("pbx", "200 BYE", None),
            ], summary(reliable)
            assert re.search(r"^Require: 100rel\r$", sent(reliable, at(caller), "INVITE")[0]["text"], re.M)
            by_pbx = reliable
            reliable = leg(mark, at(callee))
            assert dialogue(reliable, "506") == [
                ("pbx", "INVITE", "sendrecv"), ("506", "100 INVITE", None),
                ("506", "183 INVITE", "sendrecv"), ("pbx", "PRACK", None), ("506", "200 PRACK", None),
                ("506", "200 INVITE", None), ("pbx", "ACK", None),
                ("pbx", "BYE", None), ("506", "200 BYE", None),
            ], summary(reliable)
            # each PRACK acknowledges the 183 it follows
            for messages, provisional, other in [(by_pbx, PBX, at(caller)), (reliable, at(callee), PBX)]:
                progress = sent(messages, provisional, "SIP/2.0 183")[0]["text"]
                prack = sent(messages, other, "PRACK")[0]["text"]
                assert re.search(r"^Require: 100rel\r$", progress, re.M), progress
                assert field(r"^RAck: (\d+) ", prack) == field(r"^RSeq: (\d+)\r$", progress), prack

        with subtest("a callee's 200 that crosses the pbx's CANCEL is acknowledged, and the call ended with BYE"):
            caller = phone["501"]
            mark = len(sip_messages(pbx))
            sipp_start(phones, "cancel-uas", *SIPP, "-p", "${toString uasPort}", "-mp", "6010")
            uas_listening()
            ended = caller.disconnects()
            caller.call("590")
            wait_channel(pbx, "uas", state="Ringing")
            caller.hangup()
            caller.wait_disconnected(after=ended)
            assert re.findall(r"is DISCONNECTED \[reason=(\d+) ", caller.log_text())[-1] == "487", caller.log_text()
            sipp_wait(phones, "cancel-uas")
            wait_ended("501", "uas")
            cancelled = leg(mark, at(caller))
            assert dialogue(cancelled, "501") == calling("501") + [
                ("pbx", "180 INVITE", None), ("501", "CANCEL", None), ("pbx", "200 CANCEL", None),
                ("pbx", "487 INVITE", None), ("501", "ACK", None),
            ], summary(cancelled)
            crossing = leg(mark, SIPP_UAS)
            assert dialogue(crossing, "uas") == [
                ("pbx", "INVITE", "sendrecv"), ("uas", "180 INVITE", None),
                ("pbx", "CANCEL", None), ("uas", "200 CANCEL", None), ("uas", "200 INVITE", "sendrecv"),
                ("pbx", "ACK", None), ("pbx", "BYE", None), ("uas", "200 BYE", None),
            ], summary(crossing)

        with subtest("a caller's CANCEL that crosses the pbx's 200 changes nothing: the caller acknowledges the 200 and ends the call with BYE"):
            callee = phone["502"]
            mark = len(sip_messages(pbx))
            ended = callee.disconnects()
            # the pbx answers late, and some answers come after SIPp went on
            with stalled(pbx):
                sipp(phones, "cancel-uac", PBX_IP, *SIPP, "-p", "${toString sippPort}", "-mp", "6000", "-s", "502", "-au", "sipp", "-ap", "pw-sipp")
            callee.wait_disconnected(after=ended)
            wait_ended("sipp", "502")
            crossing = leg(mark, SIPP_UAC)
            assert dialogue(crossing, "sipp") == calling("sipp") + [
                ("pbx", "200 INVITE", "sendrecv"), ("sipp", "CANCEL", None), ("pbx", "200 CANCEL", None),
                ("sipp", "ACK", None), ("sipp", "BYE", None), ("pbx", "200 BYE", None),
            ], summary(crossing)
            answered = leg(mark, at(callee))
            assert dialogue(answered, "502") == [
                ("pbx", "INVITE", "sendrecv"), ("502", "100 INVITE", None), ("502", "200 INVITE", "sendrecv"), ("pbx", "ACK", None),
                ("pbx", "BYE", None), ("502", "200 BYE", None),
            ], summary(answered)

        with subtest("glare: re-INVITEs from both ends cross, each side answers the other's with 491, the callee's retry goes through and the call goes on"):
            caller = phone["503"]
            mark = len(sip_messages(pbx))
            sipp_start(phones, "glare", *SIPP, "-p", "${toString uasPort}", "-mp", "6010", "-rtp_echo")
            uas_listening()
            caller.call("590")
            wait_bridged(pbx, "503", "uas")
            wait_hears(caller, [caller.tone])
            # the pbx answers late while the re-INVITEs cross, and some
            # answers come after SIPp went on
            with stalled(pbx):
                asterisk(pbx, f"dialplan set chanvar {channel('uas')} PJSIP_SEND_SESSION_REFRESH() invite")
                # until the pbx answered SIPp's retry
                deadline = time.time() + 30
                while True:
                    crossing = leg(mark, SIPP_UAS)
                    if [m for m in sent(crossing, PBX, "SIP/2.0 200") if cseq(m) == "INVITE"]:
                        break
                    assert time.time() < deadline, summary(crossing)
                    time.sleep(1)
            # the pbx owns the Call-ID, so it would retry within 4.1 s of its
            # 491 (res_pjsip_session.c:4324-4328)
            time.sleep(4.5)
            wait_hears(caller, [caller.tone])
            wait_bridged(pbx, "503", "uas")
            ended = caller.disconnects()
            caller.hangup()
            caller.wait_disconnected(after=ended)
            sipp_wait(phones, "glare")
            wait_ended("503", "uas")
            # the pbx retries only a change the session does not have yet (RFC
            # 3261 section 14.1), and a refresh asks for none
            # (res_pjsip_session.c:2471-2481)
            crossing = leg(mark, SIPP_UAS)
            assert dialogue(crossing, "uas") == [
                ("pbx", "INVITE", "sendrecv"), ("uas", "180 INVITE", None), ("uas", "200 INVITE", "sendrecv"), ("pbx", "ACK", None),
                ("pbx", "INVITE", "sendrecv"), ("uas", "INVITE", "sendrecv"),
                ("pbx", "491 INVITE", None), ("uas", "ACK", None), ("uas", "491 INVITE", None), ("pbx", "ACK", None),
                ("uas", "INVITE", "sendrecv"), ("pbx", "200 INVITE", "sendrecv"), ("uas", "ACK", None),
                ("pbx", "BYE", None), ("uas", "200 BYE", None),
            ], summary(crossing)

        with subtest("session timers: past 90 s the call is still up, each leg refreshed twice, and both hear each other"):
            caller, callee = phone["507"], phone["508"]
            # without refreshes the call would have ended within 90 s
            time.sleep(max(0, timed_start + 100 - time.time()))
            wait_bridged(pbx, "507", "508")
            hear_each_other(caller, callee)
            assert caller.disconnects() == 0 and callee.disconnects() == 0
            by_phone = leg(timed_mark, at(caller))
            assert dialogue(by_phone, "507") == calling("507") + [
                ("pbx", "200 INVITE", "sendrecv"), ("507", "ACK", None),
                ("507", "UPDATE", None), ("pbx", "200 UPDATE", None),
                ("507", "UPDATE", None), ("pbx", "200 UPDATE", None),
            ], summary(by_phone)
            by_pbx = leg(timed_mark, at(callee))
            assert dialogue(by_pbx, "508") == [
                ("pbx", "INVITE", "sendrecv"), ("508", "100 INVITE", None), ("508", "200 INVITE", "sendrecv"), ("pbx", "ACK", None),
                ("pbx", "UPDATE", None), ("508", "200 UPDATE", None),
                ("pbx", "UPDATE", None), ("508", "200 UPDATE", None),
            ], summary(by_pbx)
            # each leg's caller asked for 90 s and refreshes: the phone on its
            # leg, the pbx on the callee's
            for messages, caller_at, callee_at in [(by_phone, at(caller), PBX), (by_pbx, PBX, at(callee))]:
                answer = sent(messages, callee_at, "SIP/2.0 200")[0]
                assert field(r"^Session-Expires: (.*?)\r$", answer["text"]) == "90;refresher=uac", answer["text"]
                # a refresh every half session
                times = [m["time"] for m in firsts(sent(messages, caller_at, "UPDATE"))]
                gaps = [b - a for a, b in zip([answer["time"]] + times, times)]
                assert all(40 < gap < 50 for gap in gaps), gaps
            ended = caller.disconnects(), callee.disconnects()
            caller.hangup()
            caller.wait_disconnected(after=ended[0])
            callee.wait_disconnected(after=ended[1])
            wait_idle(pbx)
      '';
  }
