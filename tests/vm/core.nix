# Core service behaviour with a purely freeform (layer 1) configuration: boot,
# config loading, secrets, runtime file permissions, sandboxing without
# relaxations, the CLI wrapper for users in and out of the asterisk group, a
# crash that leaves no core dump.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-core";

  nodes.pbx = {
    imports = [
      self.nixosModules.default
      ./freeform.nix
      ./common.nix
      (import ./secrets.nix {
        # characters that need care in Asterisk config files and in shells
        fixed.sip-102 = ''p;w&d,\x"$HOME'';
        fixed.vm-101 = "1234";
        random = ["sip-101"];
      })
    ];

    users.users = {
      operator = {
        isNormalUser = true;
        extraGroups = ["asterisk"];
      };
      visitor.isNormalUser = true;
    };
  };

  testScript = ''
    import re
    import shlex

    def ast(command):
        return pbx.succeed(f"asterisk -rx {shlex.quote(command)}")

    pbx.wait_for_unit("asterisk.service")

    with subtest("configuration is loaded"):
        endpoints = ast("pjsip show endpoints")
        assert "Endpoint:  101" in endpoints and "Endpoint:  102" in endpoints, endpoints
        dialplan = ast("dialplan show phones")
        assert "Dial(PJSIP/''${EXTEN},30)" in dialplan, dialplan
        assert "Hangup()" in dialplan, dialplan
        ast("pjsip show transport transport-udp")
        pbx.succeed("ss -Hlun 'sport = :5060' | grep -q 5060")

    with subtest("default modules load without errors"):
        # a line journald has not read yet is not in the journal
        pbx.succeed("journalctl --sync")
        pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|WARNING|Error loading module|declined to load|not permitted'")
        modules = ast("module show like pjsip")
        assert "chan_pjsip.so" in modules, modules

    with subtest("secrets reach Asterisk unchanged"):
        auth = ast("pjsip show auth 102")
        assert 'p;w&d,\\x"$HOME' in auth, auth
        random = pbx.succeed("cat /run/test-secrets/sip-101").strip()
        assert random in ast("pjsip show auth 101")
        pin = ast("dialplan eval function VM_INFO(101@default,password)")
        assert "Result: 1234\n" in pin, pin
        assert "Result: Front desk\n" in ast("dialplan eval function VM_INFO(101@default,fullname)")

    with subtest("secrets never reach the store or the logs"):
        template = pbx.succeed("readlink -f /etc/asterisk").strip()
        unit = pbx.succeed("readlink -f /etc/systemd/system/asterisk.service").strip()
        closure = pbx.succeed(f"nix-store -qR {template} {unit} | grep -v -- '-asterisk-[0-9.]*$'").split()
        pbx.fail(f"grep -rlF {shlex.quote(random)} {' '.join(closure)}")
        pbx.fail(f"grep -rlF 'p;w&d' {' '.join(closure)}")
        pbx.succeed(f"grep -q '@NIX_ASTERISK_SECRET:' {template}/pjsip.conf")
        pbx.succeed("journalctl --sync")
        pbx.fail(f"journalctl -b | grep -F {shlex.quote(random)}")
        pbx.fail(f"grep -rF {shlex.quote(random)} /var/log/asterisk /var/lib/asterisk")

    with subtest("rendered configuration is private to the asterisk user"):
        pbx.succeed("test \"$(stat -L -c '%U:%G %a' /run/asterisk/config)\" = 'asterisk:asterisk 500'")
        pbx.succeed("test \"$(stat -c '%U:%G %a' /run/asterisk/config/pjsip.conf)\" = 'asterisk:asterisk 400'")
        pbx.succeed("test \"$(stat -c '%U:%G %a' /run/asterisk)\" = 'asterisk:asterisk 750'")
        pbx.succeed(f"grep -qF {shlex.quote(random)} /run/asterisk/config/pjsip.conf")
        pbx.succeed("grep -qF 'password = p\;w&d' /run/asterisk/config/pjsip.conf")
        pbx.fail("grep -q '@NIX_ASTERISK_SECRET:' /run/asterisk/config/*")
        pbx.fail("su -s /bin/sh nobody -c 'cat /run/asterisk/config/pjsip.conf'")

    with subtest("daemon runs unprivileged and sandboxed"):
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.succeed(f"test \"$(stat -c %U /proc/{pid})\" = asterisk")
        for field in ["CapEff", "CapBnd", "CapAmb"]:
            pbx.succeed(f"grep -q '^{field}:\\s*0*$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^NoNewPrivs:\\s*1$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^Seccomp:\\s*2$' /proc/{pid}/status")
        # none of the relaxations of D16: no capability and no realtime
        # scheduling
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

    with subtest("state directories"):
        pbx.succeed("test -d /var/lib/asterisk/spool/voicemail")
        pbx.succeed("test -f /var/lib/asterisk/astdb.sqlite3")
        pbx.succeed("test \"$(stat -c %U /var/lib/asterisk)\" = asterisk")

    with subtest("CLI wrapper only talks to the running daemon"):
        pbx.succeed("asterisk -rx 'core show version' | grep -q 'Asterisk 22'")
        pbx.succeed("rasterisk -x 'core show uptime'")
        pbx.fail("asterisk -c")
        pbx.succeed("asterisk -V")
        # -x implies -r to Asterisk
        pbx.succeed("asterisk -x 'core show uptime'")
        # the control socket takes members of the asterisk group, and no one else
        pbx.succeed("su -l operator -c \"asterisk -rx 'core show uptime'\"")
        pbx.succeed("su -l operator -c \"rasterisk -x 'core show uptime'\"")
        refused = pbx.fail("su -l visitor -c \"asterisk -rx 'core show uptime'\" 2>&1")
        assert "Unable to connect to remote asterisk" in refused, refused
        # whatever would start a daemon is refused, whoever asks, also an -r
        # that Asterisk does not read as an option
        main = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        daemons = ["", "-c", "-- -r", "-C -r", "-Cr"]
        for user in ["root", "operator", "visitor"]:
            for arguments in daemons:
                pbx.fail(f"su -l {user} -c 'asterisk {arguments}'")
        assert pbx.succeed("pgrep -x asterisk").split() == [main]
        # and while the service is stopped, when Asterisk finds none running
        pbx.succeed("systemctl stop asterisk.service")
        for arguments in daemons:
            pbx.fail(f"asterisk {arguments}")
        pbx.fail("pgrep -x asterisk")
        pbx.succeed("systemctl start asterisk.service")

    with subtest("reload re-renders the configuration and rotated secrets"):
        pbx.succeed("printf 'rotated;pw' > /run/test-secrets/sip-102")
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.succeed("systemctl reload asterisk.service")
        assert pid == pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.wait_until_succeeds("asterisk -rx 'pjsip show auth 102' | grep -F 'rotated;pw'")

    with subtest("a comma in a secret that is one field of a mailbox line fails the reload"):
        # app_voicemail splits mailbox lines at every comma, which would make
        # this PIN 12 and the name 34
        pbx.succeed("printf '12,34' > /run/test-secrets/vm-101")
        pbx.fail("systemctl reload asterisk.service")
        # returns once journald has read what the reload wrote to its output
        pbx.succeed("journalctl --sync")
        pbx.succeed("journalctl -u asterisk.service | grep -F 'secret /run/test-secrets/vm-101 is one field of a comma-separated value'")
        pin = ast("dialplan eval function VM_INFO(101@default,password)")
        assert "Result: 1234\n" in pin, pin
        pbx.succeed("printf 1234 > /run/test-secrets/vm-101")
        pbx.succeed("systemctl reload asterisk.service")

    with subtest("a secret PIN longer than the 79 bytes Asterisk keeps fails the reload"):
        pbx.succeed("printf %080d 0 > /run/test-secrets/vm-101")
        pbx.fail("systemctl reload asterisk.service")
        pbx.succeed("journalctl --sync")
        pbx.succeed("journalctl -u asterisk.service | grep -F 'secret /run/test-secrets/vm-101 is longer than 79 bytes'")
        pin = ast("dialplan eval function VM_INFO(101@default,password)")
        assert "Result: 1234\n" in pin, pin
        pbx.succeed("printf 1234 > /run/test-secrets/vm-101")
        pbx.succeed("systemctl reload asterisk.service")

    with subtest("a secret that makes its line longer than 8190 bytes fails the reload"):
        # Asterisk would skip the line and log how it begins, with part of the
        # secret
        pbx.succeed("printf 's3cr3tXYZ%.0s' $(seq 911) > /run/test-secrets/sip-102")
        pbx.fail("systemctl reload asterisk.service")
        pbx.succeed("journalctl --sync")
        pbx.succeed("journalctl -u asterisk.service | grep -F 'is longer than 8190 bytes with /run/test-secrets/sip-102 in it'")
        pbx.fail("journalctl -b | grep -F s3cr3tXYZ")
        assert "rotated;pw" in ast("pjsip show auth 102")
        pbx.succeed("printf 'rotated;pw' > /run/test-secrets/sip-102")
        pbx.succeed("systemctl reload asterisk.service")

    with subtest("restart keeps working"):
        pbx.succeed("systemctl restart asterisk.service")
        pbx.wait_for_unit("asterisk.service")
        ast("pjsip show endpoints")

    with subtest("a crash leaves no core dump"):
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.succeed(f"kill -SEGV {pid}")
        # systemd-coredump records the crash, with a core file only where the
        # process's RLIMIT_CORE lets it keep one
        pbx.wait_until_succeeds(f"coredumpctl --no-legend list {pid}", timeout=60)
        crash = pbx.succeed(f"coredumpctl --no-legend list {pid}")
        assert re.search(r" SIGSEGV none ", crash), crash
        pbx.succeed("test -z \"$(ls /var/lib/systemd/coredump)\"")
        pbx.wait_until_succeeds(f"test \"$(systemctl show -P MainPID asterisk.service)\" != {pid}")
        pbx.wait_for_unit("asterisk.service")
  '';
}
