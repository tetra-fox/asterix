# Call queues with real callers and agents: round-robin distribution with
# music on hold for the caller, a queue whose members are all unavailable
# turns callers away, an agent logs in with a feature code and stays a member
# across a restart (persistent members), a caller waits in line while the only
# agent is busy, and the queue log records it all
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # 501 and 502 call, 511 to 514 are agents, 515 never registers
  extensions = [
    "501"
    "502"
    "511"
    "512"
    "513"
    "514"
    "515"
  ];
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
                members = [
                  "PJSIP/511"
                  "PJSIP/512"
                  "PJSIP/513"
                ];
              };
              sales = {
                members = ["PJSIP/515"];
                settings.joinempty = "unavailable,invalid";
              };
              # agents log in with *45; a busy agent gets no second call
              hotline.settings.ringinuse = false;
            };
          };

          dialplan.contexts.office.extensions = {
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
          };
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

        registered = ["501", "502", "511", "512", "513", "514"]
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(registered)
        }
        agents = {"511", "512", "513"}

        def wait_agent(caller, timeout=90):
            """The agent the caller is connected to."""
            deadline = time.time() + timeout
            while True:
                found = bridges(pbx)
                for members in found.values():
                    if caller in members and members & agents:
                        return (members & agents).pop()
                if time.time() > deadline:
                    raise Exception(f"{caller} was not connected to an agent: {found}")
                time.sleep(1)

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(registered))

        with subtest("the support queue hands successive callers to each agent in turn"):
            answered = []
            for _ in agents:
                cursor = journal_cursor(pbx)
                phone["501"].call("600")
                # the caller hears music until an agent answers
                wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/501-")
                answered.append(wait_agent("501"))
                phone["501"].hangup()
                wait_idle(pbx)
            assert sorted(answered) == sorted(agents), answered

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
            assert "PJSIP/514" in asterisk(pbx, "queue show hotline")
            phone["501"].call("602")
            wait_bridged(pbx, "501", "514")

        with subtest("a caller waits in line while the agent is busy"):
            phone["502"].call("602")
            wait_channel(pbx, "502", app="Queue")
            pbx.wait_until_succeeds("asterisk -rx 'queue show hotline' | grep -q '1. PJSIP/502-'")
            # the agent is on a call and the queue does not ring busy members
            time.sleep(5)
            assert not any("502" in members for members in bridges(pbx).values()), bridges(pbx)
            phone["501"].hangup()
            wait_bridged(pbx, "502", "514")
            phone["502"].hangup()
            wait_idle(pbx)

        with subtest("the queue log records callers, agents and logins"):
            queue_log = pbx.succeed("cat /var/log/asterisk/queue_log")
            for event in ["ENTERQUEUE", "CONNECT", "ADDMEMBER", "COMPLETECALLER"]:
                assert f"|{event}|" in queue_log, f"{event} missing from queue_log:\n{queue_log}"
      '';
  }
