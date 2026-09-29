# Call queues with real callers and agents: every strategy gives each call to
# the agent it should (ringall rings every agent of the lowest penalty at
# once, linear starts each call at the first member, rrmemory and rrordered go
# round the members in their order, leastrecent and fewestcalls go by past
# calls, random keeps to the lowest penalty, wrandom rings one member at a
# time), music on hold for the caller, a member rings for `timeout` seconds
# and the queue tries again `retry` seconds later, a member with a higher
# penalty only rings once none with a lower one can take the call, a full
# queue and a queue whose members are all unavailable turn callers away, an
# agent logs in with a feature code and stays a member across a restart
# (persistent members), a caller waits in line while the only agent is busy
# and during its wrap-up time, and the queue log records it all
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # 501 and 502 call, 511 to 514 are agents, 515 never registers, 516 rings
  # and never answers
  extensions = [
    "501"
    "502"
    "511"
    "512"
    "513"
    "514"
    "515"
    "516"
  ];

  agents = [
    "PJSIP/511"
    "PJSIP/512"
    "PJSIP/513"
  ];

  # queues named after their strategy, dialled by their name like tiers
  strategies = [
    "ringall"
    "linear"
    "rrordered"
    "leastrecent"
    "fewestcalls"
    "random"
    "wrandom"
  ];

  # 516 has the lower penalty, so it rings first although it is listed last
  tiers = {
    strategy = "linear";
    timeout = 2;
    retry = 1;
    maxLength = 1;
    members = [
      {
        interface = "PJSIP/511";
        penalty = 1;
      }
      "PJSIP/516"
    ];
  };

  # agents log in with *45; a busy agent gets no second call, nor one during
  # its wrap-up time
  hotline = {
    wrapupTime = 3;
    retry = 1;
    settings.ringinuse = false;
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-queues";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          # the test follows calls through verbose messages in the journal
          logger = {
            channels.console = [
              "notice"
              "warning"
              "error"
              "verbose"
            ];
            queueLog = true;
          };
          settings."asterisk.conf".options.verbose = 3;

          pjsip = {
            transports.udp = {};
            endpoints = lib.genAttrs extensions (extension: {
              context = "office";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          queues = {
            persistentMembers = true;
            queues = {
              support = {
                strategy = "rrmemory";
                timeout = 10;
                members = agents;
              };
              sales = {
                members = ["PJSIP/515"];
                settings.joinempty = "unavailable,invalid";
              };
              inherit hotline tiers;
              ringall = {
                strategy = "ringall";
                members =
                  agents
                  ++ [
                    {
                      interface = "PJSIP/516";
                      penalty = 1;
                    }
                  ];
              };
              # members out of the order of their numbers
              linear = {
                strategy = "linear";
                members = [
                  "PJSIP/512"
                  "PJSIP/513"
                  "PJSIP/511"
                ];
              };
              rrordered = {
                strategy = "rrordered";
                members = [
                  "PJSIP/513"
                  "PJSIP/511"
                  "PJSIP/512"
                ];
              };
              leastrecent = {
                strategy = "leastrecent";
                members = agents;
              };
              fewestcalls = {
                strategy = "fewestcalls";
                members = agents;
              };
              random = {
                strategy = "random";
                members = [
                  "PJSIP/511"
                  {
                    interface = "PJSIP/512";
                    penalty = 1;
                  }
                  {
                    interface = "PJSIP/513";
                    penalty = 1;
                  }
                ];
              };
              wrandom = {
                strategy = "wrandom";
                members = [
                  "PJSIP/511"
                  {
                    interface = "PJSIP/512";
                    penalty = 1;
                  }
                  {
                    interface = "PJSIP/513";
                    penalty = 2;
                  }
                ];
              };
            };
          };

          dialplan.contexts.office.extensions =
            {
              "600" = [
                "Answer()"
                "Queue(support)"
                "Hangup()"
              ];
              "601" = [
                "Answer()"
                "Queue(sales)"
                "Verbose(1,queuestatus \${QUEUESTATUS})"
                "Hangup()"
              ];
              "602" = [
                "Answer()"
                "Queue(hotline)"
                "Hangup()"
              ];
              "*45" = [
                "AddQueueMember(hotline,PJSIP/\${CALLERID(num)})"
                "Playback(beep)"
                "Hangup()"
              ];
            }
            // lib.genAttrs (strategies ++ ["tiers"]) (queue: [
              "Answer()"
              "Queue(${queue})"
              "Verbose(1,queuestatus \${QUEUESTATUS})"
              "Hangup()"
            ]);
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
      };
    };

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        answers = {"516": 180}
        registered = ["501", "502", "511", "512", "513", "514", "516"]
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i, auto_answer=answers.get(ext, 200))
            for i, ext in enumerate(registered)
        }
        agents = {"511", "512", "513"}
        # agents 501 reached through each queue, in order
        connected = {}

        def poll(check, what, timeout=90):
            """Wait until check() returns something true, and return it."""
            deadline = time.time() + timeout
            while not (result := check()):
                if time.time() > deadline:
                    raise Exception(f"timed out waiting for {what}")
                time.sleep(0.1)
            return result

        def agent_of(caller):
            """The agent the caller is connected to, if any."""
            for members in bridges(pbx).values():
                if caller in members and members & agents:
                    return (members & agents).pop()

        def called(cursor):
            """The members Asterisk called since `cursor`, in order."""
            return re.findall(r"Called PJSIP/(\d+)", journal_since(pbx, cursor))

        def journal_times(cursor, pattern):
            """When the lines of Asterisk's journal since `cursor` that match
            `pattern` were logged, in seconds."""
            lines = pbx.succeed(f"journalctl -u asterisk.service -o short-unix --after-cursor={shlex.quote(cursor)}").splitlines()
            return [float(line.split()[0]) for line in lines if re.search(pattern, line)]

        def completed(queue):
            """Calls of `queue` that were answered and have ended."""
            shown = asterisk(pbx, f"queue show {queue}")
            match = re.search(r"C:(\d+),", shown)
            assert match, shown
            return int(match.group(1))

        def queue_call(queue):
            """Asterisk calls 501 into `queue`; the call ends once an agent
            answers. Returns the members called and the agent who answered."""
            before = completed(queue)
            cursor = journal_cursor(pbx)
            asterisk(pbx, f"channel originate PJSIP/501 extension {queue}@office")
            agent = poll(lambda: agent_of("501"), f"501 to reach an agent of {queue}")
            # the calls to the members are logged before the agent answered
            wait_journal(pbx, cursor, "answered PJSIP/501-")
            rung = called(cursor)
            for channel in channels(pbx):
                if endpoint_of(channel["name"]) == "501":
                    asterisk(pbx, f"channel request hangup {channel['name']}")
            # strategies that go by past calls count this one once it ended
            poll(lambda: completed(queue) == before + 1, f"{queue} to count the call")
            poll(lambda: not channels(pbx), "the call to end")
            connected.setdefault(queue, []).append(agent)
            return rung, agent

        def queue_log(queue):
            """(time, agent, event, data) of each entry of `queue` in the queue log."""
            entries = []
            for line in pbx.succeed("cat /var/log/asterisk/queue_log").splitlines():
                when, _, name, agent, event, *data = line.split("|")
                if name == queue:
                    entries.append((int(when), agent, event, data))
            return entries

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(registered))

        with subtest("every queue has the strategy it was given"):
            shown = asterisk(pbx, "queue show")
            for queue, strategy in ${builtins.toJSON (lib.mapAttrs (_: queue: queue.strategy) nodes.pbx.services.asterisk.queues.queues)}.items():
                assert re.search(rf"^{queue} has 0 calls \(max [^)]*\) in '{strategy}' strategy", shown, re.M), (queue, shown)

        with subtest("rrmemory hands successive callers to each agent in turn"):
            answered = []
            for _ in agents:
                cursor = journal_cursor(pbx)
                phone["501"].call("600")
                # the caller hears music until an agent answers
                wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/501-")
                answered.append(poll(lambda: agent_of("501"), "501 to reach an agent"))
                phone["501"].hangup()
                wait_idle(pbx)
            # in the members' order, starting after the last one who answered
            assert answered == ["511", "512", "513"], answered
            connected["support"] = answered

        with subtest("ringall rings every agent of the lowest penalty at once"):
            rung, agent = queue_call("ringall")
            # 516 has a higher penalty
            assert sorted(rung) == sorted(agents) and agent in rung, (rung, agent)

        with subtest("linear starts every call at the first member"):
            for _ in range(2):
                assert queue_call("linear") == (["512"], "512")

        with subtest("rrordered goes round the members in their order"):
            assert queue_call("rrordered") == (["513"], "513")
            assert queue_call("rrordered") == (["511"], "511")

        with subtest("leastrecent gives each call to the agent whose last call ended longest ago"):
            _, first = queue_call("leastrecent")
            # Asterisk keeps the time of a call in whole seconds: the next calls
            # end in a later second than the first
            poll(lambda: re.search(rf"PJSIP/{first} .*last was [1-9]", asterisk(pbx, "queue show leastrecent")), "a second to pass")
            answered = [first] + [queue_call("leastrecent")[1] for _ in range(3)]
            # agents without a call first, then the one idle longest
            assert sorted(answered[:3]) == sorted(agents) and answered[3] == first, answered

        with subtest("fewestcalls gives each call to an agent with the fewest calls"):
            answered = [queue_call("fewestcalls")[1] for _ in range(3)]
            assert sorted(answered) == sorted(agents), answered

        with subtest("random picks among the members of the lowest penalty"):
            assert queue_call("random") == (["511"], "511")

        with subtest("wrandom rings one member at a time"):
            # the penalty is only a weight, so any member may come first
            rung, agent = queue_call("wrandom")
            assert rung == [agent], (rung, agent)

        with subtest("516 rings for `timeout` seconds, `retry` seconds apart, and 511 with a higher penalty not at all"):
            cursor = journal_cursor(pbx)
            phone["501"].call("tiers")
            wait_journal(pbx, cursor, "Nobody picked up in ${toString (tiers.timeout * 1000)} ms", count=2)
            rings = journal_times(cursor, r"Called PJSIP/516")
            ends = journal_times(cursor, r"Nobody picked up")
            # journald stamps a line when it reads it and a busy machine runs
            # timers late; the defaults Asterisk falls back to, 15 and 5 s, are
            # far outside
            for start, end in zip(rings, ends):
                assert -0.5 < end - start - ${toString tiers.timeout} < 1, (rings, ends)
            for end, start in zip(ends, rings[1:]):
                assert -0.5 < start - end - ${toString tiers.retry} < 1, (rings, ends)
            assert set(called(cursor)) == {"516"}, called(cursor)
            phone["516"].wait_request("CANCEL", after=1)

        with subtest("a full queue turns callers away"):
            cursor = journal_cursor(pbx)
            phone["502"].call("tiers")
            wait_journal(pbx, cursor, "queuestatus FULL")
            assert "tiers has 1 calls (max ${toString tiers.maxLength})" in asterisk(pbx, "queue show tiers")
            wait_channel(pbx, "501", app="Queue")
            poll(lambda: not any(endpoint_of(c["name"]) == "502" for c in channels(pbx)), "502 to be turned away")

        with subtest("511 gets the call once 516 cannot take it"):
            asterisk(pbx, "queue pause member PJSIP/516 queue tiers")
            wait_bridged(pbx, "501", "511")
            phone["501"].hangup()
            wait_idle(pbx)
            events = [(agent, event, data) for _, agent, event, data in queue_log("tiers")]
            # 502 never entered the full queue
            assert [data[1] for _, event, data in events if event == "ENTERQUEUE"] == ["501"], events
            assert events.count(("PJSIP/516", "RINGNOANSWER", ["${toString (tiers.timeout * 1000)}"])) >= 2, events
            assert ("PJSIP/516", "PAUSE", [""]) in events, events
            assert [e[0] for e in events if e[1] == "CONNECT"] == ["PJSIP/511"], events

        with subtest("a queue whose members are all unavailable turns callers away"):
            cursor = journal_cursor(pbx)
            phone["502"].call("601")
            wait_journal(pbx, cursor, "queuestatus JOINEMPTY")
            wait_idle(pbx)

        with subtest("an agent who logs in with *45 stays a member across a restart"):
            phone["514"].call("*45")
            pbx.wait_until_succeeds("asterisk -rx 'queue show hotline' | grep -q 'PJSIP/514.*dynamic'")
            wait_idle(pbx)
            pbx.succeed("systemctl restart asterisk.service")
            pbx.wait_for_unit("asterisk.service")
            wait_contacts(pbx, len(registered))
            # the queue skips an agent until its restored contact is qualified,
            # which max_initial_qualify_time keeps within 5 s of the start
            pbx.wait_until_succeeds(
                f"test $(asterisk -rx 'pjsip show contacts' | grep -c ' Avail ') -eq {len(registered)}", timeout=15
            )
            assert "PJSIP/514" in asterisk(pbx, "queue show hotline")
            phone["501"].call("602")
            wait_bridged(pbx, "501", "514")

        with subtest("a caller waits in line while the agent is busy, and during its wrap-up time"):
            phone["502"].call("602")
            wait_channel(pbx, "502", app="Queue")
            # the queue tries the agent every second, and it is on a call
            pbx.wait_until_succeeds("asterisk -rx 'queue show hotline' | grep -qE '1. PJSIP/502-.*wait: 0:(0[2-9]|[1-5][0-9])'")
            assert not any("502" in members for members in bridges(pbx).values()), bridges(pbx)
            phone["501"].hangup()
            wait_bridged(pbx, "502", "514")
            entries = queue_log("hotline")
            ended = [when for when, _, event, _ in entries if event == "COMPLETECALLER"][-1]
            answered = [when for when, _, event, _ in entries if event == "CONNECT"][-1]
            # left alone for the wrap-up time, then rung at the next try; the
            # log counts whole seconds
            assert ${toString hotline.wrapupTime} <= answered - ended <= ${toString (hotline.wrapupTime + hotline.retry)} + 2, (ended, answered)
            phone["502"].hangup()
            wait_idle(pbx)

        with subtest("the queue log records callers, agents and logins across the restart"):
            assert [event for _, _, event, _ in queue_log("NONE")].count("QUEUESTART") == 2
            for queue, answered in connected.items():
                entries = queue_log(queue)
                assert [event for _, _, event, _ in entries].count("ENTERQUEUE") == len(answered), (queue, entries)
                assert [agent for _, agent, event, _ in entries if event == "CONNECT"] == [f"PJSIP/{a}" for a in answered], (queue, entries)
                assert [event for _, _, event, _ in entries].count("COMPLETECALLER") == len(answered), (queue, entries)
            events = [(agent, event) for _, agent, event, _ in queue_log("hotline")]
            assert ("PJSIP/514", "ADDMEMBER") in events, events
            assert events.count(("PJSIP/514", "CONNECT")) == 2, events
      '';
  }
