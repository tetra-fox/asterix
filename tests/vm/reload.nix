# Deploying configuration changes to examples/minimal.nix, with every file
# that has a reload of its own in use. During a call, a change to each of
# those files is applied by its own reload and one to any other file by
# `core reload`, with the same PID and the registrations untouched, and the
# call keeps its audio both ways; switching back applies the old files the
# same way. A secret used in two files, a password and a systemd credential
# are rotated with one reload each. A changed module list restarts Asterisk,
# which ends the call, as do an added and a removed secret and, with
# reloadOnChange off, a change that would otherwise be reloaded;
# registrations survive each restart (they live in astdb). With checkConfig
# off, a PJSIP object Asterisk rejects keeps its previous version on a
# reload, until the next restart drops it, and the journal says so both
# times; a file a module rejects as a whole fails the deploy. Globals and
# extensions changed at runtime, from the dialplan and the CLI, are back to
# the configuration after `dialplan reload`, `module reload pbx_config.so` and
# `core reload`, and after a deploy that changes extensions.conf, which also
# removes a global the configuration no longer has; a deploy that leaves
# extensions.conf alone, and a reload with nothing changed, keep them. There
# is no `dialplan save`; with writeprotect off it cannot write the rendered
# extensions.conf, and what it saves elsewhere is not loaded.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;

  # a change to each file that has a reload of its own (D17), the command
  # that applies it, and a CLI command whose output then holds `shows`;
  # Asterisk shows nothing of the custom and SQLite CDR and CEL files
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
      show = "pjsip send notify reload-check endpoint 101";
      shows = "Sending NOTIFY of type 'reload-check'";
    };
    "rtp.conf" = {
      change.services.asterisk.settings."rtp.conf".general.dtmftimeout = 4000;
      reload = "module reload res_rtp_asterisk.so";
      show = "rtp show settings";
      shows = "DTMF Timeout:    4000";
    };
    "logger.conf" = {
      change.services.asterisk.logger.channels.reload-check = ["notice"];
      reload = "module reload logger";
      show = "logger show channels";
      shows = "/var/log/asterisk/reload-check";
    };
    "voicemail.conf" = {
      change.services.asterisk.voicemail.mailboxes."102".fullName = "Office";
      reload = "module reload app_voicemail.so";
      show = "voicemail show users";
      shows = "Office";
    };
    "confbridge.conf" = {
      change.services.asterisk.confbridge.bridges.reload_check.maxMembers = 5;
      reload = "module reload app_confbridge.so";
      show = "confbridge show profile bridges";
      shows = "reload_check";
    };
    "queues.conf" = {
      change.services.asterisk.queues.queues.support.members = ["PJSIP/102"];
      reload = "module reload app_queue.so";
      show = "queue show support";
      shows = "PJSIP/102";
    };
    "queuerules.conf" = {
      change.services.asterisk.settings."queuerules.conf".reload-check.penaltychange = "30,+1";
      reload = "module reload app_queue.so";
      show = "queue show rules";
      shows = "Rule: reload-check";
    };
    "musiconhold.conf" = {
      change.services.asterisk.musicOnHold.classes.reload-check.directory = "moh";
      reload = "module reload res_musiconhold.so";
      show = "moh show classes";
      shows = "Class: reload-check";
    };
    "features.conf" = {
      change.services.asterisk.features.featureMap.blindxfer = "#1";
      reload = "module reload features";
      show = "features show";
      shows = "#1";
    };
    "res_parking.conf" = {
      change.services.asterisk.settings."res_parking.conf".general.parkeddynamic = true;
      reload = "module reload res_parking.so";
      show = "parking show";
      shows = "Dynamic Parking     :  yes";
    };
    "manager.conf" = {
      change.services.asterisk.ami.users.monitor.read = ["call"];
      reload = "module reload manager";
      show = "manager show user monitor";
      shows = "read perm: system,call";
    };
    "http.conf" = {
      change.services.asterisk.http.settings.servername = "reload-check";
      reload = "module reload http";
      show = "http show status";
      shows = "Server: reload-check";
    };
    "ari.conf" = {
      change.services.asterisk.ari.users.app.readOnly = true;
      reload = "module reload res_ari.so";
      show = "ari show user app";
      shows = "Read only?: Yes";
    };
    "cdr.conf" = {
      change.services.asterisk.cdr.unanswered = true;
      reload = "module reload cdr";
      show = "cdr show status";
      shows = "Log unanswered calls:       Yes";
    };
    "cdr_custom.conf" = {
      change.services.asterisk.settings."cdr_custom.conf".mappings."/var/log/asterisk/cdr-reload-check.csv" = "\${CDR(src)}";
      reload = "module reload cdr_custom.so";
    };
    "cdr_sqlite3_custom.conf" = {
      change.services.asterisk.settings."cdr_sqlite3_custom.conf".master.busy_timeout = 2000;
      reload = "module reload cdr_sqlite3_custom.so";
    };
    "cel.conf" = {
      change.services.asterisk.settings."cel.conf".general.apps = "dial";
      reload = "module reload cel";
      show = "cel show status";
      shows = "CEL Tracking Application: dial";
    };
    "cel_custom.conf" = {
      change.services.asterisk.settings."cel_custom.conf".mappings."/var/log/asterisk/cel-reload-check.csv" = "\${eventtype}";
      reload = "module reload cel_custom.so";
    };
    # its reload stops CEL records in master.db (F2)
    "cel_sqlite3_custom.conf" = {
      change.services.asterisk.settings."cel_sqlite3_custom.conf".master.busy_timeout = 2000;
      reload = "module reload cel_sqlite3_custom.so";
    };
    "acl.conf" = {
      change.services.asterisk.settings."acl.conf".reload-check = {
        deny = "0.0.0.0/0.0.0.0";
        permit = "127.0.0.1/255.255.255.255";
      };
      reload = "module reload acl";
      show = "acl show";
      shows = "reload-check";
    };
    "indications.conf" = {
      change.services.asterisk.settings."indications.conf".general.country = "uk";
      reload = "module reload indications";
      show = "indication show";
      shows = "Default tone zone: uk";
    };
    "udptl.conf" = {
      change.services.asterisk.settings."udptl.conf".general.udptlend = 4998;
      reload = "module reload udptl";
      show = "udptl show config";
      shows = "udptlend:        4998";
    };
  };

  changesFile = pkgs.writeText "reload-changes.json" (builtins.toJSON (
    lib.mapAttrs (_: change:
      {
        show = null;
        shows = null;
      }
      // removeAttrs change ["change"])
    changes
  ));
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
        self.nixosModules.default
        ../../examples/minimal.nix
        ./common.nix
        ./phone.nix
        (sopsSecrets {
          sip-101 = "secret-101";
          sip-102 = "secret-102";
          sip-103 = "secret-103";
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
        settings."cdr_custom.conf".mappings."/var/log/asterisk/cdr-custom.csv" = "\${CDR(src)},\${CDR(dst)}";
        settings."cel_custom.conf".mappings."/var/log/asterisk/cel-custom.csv" = "\${eventtype}";
        modules.load = [
          "app_authenticate.so"
          "cdr_custom.so"
          "cel_custom.so"
        ];
        # a global, which the dialplan changes at runtime next to one of its own
        dialplan.globals.SOURCE = "nix";
        dialplan.contexts.runtime.extensions.s = [
          "Set(GLOBAL(SOURCE)=dialplan)"
          "Set(GLOBAL(RUNTIME)=dialplan)"
          "Answer()"
          "Hangup()"
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

      environment.systemPackages = [pkgs.curl];

      specialisation = {
        files.configuration = lib.mkMerge (lib.mapAttrsToList (_: change: change.change) changes);
        # a file asterix has no reload of its own for
        unmapped.configuration = {
          services.asterisk.settings."pjproject.conf".log_mappings = {
            type = "log_mappings";
            asterisk_debug = "3,4,5";
          };
        };
        modules.configuration = {
          services.asterisk.modules.load = ["app_system.so"];
        };
        secret-added.configuration = {config, ...}: {
          sops.secrets.sip-103.reloadUnits = ["asterisk.service"];
          services.asterisk.pjsip.endpoints."103" = {
            context = "phones";
            auth.password = secret config.sops.secrets.sip-103.path;
          };
        };
        restarts.configuration = {
          services.asterisk.reloadOnChange = false;
        };
        restarts-dialplan.configuration = {
          services.asterisk.reloadOnChange = false;
          services.asterisk.dialplan.contexts.phones.extensions."199" = [
            "Answer()"
            "Hangup()"
          ];
        };
        # settings Asterisk rejects, which only reach it without the check
        bad-endpoint.configuration = {
          services.asterisk = {
            checkConfig = false;
            pjsip.endpoints."102" = {
              callerId = ''"Office" <102>'';
              settings.direct_mdia = false;
            };
          };
        };
        rejected.configuration = {
          services.asterisk = {
            checkConfig = false;
            confbridge.bridges.reload_check.settings.max_membres = 5;
          };
        };
        # a global added to extensions.conf, which switching back removes
        globals.configuration = {
          services.asterisk.dialplan.globals.DEPLOYED = "yes";
        };
        # a change that leaves extensions.conf alone
        endpoint.configuration = changes."pjsip.conf".change;
        # with static, which the module sets, pbx_config offers dialplan save
        saveable.configuration = {
          services.asterisk.dialplan.general.writeprotect = false;
        };
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        changes = json.load(open("${changesFile}"))

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
            return sorted(re.findall(r"asterisk-config: (module reload \S+|core reload)$", journal, re.M))

        def shown(change):
            return change["shows"] in asterisk(pbx, change["show"])

        def registers():
            """REGISTER requests the phones have sent."""
            return {p.name: p.count("TX [0-9]+ bytes Request msg REGISTER/") for p in (alice, bob)}

        def registrations_kept(sent):
            """Asterisk has both contacts, qualified, and neither phone has
            registered since `sent` (from registers())."""
            wait_contacts(pbx, 2)
            for phone in (alice, bob):
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE ' {phone.user}/sip:{phone.user}@[^ ]+ +[^ ]+ +Avail '")
            assert registers() == sent, (sent, registers())

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

        # the phones register for an hour, so a registration after a restart
        # can only come from astdb
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

        with subtest("a change to each file with a reload of its own is applied by that reload, during the call"):
            since, cursor = marks(), journal_cursor(pbx)
            assert switch("files") == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == every_reload, reloads(cursor)
            for file, change in changes.items():
                assert change["show"] is None or shown(change), (file, asterisk(pbx, change["show"]))
            audio_went_on(since)
            assert registers() == registered

        with subtest("switching back applies the old files with the same reloads, during the call"):
            since, cursor = marks(), journal_cursor(pbx)
            assert switch() == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == every_reload, reloads(cursor)
            for file, change in changes.items():
                assert change["show"] is None or not shown(change), (file, asterisk(pbx, change["show"]))
            audio_went_on(since)

        with subtest("a change to a file without a reload of its own is applied by core reload, and so is switching back, during the call"):
            for specialisation, level in (("unmapped", "3,4,5"), (None, "3,4")):
                since, cursor = marks(), journal_cursor(pbx)
                assert switch(specialisation) == ["reloading"]
                assert main_pid() == pid, "asterisk was restarted"
                assert reloads(cursor) == ["core reload"], reloads(cursor)
                mappings = asterisk(pbx, "pjproject show log mappings")
                assert re.search(rf"^asterisk_debug +: {level}$", mappings, re.M), mappings
                audio_went_on(since)

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

        with subtest("a rotated password is applied with a reload, during the call"):
            since, cursor = marks(), journal_cursor(pbx)
            pbx.succeed("printf rotated-102 > /run/secrets/sip-102")
            pbx.succeed("systemctl reload asterisk.service")
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == ["module reload res_pjsip.so"], reloads(cursor)
            assert "rotated-102" in asterisk(pbx, "pjsip show auth 102")
            audio_went_on(since)
            # the next switch would write the sops files back, and reload
            pbx.succeed("printf secret-102 > /run/secrets/sip-102 && printf 4242 > /run/secrets/pin")
            pbx.succeed("systemctl reload asterisk.service")

        with subtest("a rotated systemd credential is applied with a reload"):
            cursor = journal_cursor(pbx)
            pbx.succeed(
                "printf rotated-ari | systemd-creds encrypt --with-key=host --name=ari-password - /var/lib/test-credentials/ari-password"
            )
            pbx.succeed("systemctl reload asterisk.service")
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == ["module reload res_ari.so"], reloads(cursor)
            pbx.succeed("curl -sf -u app:rotated-ari http://127.0.0.1:8088/ari/asterisk/info")
            pbx.fail("curl -sf -u app:ari-secret http://127.0.0.1:8088/ari/asterisk/info")

        with subtest("with checkConfig off, a PJSIP object Asterisk rejects keeps its previous version on a reload, and the journal says so"):
            since, cursor = marks(), journal_cursor(pbx)
            assert switch("bad-endpoint") == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == ["module reload res_pjsip.so"], reloads(cursor)
            journal = journal_since(pbx, cursor)
            for line in [
                "Could not find option suitable for category '102' named 'direct_mdia'",
                "Could not create an object of type 'endpoint' with id '102'",
                "Retaining existing configuration for object of type 'endpoint' with id '102'",
            ]:
                assert line in journal, journal
            assert "Office" not in asterisk(pbx, "pjsip show endpoint 102")
            audio_went_on(since)
            cursor = journal_cursor(pbx)
            assert switch() == ["reloading"]
            assert reloads(cursor) == ["module reload res_pjsip.so"], reloads(cursor)

        with subtest("with checkConfig off, a file a module rejects as a whole fails the deploy, and the module keeps its settings"):
            since, cursor = marks(), journal_cursor(pbx)
            status, output = pbx.execute(f"{base}/specialisation/rejected/bin/switch-to-configuration test 2>&1")
            assert status == 4 and "Failed to reload asterisk.service" in output, output
            assert main_pid() == pid, "asterisk was restarted"
            journal = journal_since(pbx, cursor)
            assert "Could not find option suitable for category 'reload_check' named 'max_membres'" in journal, journal
            assert "asterisk-config: module reload app_confbridge.so failed: The module 'app_confbridge.so' reported a reload failure" in journal, journal
            assert "reload_check" not in asterisk(pbx, "confbridge show profile bridges")
            audio_went_on(since)
            # the next deploy reloads the file again
            cursor = journal_cursor(pbx)
            assert switch() == ["reloading"]
            assert reloads(cursor) == ["module reload app_confbridge.so"], reloads(cursor)

        with subtest("a changed module list restarts asterisk, which ends the call; registrations survive, also switching back"):
            ended = alice.disconnects()
            assert switch("modules") == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            assert "app_system.so" in asterisk(pbx, "module show like app_system")
            registrations_kept(registered)
            alice.wait_disconnected(after=ended)
            wait_idle(pbx)
            pid = main_pid()
            assert switch() == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            assert "app_system.so" not in asterisk(pbx, "module show like app_system")
            registrations_kept(registered)

        with subtest("the rejected PJSIP object is gone after the next restart, which says why, until a deploy brings it back"):
            assert switch("bad-endpoint") == ["reloading"]
            cursor = journal_cursor(pbx)
            pbx.succeed("systemctl restart asterisk.service")
            assert "Unable to find object 102" in asterisk(pbx, "pjsip show endpoint 102")
            assert "Could not create an object of type 'endpoint' with id '102'" in journal_since(pbx, cursor)
            assert switch() == ["reloading"]
            assert "Endpoint:  102" in asterisk(pbx, "pjsip show endpoint 102")
            # the contact shows as available only after its next qualify, up to
            # 60 s after the reload
            asterisk(pbx, "pjsip qualify 102")
            registrations_kept(registered)

        with subtest("an added secret restarts asterisk, and so does removing it; registrations survive"):
            pid = main_pid()
            assert switch("secret-added") == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            assert "secret-103" in asterisk(pbx, "pjsip show auth 103")
            registrations_kept(registered)
            pid = main_pid()
            assert switch() == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            assert "Unable to find object 103" in asterisk(pbx, "pjsip show auth 103")
            registrations_kept(registered)

        with subtest("with reloadOnChange off, a change that would be reloaded restarts asterisk"):
            assert switch("restarts") == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            pid, cursor = main_pid(), journal_cursor(pbx)
            assert switch("restarts-dialplan") == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            assert reloads(cursor) == [], reloads(cursor)
            assert "Answer()" in asterisk(pbx, "dialplan show 199@phones")
            registrations_kept(registered)
            assert switch() == ["restarting"]
            pbx.wait_for_unit("asterisk.service")
            registrations_kept(registered)

        with subtest("after the restarts, the phones call each other on the registrations they made at the start"):
            alice.call("102")
            wait_bridged(pbx, "101", "102")
            wait_hears(alice, [bob.tone])
            wait_hears(bob, [alice.tone])
            alice.hangup()
            wait_idle(pbx)
            assert registers() == registered

        def dialplan_globals():
            return dict(re.findall(r"^   (\w+)=(.*)$", asterisk(pbx, "dialplan show globals"), re.M))

        def phones_dialplan():
            # without the line numbers, which a global added above the context moves
            return re.sub(r" +\[extensions\.conf:\d+\]", "", asterisk(pbx, "dialplan show phones"))

        nix_globals, nix_dialplan = dialplan_globals(), phones_dialplan()

        def change_at_runtime():
            """Globals set from the dialplan, one the configuration sets and one
            of its own, and one from the CLI; an extension added and one of the
            configuration's removed from the CLI. Returns the globals and the
            dialplan of phones."""
            before = dialplan_globals()
            asterisk(pbx, "channel originate Local/s@runtime application NoOp")
            pbx.wait_until_succeeds("asterisk -rx 'dialplan show globals' | grep -qx '   RUNTIME=dialplan'")
            wait_idle(pbx)
            asterisk(pbx, "dialplan set global CLI cli")
            asterisk(pbx, "dialplan add extension 198,1,NoOp(runtime) into phones")
            asterisk(pbx, "dialplan remove extension _10X@phones")
            changed = dialplan_globals(), phones_dialplan()
            assert changed[0] == {**before, "SOURCE": "dialplan", "RUNTIME": "dialplan", "CLI": "cli"}, changed[0]
            assert "'198' =>" in changed[1] and "'_10X' =>" not in changed[1], changed[1]
            return changed

        with subtest("what was changed at runtime is back to the configuration after dialplan reload, module reload and core reload from the CLI"):
            assert nix_globals["SOURCE"] == "nix", nix_globals
            # dialplan reload last, before the next deploy
            for command in ["core reload", "module reload pbx_config.so", "dialplan reload"]:
                change_at_runtime()
                asterisk(pbx, command)
                assert dialplan_globals() == nix_globals, (command, dialplan_globals())
                assert phones_dialplan() == nix_dialplan, (command, phones_dialplan())

        with subtest("a deploy that changes extensions.conf brings back the configuration, with a global it adds, and switching back removes that global"):
            for specialisation, added in (("globals", {"DEPLOYED": "yes"}), (None, {})):
                change_at_runtime()
                cursor = journal_cursor(pbx)
                assert switch(specialisation) == ["reloading"]
                assert reloads(cursor) == ["module reload pbx_config.so"], reloads(cursor)
                assert dialplan_globals() == {**nix_globals, **added}, (specialisation, dialplan_globals())
                assert phones_dialplan() == nix_dialplan, (specialisation, phones_dialplan())

        with subtest("a deploy that leaves extensions.conf alone, and a reload with nothing changed, keep what was changed at runtime"):
            changed = change_at_runtime()
            cursor = journal_cursor(pbx)
            assert switch("endpoint") == ["reloading"]
            assert reloads(cursor) == ["module reload res_pjsip.so"], reloads(cursor)
            assert (dialplan_globals(), phones_dialplan()) == changed
            cursor = journal_cursor(pbx)
            pbx.succeed("systemctl reload asterisk.service")
            assert reloads(cursor) == [], reloads(cursor)
            assert (dialplan_globals(), phones_dialplan()) == changed
            assert switch() == ["reloading"]
            assert (dialplan_globals(), phones_dialplan()) == changed
            asterisk(pbx, "dialplan reload")
            assert (dialplan_globals(), phones_dialplan()) == (nix_globals, nix_dialplan)

        with subtest("dialplan save does not exist, and with writeprotect off it cannot write the rendered extensions.conf, and what it saves elsewhere is not loaded"):
            output = asterisk(pbx, "dialplan save")
            assert "No such command 'dialplan save'" in output, output
            assert switch("saveable") == ["reloading"]
            # pbx_config adds dialplan save only when it loads (pbx_config.c load_module)
            output = asterisk(pbx, "dialplan save")
            assert "No such command 'dialplan save'" in output, output
            pbx.succeed("systemctl restart asterisk.service")
            rendered = pbx.succeed("sha256sum /run/asterisk/config/extensions.conf")
            change_at_runtime()
            output = asterisk(pbx, "dialplan save")
            assert "Failed to create file '/run/asterisk/config/extensions.conf'" in output, output
            assert pbx.succeed("sha256sum /run/asterisk/config/extensions.conf") == rendered
            # it appends extensions.conf to the path it is given
            output = asterisk(pbx, "dialplan save /var/lib/asterisk/")
            assert "Dialplan successfully saved into '/var/lib/asterisk//extensions.conf'" in output, output
            pbx.succeed("grep -qF 'exten => 198,1,NoOp(runtime)' /var/lib/asterisk/extensions.conf")
            asterisk(pbx, "dialplan reload")
            assert (dialplan_globals(), phones_dialplan()) == (nix_globals, nix_dialplan)
            assert switch() == ["reloading"]
            output = asterisk(pbx, "dialplan save")
            assert "I can't save dialplan now" in output, output
      '';
  }
