# One call held for an hour with session timers of 90 s on both legs, the
# phone refreshing its own leg with UPDATE and the pbx the other: every
# minute the call is the same one on both sides, bridged and heard both ways,
# every refresh comes 40 to 50 s after the last and is answered with 200,
# nothing else happens to the dialogs, and once warmed up Asterisk keeps as
# many descriptors and taskprocessors, and its heap in use within 256 KiB.
# Each minute's sample of Asterisk's resource use goes to long-call.csv in
# the result, with its heap in use every 5 minutes.
#
#   VLAN 1  pbx, phones (507 calls 508)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  minutes = 60;
  load = import ./load-nodes.nix {inherit lib;};
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-long-call";
    globalTimeout = (minutes + 30) * 60;

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = {
              sip-507 = "pw-507";
              sip-508 = "pw-508";
            };
          })
          load.pbx
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.genAttrs ["507" "508"] (extension: {
                context = "long";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
              }))
              {
                # an answer with one codec: pjsua takes an answer with several
                # as a cue to settle on one with an UPDATE (check_lock_codec in
                # pjsip/src/pjsua-lib/pjsua_call.c), which would pass for a refresh
                "507".settings.preferred_codec_only = true;
                # the pbx refreshes the session of calls to 508 every 45 s
                "508".settings.timers_sess_expires = 90;
              }
            ];
          };

          dialplan.contexts.long.extensions."_50X" = [
            "Dial(PJSIP/\${EXTEN})"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          load.sizing
        ];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + builtins.readFile ./usage.py
      + ''
        MINUTES = ${toString minutes}

        start_all()
        pbx.wait_for_unit("asterisk.service")

        # 507 asks for sessions of 90 s and refreshes them; the pbx does on the leg to 508
        caller = Phone(phones, "507", "507", "pw-507", "pbx", sip_port=5067, cli_port=2307, options="--timer-se=90 --timer-min-se=90")
        callee = Phone(phones, "508", "508", "pw-508", "pbx", sip_port=5068, cli_port=2308)

        def hear_each_other():
            wait_hears(caller, [callee.tone])
            wait_hears(callee, [caller.tone])

        def logged(phone, pattern):
            """Times of the lines of `phone`'s log that match `pattern`, in
            seconds since the midnight before pjsua started, by the phones' clock."""
            times, day, previous = [], 0, 0.0
            for line in phone.log_text().splitlines():
                match = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d{3}) ", line)
                if not match:
                    continue
                hours, minutes, seconds, milliseconds = map(int, match.groups())
                moment = hours * 3600 + minutes * 60 + seconds + milliseconds / 1000 + day
                # past midnight the clock goes back by most of a day; lines of
                # two threads can come a few milliseconds out of order
                if moment < previous - 43200:
                    day += 86400
                    moment += 86400
                previous = max(previous, moment)
                if re.search(pattern, line):
                    times.append(moment)
            return times

        def gaps(times):
            return [round(b - a, 1) for a, b in zip(times, times[1:])]

        with subtest("phones register"):
            start_phones([caller, callee])
            wait_registrations({caller: 200, callee: 200})

        with subtest("a call with sessions of 90 s starts, refreshed by the phone on one leg and by the pbx on the other"):
            caller.call("508")
            wait_bridged(pbx, "507", "508")
            hear_each_other()
            answered = time.time()
            names = sorted(c["name"] for c in channels(pbx))
            assert len(names) == 2, names

        measured = []
        output = open(driver.out_dir / "long-call.csv", "w", newline="")
        with subtest(f"for {MINUTES} minutes the call stays the same one on both sides, bridged and heard both ways"):
            received = rtp_received([caller, callee])
            for minute in range(1, MINUTES + 1):
                time.sleep(max(0, answered + 60 * minute - time.time()))
                assert sorted(c["name"] for c in channels(pbx)) == names, channels(pbx)
                wait_bridged(pbx, "507", "508", timeout=10)
                hear_each_other()
                now = rtp_received([caller, callee])
                # 50 packets a second
                assert all(now[name] >= received[name] + 2500 for name in now), (received, now)
                received = now
                assert caller.confirmed() == 1 and callee.confirmed() == 1
                assert caller.disconnects() == 0 and callee.disconnects() == 0
                sample = {
                    "minute": minute,
                    **usage(pbx),
                    "descriptors": lasting_descriptors(pbx),
                    "heap_kib": heap_in_use(pbx) if minute % 5 == 0 else "",
                }
                if not measured:
                    output.write(",".join(sample) + "\n")
                measured.append(sample)
                output.write(",".join(str(sample.get(column, "")) for column in measured[0]) + "\n")
                output.flush()
                print(f"minute {minute}: {sample}")
        output.close()

        with subtest("each leg was refreshed every 40 to 50 s with an UPDATE answered 200, and nothing else happened to either dialog"):
            # the phone sends its leg's refreshes, the pbx the other leg's
            sent = logged(caller, r"TX \d+ bytes Request msg UPDATE/")
            got = logged(callee, r"RX \d+ bytes Request msg UPDATE/")
            print(f"refreshes: {len(sent)} by the phone, {len(got)} by the pbx")
            for times, answers, first in [
                (sent, logged(caller, r"RX \d+ bytes Response msg 200/UPDATE/"), logged(caller, r"RX \d+ bytes Response msg 200/INVITE/")[-1]),
                (got, logged(callee, r"TX \d+ bytes Response msg 200/UPDATE/"), logged(callee, r"TX \d+ bytes Response msg 200/INVITE/")[-1]),
            ]:
                assert len(times) >= MINUTES * 60 // 50 and len(answers) == len(times), (len(times), len(answers))
                assert all(40 < gap < 50 for gap in gaps([first] + times)), gaps([first] + times)
            for phone in [caller, callee]:
                # direction, status of a response, and method of each SIP message
                messages = re.findall(r"([TR])X \d+ bytes (?:Request|Response) msg (?:(\d+)/)?([A-Z]+)/", phone.log_text())
                # besides the call's start and its refreshes, only the phone's
                # registrations and the pbx's qualify
                assert {method for _, _, method in messages} <= {"INVITE", "ACK", "UPDATE", "REGISTER", "OPTIONS"}, messages
                assert {status for _, status, method in messages if method == "UPDATE" and status} == {"200"}, messages
            # the second INVITE answers the pbx's challenge
            assert caller.count(r"TX [0-9]+ bytes Request msg INVITE/") == 2 and callee.count(r"RX [0-9]+ bytes Request msg INVITE/") == 1

        with subtest("once warmed up, Asterisk kept as many descriptors and taskprocessors, and its heap in use"):
            warm, last = measured[4], measured[-1]
            for key in ["descriptors", "taskprocessors", "channels", "bridges"]:
                assert last[key] == warm[key], (key, warm[key], last[key])
            heaps = [(sample["minute"], sample["heap_kib"]) for sample in measured if sample["heap_kib"] != ""]
            print(f"heap in use in KiB by minute: {heaps}")
            print(f"at minute 5 and at the end: resident memory {warm['rss_kib']} and {last['rss_kib']} KiB, threads {warm['threads']} and {last['threads']}")
            # the 160 refreshes of an hour, each keeping 2 KiB, a SIP message's
            # worth, would add 320 KiB
            assert max(heap for _, heap in heaps) - heaps[0][1] < 256, heaps
      '';
  }
