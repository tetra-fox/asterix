# Deploying configuration changes: dialplan and endpoint changes are applied
# with a reload (same PID, registrations untouched), a changed module list
# restarts Asterisk, and registrations survive the restart (they live in
# astdb).
{
  pkgs,
  self,
  sopsSecrets,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-reload";

  nodes.pbx =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../../examples/minimal.nix
        ./common.nix
        ./phone.nix
        (sopsSecrets {
          sip-101 = "secret-101";
          sip-102 = "secret-102";
        })
      ];

      specialisation = {
        dialplan.configuration = {
          services.asterisk-declarative.dialplan.contexts.phones.extensions."199" = [
            "Answer()"
            "Hangup()"
          ];
        };
        endpoint.configuration = {
          services.asterisk-declarative.pjsip.endpoints."102".callerId = ''"Office" <102>'';
        };
        modules.configuration = {
          services.asterisk-declarative.modules.load = [ "app_system.so" ];
        };
      };
    };

  testScript = builtins.readFile ./phone.py + ''
    pbx.wait_for_unit("asterisk.service")
    base = pbx.succeed("readlink -f /run/current-system").strip()

    def switch(specialisation=None):
        """Activate a specialisation (or the base system) and return what
        switch-to-configuration did with asterisk.service."""
        target = f"{base}/specialisation/{specialisation}" if specialisation else base
        output = pbx.succeed(f"{target}/bin/switch-to-configuration test 2>&1")
        print(output)
        actions = [
            line.split(" the following units:")[0]
            for line in output.splitlines()
            if " the following units:" in line and "asterisk.service" in line
        ]
        return actions

    def main_pid():
        return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

    def journal_cursor():
        return pbx.succeed("journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p'").strip()

    def journal_since(cursor):
        return pbx.succeed(f"journalctl -u asterisk.service --after-cursor='{cursor}'")

    def registered():
        return "101/sip:101@127.0.0.1" in asterisk(pbx, "pjsip show contacts")

    phone = Phone(pbx, "alice", "101", "secret-101", "127.0.0.1")
    phone.start()
    phone.wait_registered()
    pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q '101/sip:101@127.0.0.1'")
    pid = main_pid()

    with subtest("dialplan change is applied with a reload"):
        cursor = journal_cursor()
        assert switch("dialplan") == ["reloading"]
        assert main_pid() == pid, "asterisk was restarted"
        pbx.wait_until_succeeds("asterisk -rx 'dialplan show 199@phones' | grep -q 'Answer()'")
        log = journal_since(cursor)
        assert "asterisk-config: dialplan reload" in log, log
        assert "core reload" not in log, log
        assert registered()

    with subtest("endpoint change is applied with a targeted pjsip reload"):
        cursor = journal_cursor()
        assert switch("endpoint") == ["reloading"]
        assert main_pid() == pid, "asterisk was restarted"
        pbx.wait_until_succeeds("asterisk -rx 'pjsip show endpoint 102' | grep -q 'Office'")
        pbx.wait_until_succeeds("! asterisk -rx 'dialplan show 199@phones' | grep -q 'Answer()'")
        log = journal_since(cursor)
        assert "asterisk-config: module reload res_pjsip.so" in log, log
        assert registered()

    with subtest("module list change restarts asterisk, registrations survive"):
        assert switch("modules") == ["restarting"]
        pbx.wait_for_unit("asterisk.service")
        assert main_pid() != pid, "asterisk was not restarted"
        pbx.wait_until_succeeds("asterisk -rx 'module show like app_system' | grep -q 'app_system.so'")
        # restored from astdb, not re-registered: the phone re-registers every 300s
        assert registered(), asterisk(pbx, "pjsip show contacts")

    with subtest("switching back restores the original configuration"):
        assert switch() == ["restarting"]
        pbx.wait_for_unit("asterisk.service")
        pbx.fail("asterisk -rx 'module show like app_system' | grep -q 'app_system.so'")
        pbx.fail("asterisk -rx 'pjsip show endpoint 102' | grep -q 'Office'")
        assert registered()
  '';
}
