# Faults on the PBX machine itself, and what callers and the journal see.
# A secret the asterisk user can't read still reaches Asterisk, since systemd
# reads credentials as root; one that is a directory fails the reload, which
# keeps the old configuration, and a bad one fails the start, which systemd
# retries every 5 s until the file is fixed. An astdb Asterisk cannot open
# makes it exit as it starts, which fails the start at once, and systemd
# retries the same way. After SIGKILL systemd restarts Asterisk within
# seconds and every registration survives, while the call it carried goes
# silent; after SIGSTOP nothing notices: the unit stays active, the journal
# says nothing, and calls time out until SIGCONT, after which everything
# goes on without a restart. On a full /var/lib/asterisk a
# voicemail caller is cut off once recording starts, leaving an empty message
# that counts, and an astdb write fails with a vague warning; on a full
# /var/log/asterisk the SQLite CDR is logged with its record and the CSV one
# is cut short without a word; both recover once space is freed. A clock step
# leaves opening hours right, but a step back keeps a phone ringing past its
# ring time and a step forward expires every registration at once and hangs
# up the call in progress, since Asterisk counts the RTP timeout pbx gives an
# extension by the wall clock. 1,000 TCP
# phones take one file each, far below LimitNOFILE; pjproject holds at most
# 5,000 connections, and past that a new TCP phone is closed on without a log
# line, while calls go on and it registers once connections are freed.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  names = {
    "201" = "Anna";
    "202" = "Ben";
    "203" = "Cara";
  };

  tcpPhones = map (n: "tcp${toString n}") (lib.range 1000 1999);

  # a filesystem the test can fill up
  small = config: size: {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "size=${size}"
      "mode=0750"
      "uid=${toString config.ids.uids.asterisk}"
      "gid=${toString config.ids.gids.asterisk}"
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-faults";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {sip-tcp = "pw-tcp";}
              // lib.concatMapAttrs (extension: _: {
                "sip-${extension}" = "pw-${extension}";
                "vm-${extension}" = "4${extension}";
              })
              names;
          })
        ];
        virtualisation = {
          # 5,000 TCP connections
          memorySize = 2048;
          fileSystems = {
            "/var/lib/asterisk" = small config "64M";
            "/var/log/asterisk" = small config "16M";
          };
        };

        pbx = {
          enable = true;
          extensions =
            lib.mapAttrs (extension: name: {
              inherit name;
              password = secret "sip-${extension}";
              voicemail.pin = secret "vm-${extension}";
              ringTime = 5;
            })
            names;
          hours.office = {
            timezone = "UTC";
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
            closeEarly = "*28";
          };
        };

        services.asterisk = {
          openFirewall = true;
          # the test follows calls through verbose messages in the journal
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
          cdr = {
            csv.enable = true;
            sqlite.enable = true;
          };
          pjsip = {
            transports = {
              udp = {};
              tcp.protocol = "tcp";
            };
            # the TCP phones SIPp plays; they share an auth user, since SIPp
            # takes the digest's user from its command line
            endpoints = lib.genAttrs tcpPhones (_: {
              context = "faults";
              auth = {
                username = "tcp";
                password = secret "sip-tcp";
              };
              aor.qualifyFrequency = 0;
            });
          };
          dialplan.contexts.faults.extensions.hours = [
            "Gosub(pbx-hours-office,s,1)"
            "Verbose(0,hours \${GOSUB_RETVAL})"
          ];
        };
      };

      phones = {pkgs, ...}: {
        imports = [
          ./common.nix
          ./phone.nix
          ./sipp.nix
        ];
        # opens idle connections to the PBX
        environment.systemPackages = [pkgs.python3];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        PBX = pbx.succeed("ip -4 -o address show eth1 | awk '{print $4}' | cut -d/ -f1").strip()

        # registrations of 60 s, so the phones come back soon after they expire
        anna = Phone(phones, "anna", "201", "pw-201", "pbx", sip_port=5060, cli_port=2300, options="--reg-timeout=60")
        ben = Phone(phones, "ben", "202", "pw-202", "pbx", sip_port=5061, cli_port=2301, options="--reg-timeout=60")
        cara = Phone(phones, "cara", "203", "pw-203", "pbx", sip_port=5062, cli_port=2302, auto_answer=180, options="--reg-timeout=60")
        everyone = [anna, ben, cara]

        def main_pid():
            return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        def registers():
            return {p.name: p.count("TX [0-9]+ bytes Request msg REGISTER") for p in everyone}

        def refresh_registrations():
            """Have every phone register again now, so that none refreshes
            in the next 50 s, and return the REGISTERs they sent so far"""
            before = registers()
            cli_parallel([(p, "acc reg") for p in everyone])
            deadline = time.time() + 30
            # a refresh may be challenged or not, so wait until no more come
            while True:
                sent = registers()
                time.sleep(2)
                if registers() == sent and all(sent[name] > count for name, count in before.items()):
                    break
                assert time.time() < deadline, (before, sent)
            wait_contacts(pbx, 3)
            return sent

        def disconnect_reason(phone):
            return re.findall(r"is DISCONNECTED \[reason=(\d+)", phone.log_text())[-1]

        def hours():
            """What pbx-hours-office returns now"""
            cursor = journal_cursor(pbx)
            asterisk(pbx, "channel originate Local/hours@faults application Wait 1")
            wait_journal(pbx, cursor, ": hours (open|closed)$")
            return re.findall(r": hours (open|closed)$", journal_since(pbx, cursor), re.M)[-1]

        def toggle_close_early():
            calls = anna.disconnects()
            anna.call("*28")
            anna.wait_disconnected(after=calls, timeout=30)
            wait_idle(pbx)

        def leave_message():
            """anna calls cara, who doesn't answer, and speaks after the beep"""
            cursor = journal_cursor(pbx)
            anna.call("203")
            wait_journal(pbx, cursor, "Recording the message", timeout=60)
            return cursor

        with subtest("phones register, on a Wednesday at 10:00 in the office's time zone"):
            pbx.succeed("date -u -s '2026-12-02 10:00'")
            start_phones(everyone)
            wait_registrations({p: 200 for p in everyone})

        with subtest("a secret the asterisk user can't read reaches Asterisk, since systemd reads it as root"):
            pbx.succeed("chmod 0000 /run/test-secrets/sip-203")
            pbx.succeed("systemctl reload asterisk.service")
            pbx.succeed("systemctl restart asterisk.service")
            assert "pw-203" in asterisk(pbx, "pjsip show auth 203")
            pbx.succeed("chmod 0400 /run/test-secrets/sip-203")

        with subtest("a secret that is a directory fails the reload, which keeps the old configuration"):
            pbx.succeed("mv /run/test-secrets/sip-203 /run/test-secrets/sip-203.away && mkdir /run/test-secrets/sip-203")
            cursor = journal_cursor(pbx)
            pbx.fail("systemctl reload asterisk.service")
            wait_journal(pbx, cursor, r"secret /run/test-secrets/sip-203 \(credential secret-[0-9a-f]+\) is not available")
            assert "pw-203" in asterisk(pbx, "pjsip show auth 203")
            pbx.succeed("rmdir /run/test-secrets/sip-203 && mv /run/test-secrets/sip-203.away /run/test-secrets/sip-203")

        with subtest("a bad secret fails the start with a message saying it contains a line break, systemd retries, and the fixed file brings Asterisk up"):
            pbx.succeed("printf 'a\\nb' > /run/test-secrets/sip-203")
            cursor = journal_cursor(pbx)
            pbx.fail("systemctl restart asterisk.service")
            wait_journal(pbx, cursor, "secret /run/test-secrets/sip-203 contains a line break")
            wait_journal(pbx, cursor, "Scheduled restart job", timeout=30)
            pbx.succeed("printf pw-203 > /run/test-secrets/sip-203")
            pbx.wait_for_unit("asterisk.service", timeout=30)
            wait_contacts(pbx, 3)

        with subtest("an astdb Asterisk cannot open makes it exit as it starts, which fails the start at once, and systemd retries"):
            pbx.succeed("mv /var/lib/asterisk/astdb.sqlite3 /var/lib/asterisk/astdb.sqlite3.away && mkdir /var/lib/asterisk/astdb.sqlite3")
            cursor = journal_cursor(pbx)
            pbx.succeed("systemctl restart --no-block asterisk.service")
            wait_journal(pbx, cursor, "ASTdb initialization failed")
            # and not once the wait for its control socket has run out
            wait_journal(pbx, cursor, "Failed with result 'exit-code'", timeout=10)
            wait_journal(pbx, cursor, "Scheduled restart job", timeout=30)
            pbx.succeed("systemctl stop asterisk.service")
            pbx.succeed("rmdir /var/lib/asterisk/astdb.sqlite3 && mv /var/lib/asterisk/astdb.sqlite3.away /var/lib/asterisk/astdb.sqlite3")
            pbx.succeed("systemctl start asterisk.service")
            wait_contacts(pbx, 3)

        with subtest("after SIGKILL systemd restarts Asterisk, every registration survives, and the call it carried goes silent"):
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [anna, ben])
            before = refresh_registrations()
            pid = main_pid()
            cursor = journal_cursor(pbx)
            pbx.succeed(f"kill -KILL {pid}")
            wait_journal(pbx, cursor, "Main process exited, code=killed, status=9/KILL")
            # RestartSec is 5 s
            pbx.wait_until_succeeds(f"test \"$(systemctl show -P MainPID asterisk.service)\" != {pid}", timeout=15)
            pbx.wait_for_unit("asterisk.service", timeout=30)
            wait_contacts(pbx, 3)
            assert registers() == before, (before, registers())
            # the phones keep a call no one relays, until someone hangs up
            received = rtp_received([anna, ben])
            time.sleep(3)
            assert rtp_received([anna, ben]) == received, received
            assert "You have 1 active call" in ben.cli("call list")
            anna.hangup()
            ben.hangup()
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [anna, ben])

        with subtest("after SIGSTOP nothing notices: calls time out and the journal is silent until SIGCONT"):
            stats = channel_stats(pbx)
            pid = main_pid()
            cursor = journal_cursor(pbx)
            pbx.succeed(f"kill -STOP {pid}")
            calls = cara.disconnects()
            cara.call("201")
            # the INVITE's transaction times out after 32 s
            cara.wait_disconnected(after=calls, timeout=60)
            assert disconnect_reason(cara) == "408", cara.log_text()[-2000:]
            # Asterisk sends systemd no watchdog notifications
            assert pbx.succeed("systemctl show -P ActiveState,SubState asterisk.service").split() == ["active", "running"]
            assert "-- No entries --" in journal_since(pbx, cursor)
            pbx.succeed(f"kill -CONT {pid}")
            # the call goes on, the late INVITE rings no one, and the phones
            # whose registrations lapsed meanwhile register again
            wait_calls_continue(pbx, [anna, ben], stats)
            assert anna.requests("INVITE") == 0
            wait_contacts(pbx, 3)
            assert main_pid() == pid
            anna.hangup()
            wait_idle(pbx)

        inbox = "/var/lib/asterisk/spool/voicemail/default/203/INBOX"

        with subtest("on a full /var/lib/asterisk a voicemail caller is cut off, an empty message counts, and astdb writes fail"):
            pbx.execute("dd if=/dev/zero of=/var/lib/asterisk/filler bs=4k")
            calls = anna.disconnects()
            cursor = leave_message()
            wait_journal(pbx, cursor, r"\[C-[0-9a-f]+\]: format_wav\.c:[0-9]+ wav_write: Bad write \([0-9]+\): No space left on device")
            anna.wait_disconnected(after=calls, timeout=10)
            pbx.succeed(f"test -e {inbox}/msg0000.txt && test ! -s {inbox}/msg0000.txt && test ! -s {inbox}/msg0000.wav")
            # the close-early toggle holds its state in memory, not in astdb
            cursor = journal_cursor(pbx)
            toggle_close_early()
            wait_journal(pbx, cursor, "ast_db_put: Couldn't execute statement: SQL logic error")
            assert "State:InUse" in asterisk(pbx, "core show hint *28")
            assert "0 results found." in asterisk(pbx, "database show CustomDevstate")

        with subtest("once there is space again, messages and astdb writes are stored"):
            pbx.succeed("rm /var/lib/asterisk/filler")
            leave_message()
            time.sleep(4)
            anna.hangup()
            wait_idle(pbx)
            pbx.succeed(f"test -s {inbox}/msg0001.txt && test -s {inbox}/msg0001.wav")
            assert "Result: 2\n" in asterisk(pbx, "dialplan eval function VM_INFO(203@default,count)")
            toggle_close_early()
            assert re.search(r"/CustomDevstate/pbx-hours-office +: NOT_INUSE", asterisk(pbx, "database show CustomDevstate"))

        with subtest("on a full /var/log/asterisk the SQLite CDR is logged with its record, and the CSV one is cut short without a word"):
            csv = "/var/log/asterisk/cdr-csv/Master.csv"
            # a line of its own ends the file 100 bytes before a page ends, so
            # the next record starts on that page and doesn't fit on it
            size = int(pbx.succeed(f"stat -c %s {csv}"))
            pbx.succeed(f"printf '\"%0{(-size - 103) % 4096}d\"\\n' 0 >> {csv}")
            pbx.execute("dd if=/dev/zero of=/var/log/asterisk/filler bs=4k")
            cursor = journal_cursor(pbx)
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            anna.hangup()
            wait_idle(pbx)
            wait_journal(pbx, cursor, r"write_cdr: database or disk is full\. SQL: INSERT INTO cdr .*'PJSIP/201-")
            assert int(pbx.succeed(f"stat -c %s {csv}")) % 4096 == 0
            assert "cdr_csv" not in journal_since(pbx, cursor)
            pbx.succeed("rm /var/log/asterisk/filler")
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            anna.hangup()
            wait_idle(pbx)
            # the next record follows the cut one on its line
            last = pbx.succeed(f"tail -n 1 {csv}")
            assert last.count("pbx-extension-202") == 2, last

        with subtest("after a clock step back opening hours are right, and a phone rings past its ring time"):
            assert hours() == "open"
            anna.call("203")
            wait_channel(pbx, "203", state="Ringing", timeout=30)
            pbx.succeed("date -u -s '2026-12-02 08:00'")
            assert hours() == "closed"
            # Dial counts its 5 s by the wall clock, so cara would ring for
            # two hours and 5 s
            time.sleep(10)
            wait_channel(pbx, "203", state="Ringing", timeout=1)
            anna.hangup()
            wait_idle(pbx)

        with subtest("after a clock step forward opening hours are right, the RTP timeout hangs up the call, and every registration expires at once"):
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            wait_for_media_both_ways(pbx, [anna, ben])
            before = refresh_registrations()
            calls = {p.name: p.disconnects() for p in (anna, ben)}
            cursor = journal_cursor(pbx)
            pbx.succeed("date -u -s '2026-12-02 12:00'")
            assert hours() == "open"
            # Asterisk checks the RTP timeout once the clock passes the time
            # it is due, and counts the step as seconds without RTP
            wait_journal(pbx, cursor, r"Disconnecting channel 'PJSIP/20[12]-[0-9a-f]+' for lack of audio RTP activity", count=2, timeout=10)
            for p in (anna, ben):
                p.wait_disconnected(after=calls[p.name], timeout=10)
            # the registrar looks for expired contacts every 30 s, by the wall
            # clock
            wait_journal(pbx, cursor, "Removed contact .* due to expiration", count=3, timeout=40)
            assert registers() == before, (before, registers())
            assert "No objects found." in asterisk(pbx, "pjsip show contacts")
            wait_idle(pbx)
            # until each phone refreshes its registration
            wait_contacts(pbx, 3, timeout=90)

        with subtest("1,000 TCP phones register and take one file each, while a call goes on"):
            anna.call("202")
            wait_bridged(pbx, "201", "202")
            stats = wait_for_media_both_ways(pbx, [anna, ben])
            pid = main_pid()
            files = int(pbx.succeed(f"ls /proc/{pid}/fd | wc -l"))
            assert re.search(r"Max open files +65536 ", pbx.succeed(f"cat /proc/{pid}/limits"))
            phones.succeed(
                "(echo SEQUENTIAL; seq -f 'tcp%g;' 1000 1999) > /tmp/tcp-phones.csv",
                "systemd-run --unit=sipp-tcp --collect -p LimitNOFILE=4096 -E PATH "
                "sipp -sf /etc/sipp/register-stay.xml -inf /tmp/tcp-phones.csv -t tn -max_socket 1100 -m 1000 -r 200 -nostdin "
                f"-au tcp -ap pw-tcp {PBX}:5060",
            )
            pbx.wait_until_succeeds("test $(asterisk -rx 'pjsip show contacts' | grep -c '^ *Contact: *tcp1[0-9]*/') -eq 1000", timeout=120)
            assert int(pbx.succeed(f"ls /proc/{pid}/fd | wc -l")) <= files + 1010
            stats = wait_calls_continue(pbx, [anna, ben], stats)

        with subtest("past 5,000 TCP connections a new phone is closed on without a log line, and registers once they are freed"):
            phones.succeed(
                "cat > /tmp/idle.py <<'EOF'\n"
                "import resource, socket, sys, time\n"
                "resource.setrlimit(resource.RLIMIT_NOFILE, (8192, 8192))\n"
                "held = [socket.create_connection((sys.argv[1], 5060)) for _ in range(int(sys.argv[2]))]\n"
                "print('open', len(held), flush=True)\n"
                "time.sleep(3600)\n"
                "EOF"
            )
            cursor = journal_cursor(pbx)
            phones.succeed(f"systemd-run --unit=idle --collect python3 /tmp/idle.py {PBX} 4500")
            phones.wait_until_succeeds("journalctl -u idle | grep -q 'open 4500'", timeout=120)
            # PJ_IOQUEUE_MAX_HANDLES (5000) in the config_site.h of Asterisk's
            # pjproject, less the handles pjsip holds itself; pjsip closes
            # every connection past it
            pbx.wait_until_succeeds("n=$(ss -Htn state established '( sport = :5060 )' | wc -l); test $n -ge 4990 -a $n -le 5000", timeout=30)
            cara.stop()
            dora = Phone(phones, "dora", "203", "pw-203", f"{PBX};transport=tcp", sip_port=5063, cli_port=2303)
            dora.start()
            # pjsua gives a closed connection as 503
            wait_registrations({dora: 503})
            stats = wait_calls_continue(pbx, [anna, ben], stats)
            logged = journal_since(pbx, cursor)
            assert not re.search("NOTICE|WARNING|ERROR", logged), logged
            phones.succeed("systemctl stop idle")
            pbx.wait_until_succeeds("test $(ss -Htn state established '( sport = :5060 )' | wc -l) -eq 1000", timeout=30)
            # pjlib reuses a closed connection's slot only after 500 ms
            # (PJ_IOQUEUE_KEY_FREE_DELAY)
            time.sleep(1)
            dora.stop()
            dora.start()
            wait_registrations({dora: 200})
            wait_calls_continue(pbx, [anna, ben], stats)
      '';
  }
