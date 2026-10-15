# Core service behaviour with a freeform (layer 1) configuration of phones, a
# trunk and the dialplan, next to typed AMI, ARI and call records: the default
# modules load in the sandbox, secret values Asterisk reads as written reach
# it and a phone registers with one, the rendered configuration is private to
# the asterisk user, the daemon runs unprivileged and sandboxed, the CLI
# wrapper only talks to the running daemon and never starts one, a reload
# with a missing secret file fails and leaves Asterisk as it was, and
# logrotate rotates the log file, queue_log and the CSV CDRs while Asterisk
# goes on in new ones. Every kind of secret is then used (a phone's and a
# trunk's password, voicemail PINs, AMI and ARI secrets, a PIN inside a
# dialplan application's argument) with verbose and debug output at level
# 10, and each secret is looked for in the store, the journal, the arguments
# of every program the unit started, Asterisk's environment and every file
# outside the rendered configuration.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-core";

  nodes = {
    pbx = {config, ...}: let
      inherit (config.lib.asterisk) secret;
      inherit (pkgs) lib;

      # prints `<place> <name>` for each place outside the rendered
      # configuration, the unit's credentials and /run/test-secrets that holds
      # a secret: the journal, the arguments of every program the unit
      # started, what runs now, Asterisk's environment and files
      findSecrets = pkgs.writeShellApplication {
        name = "find-secrets";
        runtimeInputs = with pkgs; [
          audit
          coreutils
          gnugrep
          gnused
          systemd
        ];
        text = ''
          # a line `<name> <bytes>` per secret
          patterns=$1
          work=/run/test-secrets/scan
          mkdir -p "$work"
          journalctl -b -o export > "$work/journal"
          ausearch -m EXECVE,PROCTITLE -i > "$work/programs"
          for process in /proc/[0-9]*; do
            # a process can end while this reads it
            tr '\0' ' ' < "$process/cmdline" 2> /dev/null || true
            echo
          done > "$work/processes"
          tr '\0' '\n' < "/proc/$(systemctl show -P MainPID asterisk.service)/environ" > "$work/environment"
          while read -r name bytes; do
            for place in journal programs processes environment; do
              if grep -qaF -- "$bytes" "$work/$place"; then
                echo "$place $name"
              fi
            done
            status=0
            # /etc/asterisk is a link, which grep follows only when named
            grep -rlaF -D skip --exclude-dir='.config.*' --exclude-dir=credentials --exclude-dir=test-secrets --exclude-dir=journal -- "$bytes" \
              /etc /etc/asterisk/ /var /run /tmp /root /home /dev/shm /nix/.rw-store > "$work/files" || status=$?
            # grep exits with 1 when no file holds the bytes
            if [ "$status" -gt 1 ]; then
              exit "$status"
            fi
            sed "s|$| $name|" "$work/files"
          done < "$patterns"
        '';
      };
    in {
      imports = [
        self.nixosModules.asterisk
        ./freeform.nix
        ./common.nix
        (import ./secrets.nix {
          fixed = {
            # characters that need care in Asterisk config files and in shells
            sip-102 = ''p;w&d,\x"$HOME'';
            vm-101 = "1234";
          };
          random = [
            "sip-101"
            "ami"
            "ari"
            "trunk"
          ];
          randomDigits = [
            "vm-102"
            "pin"
          ];
        })
      ];

      services.asterisk = {
        settings = {
          "pjsip.conf" = {
            # a trunk that registers to an account of this Asterisk and calls
            # through it, so its password is sent and checked
            trunk = {
              type = "endpoint";
              context = "provider";
              disallow = "all";
              allow = "ulaw";
              outbound_auth = "trunk";
              aors = "trunk";
              from_user = "provider";
            };
            trunk-auth = {
              name = "trunk";
              type = "auth";
              username = "provider";
              password = secret "/run/test-secrets/trunk";
            };
            trunk-aor = {
              name = "trunk";
              type = "aor";
              contact = "sip:127.0.0.1:5060";
            };
            trunk-registration = {
              name = "trunk";
              type = "registration";
              outbound_auth = "trunk";
              server_uri = "sip:127.0.0.1:5060";
              client_uri = "sip:provider@127.0.0.1:5060";
              retry_interval = 5;
            };
            provider = {
              type = "endpoint";
              context = "provider";
              disallow = "all";
              allow = "ulaw";
              auth = "provider";
              aors = "provider";
            };
            provider-auth = {
              name = "provider";
              type = "auth";
              username = "provider";
              password = secret "/run/test-secrets/trunk";
            };
            provider-aor = {
              name = "provider";
              type = "aor";
              max_contacts = 1;
            };
          };
          "extensions.conf" = {
            phones.exten = [
              "700,1,Answer()"
              "700,n,Authenticate(${secret "/run/test-secrets/pin"})"
              "700,n,Hangup()"
              "*98,1,VoiceMailMain(102@default)"
              "*98,n,Hangup()"
              "_9X.,1,Dial(PJSIP/\${EXTEN:1}@trunk,20)"
              "_9X.,n,Hangup()"
            ];
            provider.exten = [
              "_X.,1,Answer()"
              "_X.,n,Wait(20)"
              "_X.,n,Hangup()"
            ];
            # channels whose records and log lines the logrotate subtest
            # looks for
            logged.exten = [
              "s,1,Answer()"
              "s,n,Hangup()"
            ];
          };
          "voicemail.conf".default."102" = "${secret "/run/test-secrets/vm-102"},Leak test";
          "modules.conf".modules.load = ["app_authenticate.so"];
          # verbose output at level 10 on standard output, which is the
          # journal; `core set verbose` only sets it for a remote console
          "asterisk.conf".options.verbose = 10;
        };

        ami = {
          enable = true;
          users.monitor = {
            secret = secret "/run/test-secrets/ami";
            write = ["system"];
          };
        };
        http.enable = true;
        ari = {
          enable = true;
          users.app.password = secret "/run/test-secrets/ari";
        };
        cdr = {
          csv.enable = true;
          sqlite.enable = true;
        };
        cel = {
          enable = true;
          sqlite.enable = true;
        };
        logger = {
          channels = {
            console = [
              "notice"
              "warning"
              "error"
              "verbose"
              "debug"
            ];
            full = ["verbose"];
          };
          queueLog = true;
        };
      };

      # logrotate runs only when the test starts it, and then rotates every
      # file; NixOS turns it off in tests (testing/test-instrumentation.nix)
      services.logrotate = {
        enable = true;
        extraArgs = ["--force"];
      };
      systemd.services.logrotate.startAt = lib.mkForce [];

      users.users = {
        operator = {
          isNormalUser = true;
          extraGroups = ["asterisk"];
        };
        visitor.isNormalUser = true;
      };

      # every program the unit starts, with its arguments
      security.auditd.enable = true;
      security.audit.rules = ["-a always,exit -F arch=b64 -S execve,execveat -F euid=${toString config.ids.uids.asterisk}"];
      # all of Asterisk's debug output reaches the journal
      services.journald.rateLimitBurst = 0;

      environment.systemPackages = [
        findSecrets
        pkgs.curl
      ];
    };

    phones = {
      imports = [
        ./common.nix
        ./phone.nix
      ];
    };
  };

  testScript = {nodes, ...}: ''
    ${builtins.readFile ./phone.py}
    def ast(command):
        return pbx.succeed(f"asterisk -rx {shlex.quote(command)}")

    start_all()
    pbx.wait_for_unit("asterisk.service")

    with subtest("default modules load without errors"):
        # a line journald has not read yet is not in the journal
        pbx.succeed("journalctl --sync")
        pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|WARNING|Error loading module|declined to load|not permitted'")
        modules = ast("module show like pjsip")
        assert "chan_pjsip.so" in modules, modules

    with subtest("secrets reach Asterisk as written, and a phone registers with one"):
        random = pbx.succeed("cat /run/test-secrets/sip-101").strip()
        assert random in ast("pjsip show auth 101")
        auth = ast("pjsip show auth 102")
        assert 'p;w&d,\\x"$HOME' in auth, auth
        # a PIN next to plain text in a mailbox line
        pin = ast("dialplan eval function VM_INFO(101@default,password)")
        assert "Result: 1234\n" in pin, pin
        assert "Result: Front desk\n" in ast("dialplan eval function VM_INFO(101@default,fullname)")
        password102 = pbx.succeed("cat /run/test-secrets/sip-102").rstrip("\n")
        phone102 = Phone(phones, "102", "102", password102, "pbx", sip_port=5071, cli_port=2301)
        phone102.start()
        wait_registrations({phone102: 200})
        phone102.stop()

    with subtest("rendered configuration is private to the asterisk user"):
        pbx.succeed("test \"$(stat -L -c '%U:%G %a' /run/asterisk/config)\" = 'asterisk:asterisk 500'")
        pbx.succeed("test \"$(stat -c '%U:%G %a' /run/asterisk/config/pjsip.conf)\" = 'asterisk:asterisk 400'")
        pbx.succeed("test \"$(stat -c '%U:%G %a' /run/asterisk)\" = 'asterisk:asterisk 750'")
        pbx.succeed(f"grep -qF {shlex.quote(random)} /run/asterisk/config/pjsip.conf")
        pbx.succeed("grep -qF 'password = p\;w&d' /run/asterisk/config/pjsip.conf")
        pbx.fail("grep -q '@NIX_ASTERISK_SECRET:' /run/asterisk/config/*")
        pbx.fail("su -s /bin/sh nobody -c 'cat /run/asterisk/config/pjsip.conf'")
        # every file 0400 and every directory 0500, not only pjsip.conf
        pbx.succeed("test -z \"$(find /run/asterisk/config/ \\( -type f ! -perm 0400 \\) -o \\( -type d ! -perm 0500 \\) -o ! -user asterisk -o ! -group asterisk)\"")

    with subtest("daemon runs unprivileged and sandboxed"):
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.succeed(f"test \"$(stat -c %U /proc/{pid})\" = asterisk")
        for field in ["CapEff", "CapBnd", "CapAmb"]:
            pbx.succeed(f"grep -q '^{field}:\\s*0*$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^NoNewPrivs:\\s*1$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^Seccomp:\\s*2$' /proc/{pid}/status")
        # with AMI and HTTP on, none of the relaxations of the sandbox: no
        # capability, since no port is below 1024, and no realtime scheduling
        properties = dict(
            line.split("=", 1)
            for line in pbx.succeed("systemctl show -p CapabilityBoundingSet -p AmbientCapabilities -p RestrictRealtime -p CPUSchedulingPolicy -p LimitRTPRIO asterisk.service").splitlines()
        )
        assert properties == {
            "CapabilityBoundingSet": "",
            "AmbientCapabilities": "",
            "RestrictRealtime": "yes",
            "CPUSchedulingPolicy": "0",
            "LimitRTPRIO": "0",
        }, properties
        # an exposure of 1.5 at most
        print(pbx.succeed("systemd-analyze security --threshold=15 asterisk.service").splitlines()[-1])

    with subtest("CLI wrapper only talks to the running daemon, and never starts one"):
        pbx.succeed("asterisk -rx 'core show version' | grep -qF 'Asterisk ${nodes.pbx.services.asterisk.package.version} '")
        pbx.succeed("rasterisk -x 'core show uptime'")
        pbx.succeed("asterisk -V")
        # -x implies -r to Asterisk
        pbx.succeed("asterisk -x 'core show uptime'")
        # the control socket takes members of the asterisk group, and no one else
        pbx.succeed("su -l operator -c \"asterisk -rx 'core show uptime'\"")
        refused = pbx.fail("su -l visitor -c \"asterisk -rx 'core show uptime'\" 2>&1")
        assert "Unable to connect to remote asterisk" in refused, refused
        # with the service stopped, Asterisk would start a daemon for whatever
        # the wrapper does not refuse, also an -r it does not read as an option
        pbx.succeed("systemctl stop asterisk.service")
        for arguments in ["", "-c", "-- -r", "-C -r", "-Cr"]:
            pbx.fail(f"asterisk {arguments}")
        pbx.fail("pgrep -x asterisk")
        pbx.succeed("systemctl start asterisk.service")

    with subtest("a missing secret file fails the reload, which leaves Asterisk as it was"):
        pbx.succeed("mv /run/test-secrets/sip-102 /run/test-secrets/sip-102.away")
        pbx.fail("systemctl reload asterisk.service")
        assert 'p;w&d,\\x"$HOME' in ast("pjsip show auth 102")
        pbx.succeed("mv /run/test-secrets/sip-102.away /run/test-secrets/sip-102")
        pbx.succeed("systemctl reload asterisk.service")

    with subtest("logrotate rotates the log file, queue_log and the CSV CDRs, and Asterisk goes on in new files"):
        files = ["full", "queue_log", "cdr-csv/Master.csv"]
        # a call record, so that every file has lines to rotate
        ast("channel originate Local/s@logged application NoOp")
        pbx.wait_until_succeeds("grep -q '\"logged\"' /var/log/asterisk/cdr-csv/Master.csv", timeout=60)
        pbx.succeed("systemctl start logrotate.service")
        rotated = {file: pbx.succeed(f"stat -c '%U %s' /var/log/asterisk/{file}.1").split() for file in files}
        assert all(owner == "asterisk" and int(size) > 0 for owner, size in rotated.values()), rotated
        # what logger reload writes first
        pbx.succeed("grep -q CONFIGRELOAD /var/log/asterisk/queue_log")
        ast("channel originate Local/s@logged application NoOp")
        pbx.wait_until_succeeds("grep -q '\"logged\"' /var/log/asterisk/cdr-csv/Master.csv", timeout=60)
        pbx.wait_until_succeeds("grep -q 'Executing \\[s@logged:1\\]' /var/log/asterisk/full")
        assert {file: pbx.succeed(f"stat -c '%U %s' /var/log/asterisk/{file}.1").split() for file in files} == rotated

    with subtest("every kind of secret is used, with verbose and debug output at level 10"):
        for command in ["core set debug 10", "pjsip set logger on", "manager set debug on"]:
            ast(command)
        secrets = {name: pbx.succeed(f"cat /run/test-secrets/{name}") for name in ["sip-101", "ami", "ari", "vm-102"]}
        # the trunk registers to the account with its password
        pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -qE '^ trunk/sip:127.0.0.1:5060 .* Registered '")
        phone = Phone(phones, "101", "101", secrets["sip-101"], "pbx")
        phone.start()
        wait_registrations({phone: 200})
        # AMI takes its secret in plain text, and its debug output leaves it out
        cursor = journal_cursor(pbx)
        login = f"Action: Login\r\nUsername: monitor\r\nSecret: {secrets['ami']}\r\n\r\nAction: Logoff\r\n\r\n"
        answer = pbx.succeed(f"exec 3<>/dev/tcp/127.0.0.1/5038; printf %s {shlex.quote(login)} >&3; timeout 5 cat <&3 || true")
        assert "Authentication accepted" in answer, answer
        wait_journal(pbx, cursor, "Secret: <redacted from logging>")
        # ARI takes it by HTTP basic authentication
        pbx.succeed(f"curl -sf -u app:{secrets['ari']} http://127.0.0.1:8088/ari/applications")
        # the caller keys in the voicemail PIN
        phone.call("*98")
        wait_journal(pbx, cursor, "Playing 'vm-password")
        phone.dtmf(secrets["vm-102"] + "#")
        wait_journal(pbx, cursor, "Playing 'vm-youhave")
        phone.hangup()
        wait_idle(pbx)
        # and hangs up while Authenticate asks for the PIN its argument holds
        phone.call("700")
        wait_channel(pbx, "101", app="Authenticate", state="Up")
        phone.hangup()
        wait_idle(pbx)
        # a call through the trunk, whose password answers the account's challenge
        phone.call("9555")
        wait_channel(pbx, "provider", app="Wait", state="Up")
        phone.hangup()
        wait_idle(pbx)
        # a reload renders every file and Asterisk reads them again
        pbx.succeed("systemctl reload asterisk.service")
        for command in ["core set debug 0", "pjsip set logger off", "manager set debug off"]:
            ast(command)

    with subtest("secrets are nowhere but in the rendered configuration"):
        # the store paths of the configuration and the unit hold placeholders
        template = pbx.succeed("readlink -f /etc/asterisk").strip()
        unit = pbx.succeed("readlink -f /etc/systemd/system/asterisk.service").strip()
        closure = pbx.succeed(f"nix-store -qR {template} {unit} | grep -v -- '-asterisk-[0-9.]*$'").split()
        pbx.fail(f"grep -rlF {shlex.quote(random)} {' '.join(closure)}")
        pbx.fail(f"grep -rlF 'p;w&d' {' '.join(closure)}")
        pbx.succeed(f"grep -q '@NIX_ASTERISK_SECRET:' {template}/pjsip.conf")
        # the audit log holds every program the unit started, with its arguments
        started = pbx.succeed("ausearch -m EXECVE -i")
        assert "render-secrets" in started and "core waitfullybooted" in started, started[-2000:]
        # vm-101 is 1234, too short to look for; ARI's password also goes out
        # in base64, as HTTP basic authentication sends it
        pbx.succeed(
            "cd /run/test-secrets"
            " && for name in sip-101 sip-102 ami ari trunk vm-102 pin; do printf '%s %s\\n' $name \"$(cat $name)\"; done > patterns"
            " && printf 'ari-basic %s\\n' \"$(printf app:%s \"$(cat ari)\" | base64 -w0)\" >> patterns"
        )
        # master.db-wal is part of master.db, whose records stay in it until
        # sqlite checkpoints them
        found = {
            (path.removesuffix("-wal"), name)
            for path, name in (line.split(" ", 1) for line in pbx.succeed("find-secrets /run/test-secrets/patterns").splitlines())
        }
        # Asterisk prints an application's arguments once it has substituted
        # them: the PIN inside Authenticate's is in the Executing line of the
        # journal and the full log, and in the call records' lastdata and appdata
        assert found == {
            ("journal", "pin"),
            ("/var/log/asterisk/full", "pin"),
            ("/var/log/asterisk/cdr-csv/Master.csv", "pin"),
            ("/var/log/asterisk/master.db", "pin"),
        }, found
  '';
}
