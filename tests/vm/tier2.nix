# Tier-2 typed options on a running Asterisk: AMI admits users by secret and
# permit, runs only the actions of their write classes, sends only the events
# of their read classes and DTMF only when asked; ARI over HTTP and HTTPS
# answers only its allowed origins and refuses a read-only user's POST; CDR
# records in CSV and SQLite and CEL records of a call nobody answered and a
# call that ends while another writer holds master.db, with a hangup's cause
# and dial status in eventextra; ConfBridge profiles, queues and music on hold
# from a Nix-built directory; logrotate rotates a log file, queue_log and the
# CSV CDRs, and Asterisk goes on writing new ones.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = [
    "101"
    "102"
  ];

  certificates = import ./certificates.nix {inherit pkgs;};
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-tier2";

    nodes.pbx = {
      config,
      pkgs,
      ...
    }: let
      inherit (config.lib.asterisk) secret;

      officeMusic = pkgs.linkFarm "office-moh" [
        {
          name = "hold.wav";
          path = "${config.services.asterisk.package}/var/lib/asterisk/moh/macroform-cold_day.wav";
        }
      ];

      amiSecret = secret "/run/test-secrets/ami";
      ariPassword = secret "/run/test-secrets/ari";
    in {
      imports = [
        self.nixosModules.default
        ./ami.nix
        ./common.nix
        ./phone.nix
        (import ./secrets.nix {
          fixed =
            lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions)
            // {
              ami = "ami-secret";
              ari = "ari-secret";
            };
        })
      ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.sqlite
      ];

      services.asterisk = {
        enable = true;

        # rotated with the CSV CDRs, where the test finds a call's dialplan steps
        logger.channels.full = ["verbose"];
        logger.queueLog = true;
        settings."asterisk.conf".options.verbose = 3;

        pjsip = {
          transports.udp = {};
          endpoints = lib.genAttrs extensions (extension: {
            context = "internal";
            auth.password = secret "/run/test-secrets/sip-${extension}";
          });
        };

        dialplan.contexts = {
          internal.extensions = {
            "903" = [
              "Answer()"
              "Wait(30)"
              "Hangup()"
            ];
            # a call nobody answers and no phone is offered
            "904" = [
              "Wait(1)"
              "Hangup()"
            ];
            # the last records before the test reads CDR and CEL records
            "mark" = [
              "Answer()"
              "Hangup()"
            ];
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

        queues.queues = {
          support = {
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
        };

        musicOnHold.classes.office = {
          directory = officeMusic;
          sort = "alpha";
        };

        ami = {
          enable = true;
          users = {
            monitor = {
              secret = amiSecret;
              write = ["system"];
            };
            calls = {
              secret = amiSecret;
              read = [
                "call"
                "user"
              ];
            };
            keys = {
              secret = amiSecret;
              read = [
                "dtmf"
                "user"
              ];
            };
            everything = {
              secret = amiSecret;
              read = ["all"];
            };
            dialer = {
              secret = amiSecret;
              write = [
                "originate"
                "user"
              ];
            };
            # from 127.0.0.2 only, where the others may not connect from
            remote = {
              secret = amiSecret;
              permit = ["127.0.0.2/255.255.255.255"];
            };
          };
        };

        http = {
          enable = true;
          tls = {
            enable = true;
            certFile = "${certificates}/pbx.pem";
            keyFile = "${certificates}/pbx.key";
          };
        };
        ari = {
          enable = true;
          allowedOrigins = ["https://ari.example.org"];
          users = {
            app.password = ariPassword;
            viewer = {
              password = ariPassword;
              readOnly = true;
            };
          };
        };
        # /ari/asterisk, whose info and global variables the tests read and write
        modules.load = ["res_ari_asterisk.so"];

        cdr = {
          csv.enable = true;
          sqlite.enable = true;
        };
        cel = {
          enable = true;
          sqlite.enable = true;
        };
      };

      # logrotate runs only when the test starts it, and then rotates every
      # file; NixOS turns it off in tests (testing/test-instrumentation.nix)
      services.logrotate = {
        enable = true;
        extraArgs = ["--force"];
      };
      systemd.services.logrotate.startAt = lib.mkForce [];
    };

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./ami-events.py
      + ''
        import csv

        pbx.wait_for_unit("asterisk.service")
        pbx.succeed("journalctl --sync")
        pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|Error loading module|declined to load'")

        phone = {
            ext: Phone(pbx, ext, ext, f"pw-{ext}", "127.0.0.1", sip_port=5070 + i, cli_port=2300 + i)
            for i, ext in enumerate(${builtins.toJSON extensions})
        }

        def ami(*args):
            return pbx.succeed(f"ami {shlex.join(args)}")

        def ami_events(user):
            """Event, channel and digit of each event `user` received"""
            return [
                json.loads(line)
                for line in pbx.succeed(f"jq -c 'select(.Event) | {{Event, Channel, Digit}}' /tmp/ami-{user}.json").splitlines()
            ]

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_registrations({p: 200 for p in phone.values()})

        caller, other = phone["101"], phone["102"]

        with subtest("AMI admits its users by secret and by the addresses permit allows"):
            cursor = journal_cursor(pbx)
            assert "Response: Success" in ami("login", "monitor", "ami-secret")
            assert "Response: Success" in ami("login", "remote", "ami-secret", "127.0.0.2")
            for user, secret, source in [
                ("monitor", "wrong", "127.0.0.1"),
                ("nobody", "ami-secret", "127.0.0.1"),
                ("monitor", "ami-secret", "127.0.0.2"),
                ("remote", "ami-secret", "127.0.0.1"),
            ]:
                answer = ami("login", user, secret, source)
                assert "Message: Authentication failed" in answer, (user, secret, source, answer)
            wait_journal(pbx, cursor, "127.0.0.2 failed to pass IP ACL as 'monitor'")
            wait_journal(pbx, cursor, "127.0.0.1 failed to pass IP ACL as 'remote'")
            pbx.fail("ss -Hltn 'sport = :5038' | grep -v 127.0.0.1")

        with subtest("AMI runs only the actions of each user's write classes"):
            assert "Response: Success" in ami("run", "monitor", "ami-secret", "CoreStatus")
            for user, action in [
                ("monitor", ["Command", "Command=core show version"]),
                ("monitor", ["Originate", "Channel=Local/903@internal", "Application=Wait", "Data=1"]),
                ("dialer", ["CoreStatus"]),
                ("calls", ["CoreStatus"]),
            ]:
                answer = ami("run", user, "ami-secret", *action)
                assert "Message: Permission denied" in answer, (user, action, answer)
            assert "Ping: Pong" in ami("run", "calls", "ami-secret", "Ping")

        with subtest("AMI sends each user the events of its read classes, and DTMF only to users that ask for it"):
            ami_listen(pbx, "ami-secret", "calls", "keys", "everything")
            caller.call("903")
            wait_channel(pbx, "101", app="Wait")
            caller.dtmf("12#")
            pbx.wait_until_succeeds("test $(grep -c '\"Event\": \"DTMFEnd\"' /tmp/ami-keys.json) -ge 3")
            caller.hangup()
            wait_idle(pbx)
            ami_done(pbx, "dialer", "ami-secret", "calls", "keys", "everything")
            events = {user: ami_events(user) for user in ["calls", "keys", "everything"]}
            for user in ["keys", "everything"]:
                assert "".join(e["Digit"] for e in events[user] if e["Event"] == "DTMFEnd") == "12#", events[user]
            assert {e["Event"] for e in events["keys"]} == {"DTMFBegin", "DTMFEnd", "UserEvent"}, events["keys"]
            calls = {e["Event"] for e in events["calls"]}
            assert {"Newchannel", "Hangup", "UserEvent"} <= calls and not {"DTMFBegin", "DTMFEnd", "Newexten", "VarSet"} & calls, calls
            assert {"Newchannel", "Newexten", "DTMFEnd", "Hangup"} <= {e["Event"] for e in events["everything"]}

        with subtest("HTTP and HTTPS serve ARI on the loopback address, and ARI refuses a wrong password"):
            info = pbx.succeed("curl -sf -u app:ari-secret http://127.0.0.1:8088/ari/asterisk/info")
            assert '"system"' in info, info
            # the certificate is for the name pbx
            info = pbx.succeed(
                "curl -sf --cacert ${certificates}/ca.pem --resolve pbx:8089:127.0.0.1 -u app:ari-secret https://pbx:8089/ari/asterisk/info"
            )
            assert '"system"' in info, info
            status = pbx.succeed("curl -s -o /dev/null -w '%{http_code}' -u app:wrong http://127.0.0.1:8088/ari/asterisk/info")
            assert status.strip() == "401", status
            listening = pbx.succeed("ss -Hltn 'sport = :8088 or sport = :8089'")
            assert len(listening.splitlines()) == 2 and "127.0.0.1:8088" in listening and "127.0.0.1:8089" in listening, listening

        with subtest("ARI answers cross-origin requests only from its allowed origins"):
            def headers(origin, path, *options):
                return pbx.succeed(
                    f"curl -s -o /dev/null -D - -H 'Origin: {origin}' {shlex.join(options)} "
                    f"'http://127.0.0.1:8088/ari/{path}?api_key=app:ari-secret'"
                )
            allowed = headers("https://ari.example.org", "asterisk/info")
            assert "Access-Control-Allow-Origin: https://ari.example.org\r\n" in allowed, allowed
            elsewhere = headers("https://elsewhere.example", "asterisk/info")
            assert "Access-Control-Allow" not in elsewhere, elsewhere
            # a browser asks before a POST from another origin
            preflight = ["-X", "OPTIONS", "-H", "Access-Control-Request-Method: POST"]
            allowed = headers("https://ari.example.org", "asterisk/variable", *preflight)
            assert re.search(r"Access-Control-Allow-Methods: [A-Z,]*POST", allowed), allowed
            elsewhere = headers("https://elsewhere.example", "asterisk/variable", *preflight)
            assert "Access-Control-Allow" not in elsewhere, elsewhere

        with subtest("a read-only ARI user may read but is refused on POST"):
            def post(user, value):
                return pbx.succeed(
                    f"curl -s -o /dev/null -w '%{{http_code}}' -X POST -u {user}:ari-secret "
                    f"'http://127.0.0.1:8088/ari/asterisk/variable?variable=WRITER&value={value}'"
                )
            assert post("viewer", "viewer") == "403"
            assert post("app", "app") == "204"
            value = pbx.succeed("curl -sf -u viewer:ari-secret 'http://127.0.0.1:8088/ari/asterisk/variable?variable=WRITER'")
            assert json.loads(value) == {"value": "app"}, value

        # Asterisk may be writing records while the test reads them: wait for its lock
        SQLITE = "sqlite3 -cmd '.timeout 10000' /var/log/asterisk/master.db"

        def table(query):
            return [row.split("|") for row in pbx.succeed(f"{SQLITE} {shlex.quote(query)}").splitlines()]

        def marker():
            """Make a call whose records come last, and return where the CSV
            file, the CDR table and the CEL table end after them. Asterisk
            writes records in order, so those of calls that ended before are
            all written by then."""
            # an earlier call's row can still be on its way to master.db, as
            # after another writer held it, so count once both files agree
            pbx.wait_until_succeeds(
                f"test $(grep -c '\"mark\"' /var/log/asterisk/cdr-csv/Master.csv) -eq $({SQLITE} \"select count(*) from cdr where dst = 'mark'\")",
                timeout=60,
            )
            marks = int(table("select count(*) from cdr where dst = 'mark'")[0][0])
            ended = caller.disconnects()
            caller.call("mark")
            caller.wait_disconnected(after=ended)
            pbx.wait_until_succeeds(f"test $(grep -c '\"mark\"' /var/log/asterisk/cdr-csv/Master.csv) -gt {marks}", timeout=60)
            pbx.wait_until_succeeds(
                f"{SQLITE} \"select count(*) from cdr where dst = 'mark'\" | grep -qx {marks + 1}", timeout=60
            )
            pbx.wait_until_succeeds(
                f"{SQLITE} \"select eventtype, exten from cel order by rowid desc limit 1\" | grep -qx 'LINKEDID_END|mark'",
                timeout=60,
            )
            return (
                int(pbx.succeed("wc -l < /var/log/asterisk/cdr-csv/Master.csv")),
                int(table("select max(rowid) from cdr")[0][0]),
                int(table("select max(rowid) from cel")[0][0]),
            )

        def records_since(position):
            """The CDR records written since `position`, the same in CSV and in
            SQLite, as (src, dst, channel's endpoint, dstchannel's endpoint,
            lastapp, disposition), the CEL records as (eventtype, channel's
            endpoint), and where they end"""
            new = marker()
            first, last = position[0] + 1, new[0] - 1
            lines = pbx.succeed(f"sed -n '{first},{last}p' /var/log/asterisk/cdr-csv/Master.csv") if first <= last else ""
            in_csv = sorted((r[1], r[2], endpoint_of(r[5]), endpoint_of(r[6]), r[7], r[14]) for r in csv.reader(lines.splitlines()))
            in_sqlite = sorted(
                (r[0], r[1], endpoint_of(r[2]), endpoint_of(r[3]), r[4], r[5])
                for r in table(f"select src, dst, channel, dstchannel, lastapp, disposition from cdr where rowid > {position[1]} and rowid < {new[1]}")
            )
            assert in_csv == in_sqlite, (in_csv, in_sqlite)
            marker_start = table(f"select min(rowid) from cel where uniqueid = (select uniqueid from cel where rowid = {new[2]})")[0][0]
            events = [
                (r[0], endpoint_of(r[1]))
                for r in table(f"select eventtype, channame from cel where rowid > {position[2]} and rowid < {marker_start} order by rowid")
            ]
            return in_sqlite, events, new

        LEG_EVENTS = ["CHAN_START", "ANSWER", "HANGUP", "CHAN_END"]

        def legs(events):
            """The CEL events every channel has once, and ANSWER once answered"""
            return sorted(event for event in events if event[0] in LEG_EVENTS)

        def expected_legs(answered, unanswered=()):
            return sorted(
                [(kind, endpoint) for endpoint in answered for kind in LEG_EVENTS]
                + [(kind, endpoint) for endpoint in unanswered for kind in LEG_EVENTS if kind != "ANSWER"]
            )

        def extra(since, kind, endpoint):
            """The eventextra of the one `kind` event of `endpoint`'s channel since the position `since`"""
            rows = table(f"select eventextra from cel where rowid > {since[2]} and eventtype = '{kind}' and channame like 'PJSIP/{endpoint}-%'")
            assert len(rows) == 1, rows
            return json.loads(rows[0][0])

        position = marker()

        with subtest("CDR and CEL: an unanswered call that reaches no phone"):
            before = position
            ended = other.disconnects()
            other.call("904")
            other.wait_disconnected(after=ended)
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # unanswered is off
            assert cdrs == [], cdrs
            assert legs(events) == expected_legs([], unanswered=["102"]), events
            hangup = extra(before, "HANGUP", "102")
            assert (hangup["hangupcause"], hangup["dialstatus"]) == (16, ""), hangup

        with subtest("CDR and CEL: the records of a call wait while another writer holds master.db for 8 s"):
            # as CDR and CEL do to each other while one writes a burst of records
            hold = "(echo 'BEGIN IMMEDIATE;'; sleep 8; echo 'COMMIT;') | sqlite3 -cmd '.timeout 10000' /var/log/asterisk/master.db"
            pbx.succeed(f"systemd-run --unit=master-db-lock --collect -E PATH sh -c {shlex.quote(hold)}")
            pbx.wait_until_fails("sqlite3 /var/log/asterisk/master.db 'BEGIN IMMEDIATE; ROLLBACK;'")
            ended = caller.disconnects()
            caller.call("mark")
            caller.wait_disconnected(after=ended)
            # the call ended, and so its records were written, while the lock was held
            pbx.succeed("systemctl is-active --quiet master-db-lock")
            pbx.wait_until_fails("systemctl is-active --quiet master-db-lock", timeout=30)
            cdrs, events, position = records_since(position)
            assert cdrs == [("101", "mark", "101", "", "Hangup", "ANSWERED")], cdrs
            assert legs(events) == expected_legs(["101"]), events
            pbx.fail("journalctl -u asterisk.service | grep 'database is locked'")

        with subtest("conference profiles, queues and music on hold are loaded"):
            assert "board" in asterisk(pbx, "confbridge show profile bridges")
            assert "chair" in asterisk(pbx, "confbridge show profile users")
            assert "chair_menu" in asterisk(pbx, "confbridge show menus")
            queue = asterisk(pbx, "queue show support")
            assert "rrmemory" in queue and "PJSIP/101" in queue and "Bob" in queue, queue
            classes = asterisk(pbx, "moh show classes")
            assert "Class: office" in classes and "office-moh" in classes, classes
            assert "hold" in asterisk(pbx, "moh show files")

        with subtest("logrotate rotates the log file, queue_log and the CSV CDRs, and Asterisk goes on in new files"):
            files = ["full", "queue_log", "cdr-csv/Master.csv"]
            pbx.succeed("systemctl start logrotate.service")
            rotated = {file: pbx.succeed(f"stat -c '%U %s' /var/log/asterisk/{file}.1").split() for file in files}
            assert all(owner == "asterisk" and int(size) > 0 for owner, size in rotated.values()), rotated
            # what logger reload writes first
            pbx.succeed("grep -q CONFIGRELOAD /var/log/asterisk/queue_log")
            ended = caller.disconnects()
            caller.call("mark")
            caller.wait_disconnected(after=ended)
            pbx.wait_until_succeeds("grep -q '\"mark\"' /var/log/asterisk/cdr-csv/Master.csv")
            pbx.wait_until_succeeds("grep -q 'Executing \\[mark@internal:1\\]' /var/log/asterisk/full")
            assert {file: pbx.succeed(f"stat -c '%U %s' /var/log/asterisk/{file}.1").split() for file in files} == rotated
      '';
  }
