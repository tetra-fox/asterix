# Upgrading a pbx that has state: it boots with the default Asterisk, switches
# to asterisk_23 with switch-to-configuration and back, as a rollback would.
# Before the first switch it takes a voicemail message, an astdb key, a queue
# member added at runtime (persistent members) and CDR and CEL records in
# SQLite. After each switch the new Asterisk runs, all of that is still
# there, the phones' registrations are too without the phones registering
# again, a call between the phones and a call through the queue to the
# runtime member carry audio both ways, and both calls add CDR and CEL
# records.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-upgrade";

    nodes.pbx = {config, ...}: let
      inherit (config.lib.asterisk) secret;
    in {
      imports = [
        self.nixosModules.default
        ./common.nix
        ./phone.nix
        (import ./secrets.nix {
          fixed = {
            sip-101 = "pw-101";
            sip-102 = "pw-102";
            vm-101 = "1234";
          };
        })
      ];

      environment.systemPackages = [pkgs.sqlite];

      services.asterisk = {
        enable = true;

        pjsip = {
          transports.udp = {};
          endpoints = lib.genAttrs ["101" "102"] (extension: {
            context = "internal";
            auth.password = secret "/run/test-secrets/sip-${extension}";
          });
        };

        dialplan.contexts.internal.extensions = {
          "_10X" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
          "700" = [
            "Answer()"
            "VoiceMail(101@default,s)"
            "Hangup()"
          ];
          "800" = [
            "Queue(support)"
            "Hangup()"
          ];
        };

        voicemail.mailboxes."101" = {
          pin = secret "/run/test-secrets/vm-101";
          fullName = "Alice";
        };

        queues = {
          persistentMembers = true;
          queues.support = {};
        };

        cdr.sqlite.enable = true;
        cel = {
          enable = true;
          sqlite.enable = true;
        };
      };

      specialisation.asterisk_23.configuration.services.asterisk.package = pkgs.asterisk_23;
    };

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + ''
        FIRST_VERSION = "${nodes.pbx.services.asterisk.package.version}"
        # what each switch activates, below the first system, and the Asterisk it runs
        SWITCHES = [
            ("asterisk_23", "/specialisation/asterisk_23", "${pkgs.asterisk_23.version}"),
            ("asterisk", "", FIRST_VERSION),
        ]
        DB = "/var/log/asterisk/master.db"

        def version():
            return asterisk(pbx, "core show version").split()[1]

        def sqlite(query):
            return pbx.succeed(f"sqlite3 {DB} {shlex.quote(query)}").split()

        def records():
            """Unique ids of the CDR records, and the number of CEL records"""
            return sqlite("select uniqueid from cdr order by rowid"), int(sqlite("select count(*) from cel")[0])

        def registers():
            return {phone.name: phone.count("TX [0-9]+ bytes Request msg REGISTER/") for phone in phones}

        def messages():
            """New messages of mailbox 101 as Asterisk counts them"""
            match = re.search(r"^default +101 +Alice +(\d+)", asterisk(pbx, "voicemail show users"), re.M)
            assert match, asterisk(pbx, "voicemail show users")
            return int(match.group(1))

        def calls_work():
            """A call from 101 to 102, then one through the queue, which only
            102 can answer as the member added at runtime; both carry audio
            both ways and add CDR and CEL records"""
            cdr, cel = records()
            for number in ["102", "800"]:
                alice.call(number)
                wait_bridged(pbx, "101", "102")
                wait_for_media_both_ways(pbx, phones)
                alice.hangup()
                wait_idle(pbx)
            # the backends write a record once its channels are gone
            pbx.wait_until_succeeds(f"test $(sqlite3 {DB} 'select count(*) from cdr') -gt {len(cdr)}", timeout=30)
            pbx.wait_until_succeeds(f"test $(sqlite3 {DB} 'select count(*) from cel') -gt {cel}", timeout=30)
            assert records()[0][:len(cdr)] == cdr, (cdr, records())

        # pjsua would register again after half its registration's lifetime;
        # an hour keeps it from doing so during the test
        alice = Phone(pbx, "alice", "101", "pw-101", "127.0.0.1", sip_port=5070, cli_port=2300, options="--reg-timeout=3600")
        bob = Phone(pbx, "bob", "102", "pw-102", "127.0.0.1", sip_port=5071, cli_port=2301, options="--reg-timeout=3600")
        phones = [alice, bob]

        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()

        with subtest(f"asterisk: Asterisk {FIRST_VERSION} runs, the phones register, and it takes a voicemail message, an astdb key, a queue member added at runtime and CDR and CEL records"):
            assert version() == FIRST_VERSION, version()
            start_phones(phones)
            wait_registrations({alice: 200, bob: 200})
            alice.call("700")
            wait_channel(pbx, "101", app="VoiceMail")
            pbx.sleep(5)
            alice.hangup()
            wait_idle(pbx)
            pbx.succeed("test -f /var/lib/asterisk/spool/voicemail/default/101/INBOX/msg0000.txt")
            assert messages() == 1
            asterisk(pbx, "database put upgrade kept before-the-upgrade")
            asterisk(pbx, "queue add member PJSIP/102 to support")
            assert "PJSIP/102" in pbx.succeed("asterisk -rx 'database show Queue/PersistentMembers'")
            calls_work()

        for name, target, expected in SWITCHES:
            with subtest(f"{name}: the switch runs Asterisk {expected} and keeps the state and the registrations"):
                cdr, cel = records()
                sent = registers()
                print(pbx.succeed(f"{base}{target}/bin/switch-to-configuration test 2>&1"))
                pbx.wait_for_unit("asterisk.service")
                assert version() == expected, version()
                # restored from astdb, and qualified, as the queue skips a
                # member until its contact is
                pbx.wait_until_succeeds("test $(asterisk -rx 'pjsip show contacts' | grep -c ' Avail ') -eq 2", timeout=15)
                assert registers() == sent, (sent, registers())
                assert "Value: before-the-upgrade" in asterisk(pbx, "database get upgrade kept")
                assert re.search(r"PJSIP/102 .*dynamic", asterisk(pbx, "queue show support")), asterisk(pbx, "queue show support")
                assert messages() == 1
                now_cdr, now_cel = records()
                assert now_cdr[:len(cdr)] == cdr and now_cel >= cel, (cdr, cel, now_cdr, now_cel)

            with subtest(f"{name}: calls work and are recorded"):
                calls_work()
      '';
  }
