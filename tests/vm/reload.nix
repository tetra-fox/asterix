# Deploying configuration changes: dialplan and endpoint changes and a rotated
# password are applied with a reload (same PID, registrations untouched, a call
# in progress keeps its audio), a changed module list restarts Asterisk, which
# ends the call, registrations survive the restart (they live in astdb), and
# a reload Asterisk does not apply fails the deploy
{
  pkgs,
  self,
  sopsSecrets,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-reload";

  nodes.pbx = {
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
        services.asterisk.dialplan.contexts.phones.extensions."199" = [
          "Answer()"
          "Hangup()"
        ];
      };
      endpoint.configuration = {
        services.asterisk.pjsip.endpoints."102".callerId = ''"Office" <102>'';
      };
      modules.configuration = {
        services.asterisk.modules.load = ["app_system.so"];
      };
      # voicemail.conf without app_voicemail.so, which has nothing to reload
      unloaded.configuration = {
        services.asterisk.settings."voicemail.conf".general.maxmsg = 10;
      };
    };
  };

  testScript =
    builtins.readFile ./phone.py
    + ''
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

      def registered():
          return "101/sip:101@127.0.0.1" in asterisk(pbx, "pjsip show contacts")

      alice = Phone(pbx, "alice", "101", "secret-101", "127.0.0.1", sip_port=5070, cli_port=2300)
      bob = Phone(pbx, "bob", "102", "secret-102", "127.0.0.1", sip_port=5071, cli_port=2301)

      start_phones([alice, bob])
      alice.wait_registered()
      bob.wait_registered()
      pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q '101/sip:101@127.0.0.1'")
      pid = main_pid()

      with subtest("a call is up before the changes"):
          alice.call("102")
          wait_bridged(pbx, "101", "102")
          call = wait_for_media_both_ways(pbx, [alice, bob])

      with subtest("dialplan change is applied with a reload"):
          cursor = journal_cursor(pbx)
          assert switch("dialplan") == ["reloading"]
          assert main_pid() == pid, "asterisk was restarted"
          pbx.wait_until_succeeds("asterisk -rx 'dialplan show 199@phones' | grep -q 'Answer()'")
          journal = journal_since(pbx, cursor)
          assert "asterisk-config: module reload pbx_config.so" in journal, journal
          assert "core reload" not in journal, journal
          assert registered()
          call = wait_calls_continue(pbx, [alice, bob], call)

      with subtest("endpoint change is applied with a targeted pjsip reload"):
          cursor = journal_cursor(pbx)
          assert switch("endpoint") == ["reloading"]
          assert main_pid() == pid, "asterisk was restarted"
          pbx.wait_until_succeeds("asterisk -rx 'pjsip show endpoint 102' | grep -q 'Office'")
          pbx.wait_until_succeeds("! asterisk -rx 'dialplan show 199@phones' | grep -q 'Answer()'")
          journal = journal_since(pbx, cursor)
          assert "asterisk-config: module reload res_pjsip.so" in journal, journal
          assert registered()
          call = wait_calls_continue(pbx, [alice, bob], call)

      with subtest("a rotated password is applied with a reload"):
          # what sops-nix does on a deploy with a changed secret: new file
          # contents, then `systemctl reload` (reloadUnits in the example)
          cursor = journal_cursor(pbx)
          pbx.succeed("printf rotated-102 > /run/secrets/sip-102")
          pbx.succeed("systemctl reload asterisk.service")
          assert main_pid() == pid, "asterisk was restarted"
          assert "rotated-102" in asterisk(pbx, "pjsip show auth 102")
          assert "asterisk-config: module reload res_pjsip.so" in journal_since(pbx, cursor)
          call = wait_calls_continue(pbx, [alice, bob], call)

      with subtest("module list change restarts asterisk, which ends the call; registrations survive"):
          ended = alice.disconnects()
          assert switch("modules") == ["restarting"]
          pbx.wait_for_unit("asterisk.service")
          assert main_pid() != pid, "asterisk was not restarted"
          pbx.wait_until_succeeds("asterisk -rx 'module show like app_system' | grep -q 'app_system.so'")
          # restored from astdb, not re-registered: the phone re-registers every 300s
          assert registered(), asterisk(pbx, "pjsip show contacts")
          alice.wait_disconnected(after=ended)
          wait_idle(pbx)

      with subtest("switching back restores the original configuration"):
          assert switch() == ["restarting"]
          pbx.wait_for_unit("asterisk.service")
          pbx.fail("asterisk -rx 'module show like app_system' | grep -q 'app_system.so'")
          pbx.fail("asterisk -rx 'pjsip show endpoint 102' | grep -q 'Office'")
          assert registered()

      with subtest("a reload Asterisk does not apply fails the deploy"):
          cursor = journal_cursor(pbx)
          pid = main_pid()
          status, output = pbx.execute(f"{base}/specialisation/unloaded/bin/switch-to-configuration test 2>&1")
          assert status == 4 and "Failed to reload asterisk.service" in output, output
          journal = journal_since(pbx, cursor)
          assert "module reload app_voicemail.so failed: No such module 'app_voicemail.so'" in journal, journal
          assert main_pid() == pid, "asterisk was restarted"
    '';
}
