# Core service behaviour with a purely freeform (layer 1) configuration: boot,
# config loading, secrets, runtime file permissions, CLI wrapper, sandboxing.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "asterisk-core";

  nodes.pbx = {
    imports = [
      self.nixosModules.default
      ./freeform.nix
      ./common.nix
      (import ./secrets.nix {
        # characters that need care in Asterisk config files and in shells
        fixed.sip-102 = ''p;w&d\x"$HOME'';
        random = [ "sip-101" ];
      })
    ];
  };

  testScript = ''
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
        pbx.fail("journalctl -u asterisk.service | grep -E 'ERROR|WARNING|Error loading module|declined to load|not permitted'")
        modules = ast("module show like pjsip")
        assert "chan_pjsip.so" in modules, modules

    with subtest("secrets reach Asterisk unchanged"):
        auth = ast("pjsip show auth 102")
        assert 'p;w&d\\x"$HOME' in auth, auth
        random = pbx.succeed("cat /run/test-secrets/sip-101").strip()
        assert random in ast("pjsip show auth 101")

    with subtest("secrets never reach the store or the logs"):
        template = pbx.succeed("readlink -f /etc/asterisk").strip()
        unit = pbx.succeed("readlink -f /etc/systemd/system/asterisk.service").strip()
        closure = pbx.succeed(f"nix-store -qR {template} {unit} | grep -v -- '-asterisk-[0-9.]*$'").split()
        pbx.fail(f"grep -rlF {shlex.quote(random)} {' '.join(closure)}")
        pbx.fail(f"grep -rlF 'p;w&d' {' '.join(closure)}")
        pbx.succeed(f"grep -q '@NIX_ASTERISK_SECRET:' {template}/pjsip.conf")
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
        pbx.succeed(f"grep -q '^CapEff:\\s*0*$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^NoNewPrivs:\\s*1$' /proc/{pid}/status")
        pbx.succeed(f"grep -q '^Seccomp:\\s*2$' /proc/{pid}/status")
        print(pbx.succeed("systemd-analyze security asterisk.service | tail -1"))

    with subtest("state directories"):
        pbx.succeed("test -d /var/lib/asterisk/spool/voicemail")
        pbx.succeed("test -f /var/lib/asterisk/astdb.sqlite3")
        pbx.succeed("test \"$(stat -c %U /var/lib/asterisk)\" = asterisk")

    with subtest("CLI wrapper only talks to the running daemon"):
        pbx.succeed("asterisk -rx 'core show version' | grep -q 'Asterisk 22'")
        pbx.succeed("rasterisk -x 'core show uptime'")
        pbx.fail("asterisk -c")
        pbx.succeed("asterisk -V")

    with subtest("reload re-renders the configuration and rotated secrets"):
        pbx.succeed("printf 'rotated;pw' > /run/test-secrets/sip-102")
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.succeed("systemctl reload asterisk.service")
        assert pid == pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
        pbx.wait_until_succeeds("asterisk -rx 'pjsip show auth 102' | grep -F 'rotated;pw'")

    with subtest("restart keeps working"):
        pbx.succeed("systemctl restart asterisk.service")
        pbx.wait_for_unit("asterisk.service")
        ast("pjsip show endpoints")
  '';
}
