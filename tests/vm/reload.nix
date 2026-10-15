# Deploying configuration changes to examples/minimal.nix, with every file
# that has a reload of its own in use and the phones 101 and 102 running on
# the pbx itself. During a call, a change to each of those files is applied
# by its own reload and one to any other file by `core reload`, with the same
# PID and the registrations untouched, the call keeps its audio both ways and
# CEL keeps writing its records to master.db; switching back applies the old
# files the same way. A secret used in two files and a systemd credential are
# rotated with one reload each. A deploy whose SQLite CDR and CEL files name
# columns master.db lacks adds them first, so the records fill them.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;

  # a change to each file that has a reload of its own and the command that
  # applies it; for two of them, a CLI command whose output then holds `shows`
  changes = {
    "extensions.conf" = {
      change.services.asterisk.dialplan.contexts.phones.extensions."199" = [
        "Answer()"
        "Hangup()"
      ];
      reload = "module reload pbx_config.so";
      show = "dialplan show 199@phones";
      shows = "Answer()";
    };
    "pjsip.conf" = {
      change.services.asterisk.pjsip.endpoints."102".callerId = ''"Office" <102>'';
      reload = "module reload res_pjsip.so";
      show = "pjsip show endpoint 102";
      shows = "Office";
    };
    "pjsip_notify.conf" = {
      change.services.asterisk.settings."pjsip_notify.conf".reload-check.Event = "check-sync";
      reload = "module reload res_pjsip_notify.so";
    };
    "rtp.conf" = {
      change.services.asterisk.settings."rtp.conf".general.dtmftimeout = 4000;
      reload = "module reload res_rtp_asterisk.so";
    };
    "logger.conf" = {
      change.services.asterisk.logger.channels.reload-check = ["notice"];
      reload = "module reload logger";
    };
    "voicemail.conf" = {
      change.services.asterisk.voicemail.mailboxes."102".fullName = "Office";
      reload = "module reload app_voicemail.so";
    };
    "confbridge.conf" = {
      change.services.asterisk.confbridge.bridges.reload_check.maxMembers = 5;
      reload = "module reload app_confbridge.so";
    };
    "queues.conf" = {
      change.services.asterisk.queues.queues.support.members = ["PJSIP/102"];
      reload = "module reload app_queue.so";
    };
    "queuerules.conf" = {
      change.services.asterisk.settings."queuerules.conf".reload-check.penaltychange = "30,+1";
      reload = "module reload app_queue.so";
    };
    "musiconhold.conf" = {
      change.services.asterisk.musicOnHold.classes.reload-check.directory = "moh";
      reload = "module reload res_musiconhold.so";
    };
    "features.conf" = {
      change.services.asterisk.features.featureMap.blindxfer = "#1";
      reload = "module reload features";
    };
    "res_parking.conf" = {
      change.services.asterisk.settings."res_parking.conf".general.parkeddynamic = true;
      reload = "module reload res_parking.so";
    };
    "manager.conf" = {
      change.services.asterisk.ami.users.monitor.read = ["call"];
      reload = "module reload manager";
    };
    "http.conf" = {
      change.services.asterisk.http.settings.servername = "reload-check";
      reload = "module reload http";
    };
    "ari.conf" = {
      change.services.asterisk.ari.users.app.readOnly = true;
      reload = "module reload res_ari.so";
    };
    "cdr.conf" = {
      change.services.asterisk.cdr.unanswered = true;
      reload = "module reload cdr";
    };
    "cdr_custom.conf" = {
      change.services.asterisk.settings."cdr_custom.conf".mappings."/var/log/asterisk/cdr-reload-check.csv" = "\${CDR(src)}";
      reload = "module reload cdr_custom.so";
    };
    # a changed busy_timeout restarts Asterisk, as the reload keeps the old one
    "cdr_sqlite3_custom.conf" = {
      change.services.asterisk.cdr.sqlite.table = "reload_check";
      reload = "module reload cdr_sqlite3_custom.so";
    };
    "cel.conf" = {
      change.services.asterisk.settings."cel.conf".general.apps = "dial";
      reload = "module reload cel";
    };
    "cel_custom.conf" = {
      change.services.asterisk.settings."cel_custom.conf".mappings."/var/log/asterisk/cel-reload-check.csv" = "\${eventtype}";
      reload = "module reload cel_custom.so";
    };
    "cel_sqlite3_custom.conf" = {
      change.services.asterisk.settings."cel_sqlite3_custom.conf".master.busy_timeout = 2000;
      reload = "module refresh cel_sqlite3_custom.so";
    };
    "acl.conf" = {
      change.services.asterisk.settings."acl.conf".reload-check = {
        deny = "0.0.0.0/0.0.0.0";
        permit = "127.0.0.1/255.255.255.255";
      };
      reload = "module reload acl";
    };
    "indications.conf" = {
      change.services.asterisk.settings."indications.conf".general.country = "uk";
      reload = "module reload indications";
    };
    "udptl.conf" = {
      change.services.asterisk.settings."udptl.conf".general.udptlend = 4998;
      reload = "module reload udptl";
    };
  };

  # the changes without their configuration, as a Python dict of strings
  changeChecks = builtins.toJSON (lib.mapAttrs (_: change: removeAttrs change ["change"]) changes);
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-reload";

    nodes.pbx = {
      config,
      lib,
      ...
    }: let
      inherit (config.lib.asterisk) credential secret;
    in {
      imports = [
        self.nixosModules.asterisk
        ../../examples/minimal.nix
        ./common.nix
        ./phone.nix
        (sopsSecrets {
          sip-101 = "secret-101";
          sip-102 = "secret-102";
          pin = "4242";
          ami = "ami-secret";
        })
      ];

      sops.secrets = lib.genAttrs ["pin" "ami"] (_: {
        reloadUnits = ["asterisk.service"];
      });

      # every file with a reload of its own, with its module loaded
      services.asterisk = {
        # a secret in two files: a mailbox PIN, also asked for by extension 700
        voicemail.mailboxes."102".pin = secret config.sops.secrets.pin.path;
        dialplan.contexts.phones.extensions."700" = [
          "Answer()"
          "Authenticate(${secret config.sops.secrets.pin.path})"
          "Hangup()"
        ];
        queues.queues.support.members = ["PJSIP/101"];
        settings."queuerules.conf".ramp.penaltychange = "60,+1";
        # loads res_parking
        features.featureMap.parkcall = "#72";
        ami = {
          enable = true;
          users.monitor = {
            secret = secret config.sops.secrets.ami.path;
            read = ["system"];
          };
        };
        http.enable = true;
        ari = {
          enable = true;
          users.app.password = credential "ari-password";
        };
        cdr.sqlite.enable = true;
        cel = {
          enable = true;
          sqlite.enable = true;
        };
        # calls whose channel events the test looks for in master.db
        dialplan.contexts.records.extensions."_X." = [
          "Answer()"
          "Hangup()"
        ];
        settings."cdr_custom.conf".mappings."/var/log/asterisk/cdr-custom.csv" = "\${CDR(src)},\${CDR(dst)}";
        settings."cel_custom.conf".mappings."/var/log/asterisk/cel-custom.csv" = "\${eventtype}";
        modules.load = [
          "app_authenticate.so"
          "cdr_custom.so"
          "cel_custom.so"
        ];
      };

      # a credential systemd decrypts itself, which the test rotates by
      # encrypting a new one
      systemd.services.test-credential = {
        wantedBy = ["multi-user.target"];
        before = ["asterisk.service"];
        requiredBy = ["asterisk.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [config.systemd.package];
        script = ''
          install -d -m 0700 /var/lib/test-credentials
          printf ari-secret | systemd-creds encrypt --with-key=host --name=ari-password - /var/lib/test-credentials/ari-password
        '';
      };
      systemd.services.asterisk.serviceConfig.LoadCredentialEncrypted = ["ari-password:/var/lib/test-credentials/ari-password"];

      environment.systemPackages = [
        pkgs.curl
        pkgs.sqlite
      ];

      specialisation = {
        files.configuration = lib.mkMerge (lib.mapAttrsToList (_: change: change.change) changes);
        # a file asterix has no reload of its own for
        unmapped.configuration = {
          services.asterisk.settings."pjproject.conf".log_mappings = {
            type = "log_mappings";
            asterisk_debug = "3,4,5";
          };
        };
        # CDR and CEL columns master.db does not have yet
        columns.configuration = {
          services.asterisk.settings = {
            "cdr_sqlite3_custom.conf".master = {
              columns = "calldate, src, dst, linkedid";
              values = "'\${CDR(start)}', '\${CDR(src)}', '\${CDR(dst)}', '\${CDR(linkedid)}'";
            };
            "cel_sqlite3_custom.conf".master = {
              columns = "eventtype, exten, eventenum";
              values = "'\${eventtype}', '\${CHANNEL(exten)}', '\${eventenum}'";
            };
          };
        };
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        changes = ${changeChecks}

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

        def reloads(cursor):
            """The commands asterisk-config ran after `cursor`, none of which failed."""
            journal = journal_since(pbx, cursor)
            assert not re.search(r"asterisk-config: .* failed", journal), journal
            return sorted(re.findall(r"asterisk-config: (module (?:reload|refresh) \S+|core reload)$", journal, re.M))

        # Asterisk may be writing records while the test reads them: wait for its lock
        SQLITE = "sqlite3 -cmd '.timeout 10000' /var/log/asterisk/master.db"
        record_numbers = itertools.count(1000)

        def wait_row(query):
            pbx.wait_until_succeeds(f"{SQLITE} {shlex.quote(query)} | grep -q .", timeout=30)

        def record_call():
            """Starts a channel into the records context, whose CDR and CEL
            records name the number this returns."""
            number = next(record_numbers)
            asterisk(pbx, f"channel originate Local/{number}@records application NoOp")
            return number

        def channel_events_recorded():
            """A channel started now runs to its end in master.db's CEL table."""
            wait_row(f"select 1 from cel where exten = '{record_call()}' and eventtype = 'CHAN_END'")

        def shown(change):
            return change["shows"] in asterisk(pbx, change["show"])

        def registers():
            """REGISTER requests alice and bob have sent."""
            return {p.name: p.count("TX [0-9]+ bytes Request msg REGISTER/") for p in (alice, bob)}

        def marks():
            return {p.name: recorded(p) for p in (alice, bob)}

        def audio_went_on(since):
            """In every 100 ms since the marks `since`, until 2 s from now, the
            loudest tone alice heard was bob's and the loudest bob heard was
            alice's. No packet is lost, but one can come a frame late, as
            during `core reload`, and the phone's jitter buffer then drops or
            repeats a 20 ms frame, which splits a window's peak in two."""
            for phone, peer in ((alice, bob), (bob, alice)):
                wait_recorded(phone, recorded(phone), 2)
                windows = heard(phone, since[phone.name])
                assert windows and all(window and abs(window[0] - peer.tone) <= TOLERANCE for window in windows), (phone.name, windows)

        # the phones register for an hour, so that none registers again
        # during the test
        alice = Phone(pbx, "alice", "101", "secret-101", "127.0.0.1", sip_port=5070, cli_port=2300)
        bob = Phone(pbx, "bob", "102", "secret-102", "127.0.0.1", sip_port=5071, cli_port=2301)
        pbx.succeed("\n".join(p.start_command("--reg-timeout=3600") for p in (alice, bob)))
        wait_registrations({alice: 200, bob: 200})
        wait_contacts(pbx, 2)
        registered = registers()
        pid = main_pid()
        every_reload = sorted({change["reload"] for change in changes.values()})

        with subtest("a call is up before the changes"):
            alice.call("102")
            wait_bridged(pbx, "101", "102")
            wait_hears(alice, [bob.tone])
            wait_hears(bob, [alice.tone])

        with subtest("a change to each file with a reload of its own is applied by that reload, and switching back too, during the call"):
            for specialisation in ("files", None):
                since, cursor = marks(), journal_cursor(pbx)
                assert switch(specialisation) == ["reloading"]
                assert main_pid() == pid, "asterisk was restarted"
                assert reloads(cursor) == every_reload, reloads(cursor)
                for file, change in changes.items():
                    if "show" in change:
                        assert shown(change) == (specialisation == "files"), (file, asterisk(pbx, change["show"]))
                audio_went_on(since)
                assert registers() == registered
                channel_events_recorded()

        with subtest("a change to a file without a reload of its own is applied by core reload, and so is switching back, during the call"):
            for specialisation, level in (("unmapped", "3,4,5"), (None, "3,4")):
                since, cursor = marks(), journal_cursor(pbx)
                assert switch(specialisation) == ["reloading"]
                assert main_pid() == pid, "asterisk was restarted"
                # core reload also reloads cel_sqlite3_custom, which is then refreshed
                assert reloads(cursor) == ["core reload", "module refresh cel_sqlite3_custom.so"], reloads(cursor)
                mappings = asterisk(pbx, "pjproject show log mappings")
                assert re.search(rf"^asterisk_debug +: {level}$", mappings, re.M), mappings
                audio_went_on(since)
                channel_events_recorded()

        with subtest("a secret used in two files is rotated with one reload, during the call"):
            # what sops-nix does on a deploy with a changed secret: new file
            # contents, then `systemctl reload` (reloadUnits)
            since, cursor = marks(), journal_cursor(pbx)
            pbx.succeed("printf 5678 > /run/secrets/pin")
            pbx.succeed("systemctl reload asterisk.service")
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == ["module reload app_voicemail.so", "module reload pbx_config.so"], reloads(cursor)
            assert "Result: -5678\n" in asterisk(pbx, "dialplan eval function VM_INFO(102@default,password)")
            assert "Authenticate(5678)" in asterisk(pbx, "dialplan show 700@phones")
            audio_went_on(since)
            # the next switch would write the sops file back, and reload
            pbx.succeed("printf 4242 > /run/secrets/pin")
            pbx.succeed("systemctl reload asterisk.service")

        with subtest("a rotated systemd credential is applied with a reload"):
            cursor = journal_cursor(pbx)
            pbx.succeed(
                "printf rotated-ari | systemd-creds encrypt --with-key=host --name=ari-password - /var/lib/test-credentials/ari-password"
            )
            pbx.succeed("systemctl reload asterisk.service")
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == ["module reload res_ari.so"], reloads(cursor)
            pbx.succeed("curl -sf -u app:rotated-ari http://127.0.0.1:8088/ari/applications")
            pbx.fail("curl -sf -u app:ari-secret http://127.0.0.1:8088/ari/applications")

        with subtest("a deploy that names CDR and CEL columns master.db lacks adds them, and the records fill them"):
            # created before Asterisk started, as Asterisk would have created it
            assert pbx.succeed("stat -c '%U:%G %a' /var/log/asterisk/master.db").strip() == "asterisk:asterisk 640"
            cursor = journal_cursor(pbx)
            assert switch("columns") == ["reloading"]
            assert reloads(cursor) == ["module refresh cel_sqlite3_custom.so", "module reload cdr_sqlite3_custom.so"], reloads(cursor)
            number = record_call()
            wait_row(f"select 1 from cdr where dst = '{number}' and length(linkedid) > 0")
            wait_row(f"select 1 from cel where exten = '{number}' and eventenum = 'CHAN_END'")
      '';
  }
