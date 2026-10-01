# Tier-2 typed options on a running Asterisk: voicemail with e-mail
# notification; each built-in call feature fires on its digits from the side
# the Dial options give it, while the same digits from the other side, digits
# of no feature and a code whose digits come further apart than
# featuredigittimeout reach the far end, and a transfer number ends after
# transferdigittimeout; applications run on the side that pressed their code
# or on its peer, with all their arguments; AMI admits users by secret and
# permit, runs only the actions of their write classes, sends only the events
# of their read classes, DTMF only when asked, and every event of 128 calls at
# once; ARI over HTTP and HTTPS answers only its allowed origins, refuses a
# read-only user's POST and runs a Stasis application that answers, plays a
# sound and hangs up; CDR records in CSV and SQLite and CEL records of blind
# and attended transfers, a conference, a queue, a ring group, a call nobody
# answered and a call that ends while another writer holds master.db, with a
# transfer's target and a hangup's cause and dial status in eventextra;
# ConfBridge profiles, queues and music on hold from a Nix-built directory.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = [
    "101"
    "102"
    "103"
    "104"
  ];

  # sounds the pbx plays, each a tone no phone sends (phone.py), so a
  # recording shows which one played
  promptTones = {
    self-tone = 2500;
    peer-tone = 2700;
    ari-tone = 2900;
  };
  prompts = pkgs.runCommand "tier2-prompts" {nativeBuildInputs = [pkgs.sox];} ''
    mkdir -p $out/sounds/test
    ${lib.concatStrings (lib.mapAttrsToList (name: tone: ''
        sox -n -r 8000 -b 16 -c 1 -e signed-integer -t raw $out/sounds/test/${name}.sln synth 2 sine ${toString tone} vol 0.5
      '')
      promptTones)}
  '';

  certificates = import ./certificates.nix {inherit pkgs;};

  stasisApp = pkgs.writers.writePython3Bin "stasis" {libraries = [pkgs.python3Packages.websocket-client];} ./stasis.py;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-tier2";

    nodes.pbx = {
      config,
      pkgs,
      ...
    }: let
      inherit (config.lib.asterisk) secret;

      # records every message Asterisk "sends", and the password an SMTP client
      # would read from its credential
      fakeSendmail = pkgs.writeShellScript "fake-sendmail" ''
        cat > "/var/lib/asterisk/sent-mail-$(date +%s%N).eml"
        cat "$CREDENTIALS_DIRECTORY/smtp-password" > /var/lib/asterisk/smtp-password-seen
      '';

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
              vm-101 = "9876";
              ami = "ami-secret";
              ari = "ari-secret";
              smtp = "smtp-secret";
            };
        })
      ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.sqlite
        stasisApp
      ];

      services.asterisk = {
        enable = true;

        credentials.smtp-password = "/run/test-secrets/smtp";

        # the test follows calls through verbose messages in the journal
        logger.channels.console = [
          "notice"
          "warning"
          "error"
          "verbose"
        ];
        settings."asterisk.conf".options.verbose = 3;
        sounds.packages = [prompts];

        pjsip = {
          transports.udp = {};
          endpoints = lib.genAttrs extensions (extension: {
            context = "internal";
            auth.password = secret "/run/test-secrets/sip-${extension}";
            mailboxes = lib.optional (extension == "101") "101@default";
          });
        };

        dialplan.contexts = {
          internal.extensions = {
            "_10X" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "Hangup()"
            ];
            # 20X calls 10X with the features split between the two sides:
            # transfers and one-touch recording for the called phone,
            # disconnect, parking and the applications for the caller
            "_20X" = [
              "Set(DYNAMIC_FEATURES=selftone#peertone#globals)"
              "Dial(PJSIP/10\${EXTEN:2},20,txHK)"
              "Hangup()"
            ];
            # calls 103 like 203; a transfer dialled to 10 waits for more
            # digits, as 101 to 104 start with it
            "10" = ["Goto(203,1)"];
            "700" = [
              "Answer()"
              "VoiceMail(101@default,s)"
              "Hangup()"
            ];
            "800" = [
              "Answer()"
              "ConfBridge(800,board,chair)"
            ];
            "900" = [
              "Stasis(tier2)"
              "Hangup()"
            ];
            # a ring group
            "901" = [
              "Dial(PJSIP/102&PJSIP/104,20)"
              "Hangup()"
            ];
            "902" = [
              "Queue(sales)"
              "Hangup()"
            ];
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
          # AMI originates its calls here, which all wait until the test sets RELEASE
          flood.extensions.s = [
            "Answer()"
            "While($[\"\${GLOBAL(RELEASE)}\" = \"\"])"
            "Wait(0.2)"
            "EndWhile()"
            "Hangup()"
          ];
        };

        voicemail = {
          mailboxes."101" = {
            pin = secret "/run/test-secrets/vm-101";
            fullName = "Alice";
            email = "alice@example.org";
          };
          email = {
            command = "${fakeSendmail}";
            fromAddress = "pbx@example.org";
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
          # both ring at once; 104 never answers
          sales = {
            strategy = "ringall";
            members = [
              "PJSIP/101"
              "PJSIP/104"
            ];
          };
        };

        musicOnHold.classes.office = {
          directory = officeMusic;
          sort = "alpha";
        };

        features = {
          general = {
            featuredigittimeout = 1000;
            transferdigittimeout = 2;
          };
          featureMap = {
            blindxfer = "#1";
            atxfer = "*2";
            disconnect = "*0";
            automixmon = "*3";
            parkcall = "#72";
          };
          applications = {
            selftone = {
              dtmf = "*7";
              app = "Playback";
              args = "test/self-tone";
            };
            peertone = {
              dtmf = "*8";
              activateOn = "peer";
              app = "Playback";
              args = "test/peer-tone";
            };
            globals = {
              dtmf = "*9";
              app = "MSet";
              args = "GLOBAL(FIRST)=1,GLOBAL(SECOND)=2";
            };
          };
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
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + builtins.readFile ./ami-events.py
      + ''
        import csv

        SELF_TONE, PEER_TONE, ARI_TONE = ${toString promptTones.self-tone}, ${toString promptTones.peer-tone}, ${toString promptTones.ari-tone}

        pbx.wait_for_unit("asterisk.service")
        pbx.succeed("journalctl --sync")
        pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|Error loading module|declined to load'")

        phone = {
            ext: Phone(pbx, ext, ext, f"pw-{ext}", "127.0.0.1", sip_port=5070 + i, cli_port=2300 + i, auto_answer=180 if ext == "104" else 200)
            for i, ext in enumerate(${builtins.toJSON extensions})
        }

        def tone_heard(p, tone, start):
            """Whether `tone` was the loudest `p` heard in any 100 ms since the
            mark `start`. The 100 ms in which a prompt stops also hold weaker
            peaks up to a few hundred Hz away from it."""
            return any(window and abs(window[0] - tone) <= TOLERANCE for window in heard(p, start))

        def wait_prompt(cursor, ext, prompt):
            wait_journal(pbx, cursor, f"<PJSIP/{ext}-[0-9a-f]+> Playing '{prompt}\\.")

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

        with subtest("voicemail records a message and sends a notification"):
            assert "Alice" in asterisk(pbx, "voicemail show users")
            phone["101"].call("700")
            pbx.wait_until_succeeds("asterisk -rx 'core show channels' | grep -q 'VoiceMail'")
            pbx.sleep(8)
            phone["101"].hangup()
            pbx.wait_until_succeeds("test -f /var/lib/asterisk/spool/voicemail/default/101/INBOX/msg0000.txt")
            pbx.wait_until_succeeds("ls /var/lib/asterisk/sent-mail-*.eml")
            mail = pbx.succeed("cat /var/lib/asterisk/sent-mail-*.eml")
            assert "alice@example.org" in mail and "pbx@example.org" in mail, mail[:2000]
            assert pbx.succeed("cat /var/lib/asterisk/smtp-password-seen").strip() == "smtp-secret"
            pbx.fail("grep -R 9876 /etc/asterisk/")
            wait_idle(pbx)

        caller, callee, target = phone["101"], phone["102"], phone["103"]

        with subtest("a feature's digits from the side without it, and digits of no feature, reach the far end"):
            caller.call("202")
            wait_bridged(pbx, "101", "102")
            received = callee.dtmf_received()
            caller.dtmf("5")
            callee.wait_dtmf("5", after=len(received))
            # transfers and one-touch recording are the called phone's
            caller.dtmf("#1*2*3")
            callee.wait_dtmf("5#1*2*3", after=len(received))
            received = caller.dtmf_received()
            # disconnect, parking and the applications are the caller's
            callee.dtmf("*0#72*7*8*9")
            caller.wait_dtmf("*0#72*7*8*9", after=len(received))
            assert "Parked Calls\n------------\n  (none)" in asterisk(pbx, "parking show default")
            wait_bridged(pbx, "101", "102")

        with subtest("the digits of a code further apart than featuredigittimeout reach the far end"):
            received = callee.dtmf_received()
            caller.dtmf("#7")
            # a caller who pauses between digits, for twice featuredigittimeout
            time.sleep(2)
            caller.dtmf("2")
            callee.wait_dtmf("#72", after=len(received))
            assert "Parked Calls\n------------\n  (none)" in asterisk(pbx, "parking show default")
            wait_bridged(pbx, "101", "102")

        with subtest("applications run on the side that pressed their code or on its peer, with all their arguments"):
            start = {p: recorded(p) for p in (caller, callee)}
            caller.dtmf("*7")
            wait_heard(caller, [SELF_TONE], start[caller])
            # the application reads the caller's digits until it is done, and
            # then the caller hears the called phone again
            wait_hears(caller, [callee.tone])
            caller.dtmf("*8")
            wait_heard(callee, [PEER_TONE], start[callee])
            wait_hears(callee, [caller.tone])
            assert not tone_heard(callee, SELF_TONE, start[callee]), heard(callee, start[callee])
            assert not tone_heard(caller, PEER_TONE, start[caller]), heard(caller, start[caller])
            caller.dtmf("*9")
            pbx.wait_until_succeeds("asterisk -rx 'dialplan show globals' | grep -q 'FIRST=1'")
            globals_ = asterisk(pbx, "dialplan show globals")
            assert "SECOND=2" in globals_, globals_

        with subtest("one-touch recording is the called phone's, disconnect the caller's"):
            callee.dtmf("*3")
            pbx.wait_until_succeeds("ls /var/lib/asterisk/spool/monitor/auto-*.wav")
            ended = {p: p.disconnects() for p in (caller, callee)}
            caller.dtmf("*0")
            for p in (caller, callee):
                p.wait_disconnected(after=ended[p])
            wait_idle(pbx)

        with subtest("the called phone transfers blindly with its code, and a pause longer than transferdigittimeout ends the number"):
            cursor = journal_cursor(pbx)
            caller.call("202")
            wait_bridged(pbx, "101", "102")
            callee.dtmf("#1")
            wait_prompt(cursor, "102", "pbx-transfer")
            # 10 could go on to 101, so Asterisk takes it once no digit came for transferdigittimeout
            callee.dtmf("10")
            wait_journal(pbx, cursor, r'Executing \[10@internal:1\] Goto\("PJSIP/101-')
            wait_bridged(pbx, "101", "103")

        with subtest("the caller parks the call with its code"):
            ended = caller.disconnects()
            caller.dtmf("#72")
            wait_journal(pbx, cursor, "Parking 'PJSIP/103-[0-9a-f]+' in 'default' at space 701")
            assert re.search(r"Space +: +701\n +Channel +: +PJSIP/103-", asterisk(pbx, "parking show default"))
            caller.wait_disconnected(after=ended)
            target.hangup()
            wait_idle(pbx)

        with subtest("the called phone transfers with consultation with its code"):
            cursor = journal_cursor(pbx)
            caller.call("202")
            wait_bridged(pbx, "101", "102")
            callee.dtmf("*2")
            wait_prompt(cursor, "102", "pbx-transfer")
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/101-")
            callee.dtmf("103")
            # the consultation runs through a Local channel
            wait_hears(callee, [target.tone])
            callee.hangup()
            wait_bridged(pbx, "101", "103")
            caller.hangup()
            wait_idle(pbx)

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
                ("monitor", ["Originate", "Channel=Local/s@flood", "Application=Wait", "Data=1"]),
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

        with subtest("a Stasis application answers, plays a sound and hangs up"):
            pbx.succeed("systemd-run --unit=stasis --collect stasis tier2 app:ari-secret test/ari-tone /tmp/stasis.log")
            pbx.wait_until_succeeds("grep -qx connected /tmp/stasis.log")
            start = recorded(caller)
            byes = caller.requests("BYE")
            confirmed = caller.confirmed()
            caller.call("900")
            caller.wait_request("BYE", after=byes)
            assert caller.confirmed() > confirmed
            windows = heard(caller, start)
            assert sum(same(window, [ARI_TONE]) for window in windows) >= 15, windows
            pbx.wait_until_succeeds("grep -qx StasisEnd /tmp/stasis.log")
            received = pbx.succeed("cat /tmp/stasis.log").split()
            steps = ["StasisStart", "PlaybackStarted", "PlaybackFinished", "StasisEnd"]
            assert [event for event in received if event in steps] == steps, received
            wait_idle(pbx)

        # Asterisk may be writing records while the test reads them: wait for its lock
        SQLITE = "sqlite3 -cmd '.timeout 10000' /var/log/asterisk/master.db"

        def table(query):
            return [row.split("|") for row in pbx.succeed(f"{SQLITE} {shlex.quote(query)}").splitlines()]

        def marker():
            """Make a call whose records come last, and return where the CSV
            file, the CDR table and the CEL table end after them. Asterisk
            writes records in order, so those of calls that ended before are
            all written by then."""
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

        def who(events, kind):
            return sorted(endpoint for event, endpoint in events if event == kind)

        def extra(since, kind, endpoint):
            """The eventextra of the one `kind` event of `endpoint`'s channel since the position `since`"""
            rows = table(f"select eventextra from cel where rowid > {since[2]} and eventtype = '{kind}' and channame like 'PJSIP/{endpoint}-%'")
            assert len(rows) == 1, rows
            return json.loads(rows[0][0])

        position = marker()

        with subtest("CDR and CEL: a blind transfer"):
            before = position
            caller.call("102")
            wait_bridged(pbx, "101", "102")
            callee.transfer("103")
            wait_bridged(pbx, "101", "103")
            caller.hangup()
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # the first record takes 103 as dst if 101's snapshot from leaving the bridge,
            # which names 103 already (main/bridge_channel.c:316), reaches the CDR engine
            # before 102's hangup ends the record (main/cdr.c:2119-2122), and keeps 102, as
            # Asterisk's CDR specification has, if after; each channel leaves in its own thread
            # TODO: expect one dst once Asterisk writes the same one every time
            assert cdrs in (
                [("101", "103", "101", "102", "Dial", "ANSWERED"), ("101", "103", "101", "103", "Dial", "ANSWERED")],
                [("101", "102", "101", "102", "Dial", "ANSWERED"), ("101", "103", "101", "103", "Dial", "ANSWERED")],
            ), cdrs
            assert legs(events) == expected_legs(["101", "102", "103"]), events
            assert who(events, "BLINDTRANSFER") == ["102"] and len(who(events, "LINKEDID_END")) == 1, events
            transfer = extra(before, "BLINDTRANSFER", "102")
            assert (transfer["extension"], transfer["context"]) == ("103", "internal"), transfer
            # the columns hold what they are named after: the caller's channel starts the call's linkedid
            caller_start, callee_start = table(
                f"select exten, context, channame, uniqueid, linkedid from cel where eventtype = 'CHAN_START' and rowid > {before[2]} order by rowid limit 2"
            )
            assert caller_start[:2] == ["102", "internal"] and re.fullmatch(r"PJSIP/101-[0-9a-f]+", caller_start[2]), caller_start
            assert re.fullmatch(r"[0-9.]+", caller_start[3]) and caller_start[4] == caller_start[3], caller_start
            assert re.fullmatch(r"PJSIP/102-[0-9a-f]+", callee_start[2]) and callee_start[4] == caller_start[3], callee_start

        with subtest("CDR and CEL: an attended transfer"):
            caller.call("102")
            wait_bridged(pbx, "101", "102")
            held = callee.current_call()
            callee.hold()
            callee.call("103")
            wait_bridged(pbx, "102", "103")
            callee.transfer_replaces(held)
            wait_bridged(pbx, "101", "103")
            pbx.wait_until_fails("asterisk -rx 'core show channels concise' | grep -q '^PJSIP/102-'")
            caller.hangup()
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # the specification has three records, the last with dst 103; Asterisk
            # also pairs 103 with the 102 it replaces in the caller's bridge
            assert cdrs == sorted([
                ("101", "102", "101", "102", "Dial", "ANSWERED"),
                ("102", "103", "102", "103", "Dial", "ANSWERED"),
                ("101", "102", "101", "103", "Dial", "ANSWERED"),
                ("103", "", "103", "102", "AppDial", "ANSWERED"),
            ]), cdrs
            assert legs(events) == expected_legs(["101", "102", "102", "103"]), events
            assert who(events, "ATTENDEDTRANSFER") == ["102"] and len(who(events, "LINKEDID_END")) == 2, events

        with subtest("CDR and CEL: a conference"):
            for p in (caller, callee, target):
                p.call("800")
                pbx.wait_until_succeeds(f"asterisk -rx 'confbridge list 800' | grep -q '^PJSIP/{p.user}-'")
            for p in (caller, callee, target):
                p.hangup()
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # one record for each pair, as the specification has, and Asterisk
            # adds one of its own for the last to join
            assert cdrs == [
                ("101", "800", "101", "102", "ConfBridge", "ANSWERED"),
                ("101", "800", "101", "103", "ConfBridge", "ANSWERED"),
                ("102", "800", "102", "103", "ConfBridge", "ANSWERED"),
                ("103", "800", "103", "", "ConfBridge", "ANSWERED"),
            ], cdrs
            assert legs(events) == expected_legs(["101", "102", "103"]), events
            assert who(events, "BRIDGE_ENTER") == ["101", "102", "103"] and len(who(events, "LINKEDID_END")) == 3, events

        with subtest("CDR and CEL: a queue"):
            target.call("902")
            wait_bridged(pbx, "103", "101")
            target.hangup()
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            assert cdrs == [("103", "902", "103", "101", "Queue", "ANSWERED"), ("103", "902", "103", "104", "Queue", "NO ANSWER")], cdrs
            assert legs(events) == expected_legs(["101", "103"], unanswered=["104"]), events
            assert len(who(events, "LINKEDID_END")) == 1, events

        with subtest("CDR and CEL: a ring group"):
            before = position
            target.call("901")
            wait_bridged(pbx, "103", "102")
            target.hangup()
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # with unanswered off too: the phone that only rang was offered the call
            assert cdrs == [("103", "901", "103", "102", "Dial", "ANSWERED"), ("103", "901", "103", "104", "Dial", "NO ANSWER")], cdrs
            assert legs(events) == expected_legs(["102", "103"], unanswered=["104"]), events
            assert len(who(events, "LINKEDID_END")) == 1, events
            hangup = extra(before, "HANGUP", "103")
            assert (hangup["hangupcause"], hangup["dialstatus"]) == (16, "ANSWER"), hangup

        with subtest("CDR and CEL: an unanswered call that reaches no phone"):
            before = position
            ended = target.disconnects()
            target.call("904")
            target.wait_disconnected(after=ended)
            wait_idle(pbx)
            cdrs, events, position = records_since(position)
            # unanswered is off
            assert cdrs == [], cdrs
            assert legs(events) == expected_legs([], unanswered=["103"]), events
            hangup = extra(before, "HANGUP", "103")
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

        with subtest("AMI users receive every event of 128 calls at once"):
            ami_listen(pbx, "ami-secret", "calls", "everything")
            answers = ami("run", "dialer", "ami-secret", "--times", "128", "Originate", "Channel=Local/s@flood", "Application=Wait", "Data=60", "Async=true")
            assert answers.count("Response: Success") == 128, answers
            pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -qx '256 active channels'")
            asterisk(pbx, "dialplan set global RELEASE 1")
            wait_idle(pbx)
            ami_done(pbx, "dialer", "ami-secret", "calls", "everything")
            for user in ["calls", "everything"]:
                counts = json.loads(pbx.succeed(
                    f"jq -s '[.[] | select(.Channel // \"\" | startswith(\"Local/s@flood-\")) | .Event] | group_by(.) | map({{key: .[0], value: length}}) | from_entries' /tmp/ami-{user}.json"
                ))
                assert (counts.get("Newchannel"), counts.get("Hangup"), counts.get("OriginateResponse")) == (256, 256, 128), (user, counts)

        with subtest("conference profiles, queues and music on hold are loaded"):
            assert "board" in asterisk(pbx, "confbridge show profile bridges")
            assert "chair" in asterisk(pbx, "confbridge show profile users")
            assert "chair_menu" in asterisk(pbx, "confbridge show menus")
            queue = asterisk(pbx, "queue show support")
            assert "rrmemory" in queue and "PJSIP/101" in queue and "Bob" in queue, queue
            classes = asterisk(pbx, "moh show classes")
            assert "Class: office" in classes and "office-moh" in classes, classes
            assert "hold" in asterisk(pbx, "moh show files")
      '';
  }
