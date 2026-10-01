# Upgrading a pbx that has state: it boots the first of `systems` and
# switches to each next one with switch-to-configuration. Before the first
# switch it takes a voicemail message, an astdb key, a queue member added at
# runtime (persistent members) and CDR and CEL records in SQLite. After each
# switch the new Asterisk runs, all of that is still there, the phones'
# registrations are too without the phones registering again, a call between
# the phones and a call through the queue to the runtime member carry audio
# both ways, and both calls add CDR and CEL records.
#
# The gate goes from the default Asterisk to asterisk_23 and back.
{
  pkgs,
  self,
  # each a name, the nixpkgs it is built from, the asterix module, the
  # attribute of the Asterisk package in that nixpkgs and further modules
  systems ?
    map (package: {
      name = package;
      inherit package;
    }) [
      "asterisk"
      "asterisk_23"
      "asterisk"
    ],
}: let
  inherit (pkgs) lib;

  withDefaults = system:
    {
      inherit pkgs;
      asterix = self.nixosModules.default;
      package = "asterisk";
      modules = [];
    }
    // system;

  node = system: {config, ...}: let
    inherit (config.lib.asterisk) secret;
  in {
    imports =
      [
        system.asterix
        ./common.nix
        # the phones run from the test's nixpkgs whatever the system's is
        (import ./phone.nix {inherit pkgs;})
        (import ./secrets.nix {
          fixed = {
            sip-101 = "pw-101";
            sip-102 = "pw-102";
            vm-101 = "1234";
          };
        })
      ]
      ++ system.modules;

    system.switch.enable = true;
    environment.systemPackages = [pkgs.sqlite];

    services.asterisk = {
      enable = true;
      package = system.pkgs.${system.package};

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
  };

  first = withDefaults (builtins.head systems);
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-upgrade";

    nodes.pbx = node first;

    testScript = {nodes, ...}: let
      # the host's store and the test's directories as the running VM has
      # them: the test framework of another nixpkgs may share them otherwise
      # (nixos-unstable's qemu-vm.nix with virtiofs, 26.05's with 9p), and
      # the switch would fail to mount them
      shared = lib.mapAttrs (_: fs: lib.mkForce {inherit (fs) device fsType options;}) (
        lib.getAttrs ["/nix/.ro-store" "/tmp/shared" "/tmp/xchg"] nodes.pbx.virtualisation.fileSystems
      );
      next = map (system: let
        full = withDefaults system;
      in {
        inherit (full) name;
        version = full.pkgs.${full.package}.version;
        toplevel =
          (full.pkgs.testers.runNixOSTest {
            name = "asterisk-upgrade-${full.name}";
            nodes.pbx = {
              imports = [(node full)];
              virtualisation.fileSystems = shared;
            };
            testScript = "";
          }).nodes.pbx.system.build.toplevel;
      }) (builtins.tail systems);
    in
      builtins.readFile ./phone.py
      + ''
        FIRST_NAME, FIRST_VERSION = ${builtins.toJSON first.name}, ${builtins.toJSON first.pkgs.${first.package}.version}
        SYSTEMS = json.loads(${builtins.toJSON (builtins.toJSON next)})
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

        with subtest(f"{FIRST_NAME}: Asterisk {FIRST_VERSION} runs, the phones register, and it takes a voicemail message, an astdb key, a queue member added at runtime and CDR and CEL records"):
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

        for system in SYSTEMS:
            with subtest(f"{system['name']}: the switch runs Asterisk {system['version']} and keeps the state and the registrations"):
                cdr, cel = records()
                sent = registers()
                print(pbx.succeed(f"{system['toplevel']}/bin/switch-to-configuration test 2>&1"))
                pbx.wait_for_unit("asterisk.service")
                assert version() == system["version"], version()
                # restored from astdb, and qualified, as the queue skips a
                # member until its contact is
                pbx.wait_until_succeeds("test $(asterisk -rx 'pjsip show contacts' | grep -c ' Avail ') -eq 2", timeout=15)
                assert registers() == sent, (sent, registers())
                assert "Value: before-the-upgrade" in asterisk(pbx, "database get upgrade kept")
                assert re.search(r"PJSIP/102 .*dynamic", asterisk(pbx, "queue show support")), asterisk(pbx, "queue show support")
                assert messages() == 1
                now_cdr, now_cel = records()
                assert now_cdr[:len(cdr)] == cdr and now_cel >= cel, (cdr, cel, now_cdr, now_cel)

            with subtest(f"{system['name']}: calls work and are recorded"):
                calls_work()
      '';
  }
