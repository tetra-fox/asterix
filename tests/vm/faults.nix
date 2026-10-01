# Faults on the PBX machine itself, and what callers and the journal see.
# A secret the asterisk user can't read still reaches Asterisk, since systemd
# reads credentials as root; one that is a directory fails the reload, which
# keeps the old configuration, and a bad one fails the start, which systemd
# retries every 5 s until the file is fixed. After SIGKILL systemd restarts
# Asterisk within seconds and every registration survives, while the call it
# carried goes silent.
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
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-faults";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.mapAttrs' (extension: _: lib.nameValuePair "sip-${extension}" "pw-${extension}") names;
          })
        ];

        pbx = {
          enable = true;
          extensions =
            lib.mapAttrs (extension: name: {
              inherit name;
              password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            })
            names;
        };

        services.asterisk = {
          openFirewall = true;
          pjsip.transports.udp = {};
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

        anna = Phone(phones, "anna", "201", "pw-201", "pbx", sip_port=5060, cli_port=2300)
        ben = Phone(phones, "ben", "202", "pw-202", "pbx", sip_port=5061, cli_port=2301)
        cara = Phone(phones, "cara", "203", "pw-203", "pbx", sip_port=5062, cli_port=2302)
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

        with subtest("phones register"):
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
      '';
  }
