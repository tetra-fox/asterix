# Deploying configuration changes to examples/minimal.nix, with every file
# that has a reload of its own in use. During a call, a change to each of
# those files is applied by its own reload and one to any other file by
# `core reload`, with the same PID and the registrations untouched, the call
# keeps its audio both ways and CEL keeps writing its records to master.db;
# switching back applies the old files the same way. A secret used in two
# files, a password and a systemd credential are rotated with one reload each.
# A changed module list restarts Asterisk, which ends the call, as do an added
# and a removed secret and, with reloadOnChange off, a change that would
# otherwise be reloaded; registrations survive each restart (they live in
# astdb). With checkConfig off, a PJSIP object Asterisk rejects keeps its
# previous version on a reload, until the next restart drops it, and the
# journal says so both times; a file a module rejects as a whole fails the
# deploy. A deploy whose SQLite CDR and CEL files name columns or tables
# master.db lacks adds them first, so the records fill them, and switching
# back removes none; one that cannot add them fails and applies nothing, and a
# start goes on without them. Globals and extensions changed at runtime, from
# the dialplan and the CLI, are back to the configuration after `dialplan
# reload`, `module reload pbx_config.so` and `core reload`, and after a deploy
# that changes extensions.conf, which also removes a global the configuration
# no longer has; a deploy that leaves extensions.conf alone, and a reload with
# nothing changed, keep them. There is no `dialplan save`; with writeprotect
# off it cannot write the rendered extensions.conf, and what it saves
# elsewhere is not loaded. A secret PIN no phone can type fails the reload.
# With pbx_ael loaded, a deploy of extensions.conf or extensions.ael reloads
# pbx_config and then pbx_ael, and the globals of the AEL dialplan stay. On a
# pbx layer system, a deploy that removes the opening hours while closed
# early and a queue with a member added at runtime leaves their astdb keys
# alone and logs nothing; switching back brings the hours back closed, and
# the queue without its runtime member until the next start. The same deploy
# turns on the HTTP server and adds a queue rule, which switching back turns
# off and removes again. After a reboot, in which Asterisk waits for the
# address its transport binds, the phones' registrations come back from
# astdb without the phones registering again, the trunk registers, the hours
# are still closed, the runtime queue member is back, and a call from the
# provider reaches the phone of the closed destination.
#
#   pbx       examples/minimal.nix, runs the phones 101 and 102
#   ael       an AEL dialplan next to extensions.conf
#   office    10.1.0.10, a pbx layer system, which its transport binds and
#             which comes up late
#   provider  10.1.0.5, a second Asterisk that takes the office's
#             registration, and runs the office's phones 201 and 202
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;

  # a change to each file that has a reload of its own, the command
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
    # a changed busy_timeout restarts Asterisk, as the reload keeps the old one
    "cdr_sqlite3_custom.conf" = {
      change.services.asterisk.cdr.sqlite.table = "reload_check";
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
        modules.configuration = {
          services.asterisk.modules.load = ["app_system.so"];
        };
        # CDR and CEL columns master.db does not have yet, then other tables
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
        tables.configuration = {
          services.asterisk.cdr.sqlite.table = "calls";
          services.asterisk.cel.sqlite.table = "events";
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

    # an AEL dialplan next to extensions.conf, each with a global
    nodes.ael = {lib, ...}: {
      imports = [
        self.nixosModules.default
        ./common.nix
      ];

      services.asterisk = {
        enable = true;
        modules.load = [
          "res_ael_share.so"
          "pbx_ael.so"
        ];
        dialplan = {
          globals.CONF = "conf";
          contexts.plain.extensions.s = ["NoOp()"];
        };
        extraConfig."extensions.ael" = ''
          globals {
            AEL=ael;
          };
          context from-ael {
            s => {
              NoOp(''${AEL});
            };
          };
        '';
      };

      specialisation = {
        conf.configuration = {
          services.asterisk.dialplan.contexts.plain.extensions."1" = ["NoOp()"];
        };
        ael.configuration = {
          services.asterisk.extraConfig."extensions.ael" = lib.mkAfter ''
            context more-ael {
              s => {
                NoOp();
              };
            };
          '';
        };
      };
    };

    nodes.office = {
      config,
      lib,
      ...
    }: let
      secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
    in {
      imports = [
        self.nixosModules.pbx
        ./common.nix
        (import ./secrets.nix {
          fixed = {
            sip-trunk = "trunk-password";
            sip-201 = "pw-201";
            sip-202 = "pw-202";
          };
        })
      ];

      # no address at boot: the test adds it once Asterisk waits for it, as
      # for a network card that comes up late
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [];

      pbx = {
        enable = true;
        extensions = {
          "201".password = secret "sip-201";
          "202".password = secret "sip-202";
        };
        # open around the clock, so only closing early closes it
        hours.office = {
          timezone = "UTC";
          open = [
            {
              days = "mon-sun";
              time = "00:00-23:59";
            }
          ];
          closeEarly = "*28";
        };
        inbound."5551000" = {
          trunk = "provider";
          hours = "office";
          open.extension = "201";
          closed.extension = "202";
        };
        queues = {
          support.number = "600";
          sales.number = "610";
        };
      };

      services.asterisk = {
        openFirewall = true;
        pjsip = {
          transports.udp.address = "10.1.0.10";
          trunks.provider = {
            host = "10.1.0.5";
            username = "5551000";
            password = secret "sip-trunk";
            registration.contactUser = "5551000";
            # the phones send from the provider's address too
            matchProviderHost = false;
          };
        };
        queues = {
          persistentMembers = true;
          queues = {
            support.members = ["PJSIP/201"];
            sales.members = ["PJSIP/201"];
          };
        };
        # what the test reads back from astdb
        dialplan.contexts.hourstest.extensions.s = [
          "Gosub(pbx-hours-office,s,1)"
          "Set(DB(hourstest/result)=\${GOSUB_RETVAL})"
        ];
      };

      # without the hours and the support queue, with the HTTP server and a
      # queue rule, whose modules stay loaded
      specialisation.changed.configuration = {
        # the context that reads the hours goes with them
        services.asterisk.dialplan.contexts.hourstest.extensions = lib.mkForce {};
        pbx = {
          hours = lib.mkForce {};
          inbound."5551000" = lib.mkForce {
            trunk = "provider";
            destination.extension = "201";
          };
          queues = lib.mkForce {sales.number = "610";};
        };
        services.asterisk = {
          queues.queues = lib.mkForce {sales.members = ["PJSIP/201"];};
          http.enable = true;
          settings."queuerules.conf".ramp.penaltychange = "30,+1";
        };
      };
    };

    nodes.provider = {
      config,
      lib,
      ...
    }: {
      imports = [
        self.nixosModules.default
        ./common.nix
        ./phone.nix
        (import ./secrets.nix {fixed.customer = "trunk-password";})
      ];

      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "10.1.0.5";
          prefixLength = 24;
        }
      ];

      services.asterisk = {
        enable = true;
        openFirewall = true;
        pjsip = {
          transports.udp = {};
          # the office's account; the endpoint name is its user name
          endpoints."5551000" = {
            context = "carrier";
            auth.password = config.lib.asterisk.secret "/run/test-secrets/customer";
          };
        };
        dialplan.contexts = {
          carrier.extensions."_X." = [
            "Answer()"
            "Wait(30)"
            "Hangup()"
          ];
          # the provider's side of calls placed to the office
          feed.extensions.s = [
            "Wait(30)"
            "Hangup()"
          ];
        };
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()

        def address_comes_late():
            """The office's Asterisk waits for the address its transport
            binds, which the test adds only then, and listens on it once it
            is there."""
            office.wait_until_succeeds("journalctl -b -u asterisk.service | grep -q 'asterisk-config: waiting for address 10.1.0.10'")
            office.succeed("ip address add 10.1.0.10/24 dev eth1")
            office.wait_for_unit("asterisk.service")
            office.succeed("ss -Hlun 'src 10.1.0.10 and sport = :5060' | grep -q .")

        # the office's Asterisk waits 90 s for its address, so it comes now.
        # The provider is up first, as in reality: the office qualifies its
        # trunk within 5 s of starting and only retries a minute later
        provider.wait_for_unit("asterisk.service")
        address_comes_late()
        office_base = office.succeed("readlink -f /run/current-system").strip()

        pbx.wait_for_unit("asterisk.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        changes = json.load(open("${changesFile}"))

        def switch(specialisation=None, machine=pbx, base=base):
            """Activate a specialisation of `machine` (or its base system
            `base`) and return what switch-to-configuration did with
            asterisk.service."""
            target = f"{base}/specialisation/{specialisation}" if specialisation else base
            output = machine.succeed(f"{target}/bin/switch-to-configuration test 2>&1")
            print(output)
            actions = [
                line.split(" the following units:")[0]
                for line in output.splitlines()
                if " the following units:" in line and "asterisk.service" in line
            ]
            return actions

        def main_pid(machine=pbx):
            return machine.succeed("systemctl show -P MainPID asterisk.service").strip()

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

        def columns(table):
            return pbx.succeed(f"{SQLITE} \"select name from pragma_table_info('{table}')\"").split()

        def shown(change):
            return change["shows"] in asterisk(pbx, change["show"])

        def registers(*phones):
            """REGISTER requests the phones, alice and bob unless given, have sent."""
            return {p.name: p.count("TX [0-9]+ bytes Request msg REGISTER/") for p in phones or (alice, bob)}

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
            channel_events_recorded()

        with subtest("switching back applies the old files with the same reloads, during the call"):
            since, cursor = marks(), journal_cursor(pbx)
            assert switch() == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            assert reloads(cursor) == every_reload, reloads(cursor)
            for file, change in changes.items():
                assert change["show"] is None or not shown(change), (file, asterisk(pbx, change["show"]))
            audio_went_on(since)
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

        with subtest("a secret PIN no phone can type fails the reload, and the mailbox keeps its PIN"):
            # VoiceMailMain takes a PIN that starts with * for a jump to extension a
            cursor = journal_cursor(pbx)
            pbx.succeed("printf '*4242' > /run/secrets/pin")
            pbx.fail("systemctl reload asterisk.service")
            wait_journal(pbx, cursor, "secret /run/secrets/pin is in a voicemail PIN")
            assert "Result: -4242\n" in asterisk(pbx, "dialplan eval function VM_INFO(102@default,password)")
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

        sqlite_reloads = ["module refresh cel_sqlite3_custom.so", "module reload cdr_sqlite3_custom.so"]

        with subtest("a deploy that names CDR and CEL columns master.db lacks adds them, and the records fill them"):
            # created before Asterisk started, as Asterisk would have created it
            assert pbx.succeed("stat -c '%U:%G %a' /var/log/asterisk/master.db").strip() == "asterisk:asterisk 640"
            cursor = journal_cursor(pbx)
            assert switch("columns") == ["reloading"]
            assert reloads(cursor) == sqlite_reloads, reloads(cursor)
            number = record_call()
            wait_row(f"select 1 from cdr where dst = '{number}' and length(linkedid) > 0")
            wait_row(f"select 1 from cel where exten = '{number}' and eventenum = 'CHAN_END'")

        with subtest("a deploy that names other tables creates them, and the records go there"):
            cursor = journal_cursor(pbx)
            assert switch("tables") == ["reloading"]
            assert reloads(cursor) == sqlite_reloads, reloads(cursor)
            number = record_call()
            wait_row(f"select 1 from calls where dst = '{number}'")
            wait_row(f"select 1 from events where exten = '{number}' and eventtype = 'CHAN_END'")

        with subtest("switching back keeps every table and column, and the records go to the first tables again"):
            assert switch() == ["reloading"]
            number = record_call()
            wait_row(f"select 1 from cdr where dst = '{number}' and linkedid is null")
            wait_row(f"select 1 from cel where exten = '{number}' and eventtype = 'CHAN_END' and eventenum is null")
            assert columns("calls") and columns("events"), (columns("calls"), columns("events"))

        with subtest("a deploy with a column master.db cannot take fails and applies nothing, and a reload applies it once master.db takes it"):
            pid, cursor = main_pid(), journal_cursor(pbx)
            pbx.succeed(f"{SQLITE} 'ALTER TABLE cdr DROP COLUMN linkedid' && chattr +i /var/log/asterisk/master.db")
            status, output = pbx.execute(f"{base}/specialisation/columns/bin/switch-to-configuration test 2>&1")
            assert status == 4 and "Failed to reload asterisk.service" in output, output
            assert main_pid() == pid, "asterisk was restarted"
            journal = journal_since(pbx, cursor)
            assert "sqlite-tables: cannot add the columns that cdr_sqlite3_custom.conf names to cdr in /var/log/asterisk/master.db" in journal, journal
            assert reloads(cursor) == [], journal
            pbx.fail("grep -q linkedid /run/asterisk/config/cdr_sqlite3_custom.conf")
            pbx.succeed("chattr -i /var/log/asterisk/master.db")
            cursor = journal_cursor(pbx)
            pbx.succeed("systemctl reload asterisk.service")
            assert reloads(cursor) == sqlite_reloads, reloads(cursor)
            number = record_call()
            wait_row(f"select 1 from cdr where dst = '{number}' and length(linkedid) > 0")
            assert switch() == ["reloading"]

        with subtest("Asterisk starts when master.db cannot take a column it lacks, and the next start adds it"):
            pid, cursor = main_pid(), journal_cursor(pbx)
            pbx.succeed(f"{SQLITE} 'ALTER TABLE cel DROP COLUMN peer' && chattr +i /var/log/asterisk/master.db")
            pbx.succeed("systemctl restart asterisk.service")
            assert main_pid() != pid, "asterisk was not restarted"
            journal = journal_since(pbx, cursor)
            assert "sqlite-tables: cannot add the columns that cel_sqlite3_custom.conf names to cel in /var/log/asterisk/master.db" in journal, journal
            assert "asterisk-config: starting Asterisk with master.db as it is" in journal, journal
            pbx.succeed("chattr -i /var/log/asterisk/master.db")
            pbx.succeed("systemctl restart asterisk.service")
            assert "peer" in columns("cel"), columns("cel")
            channel_events_recorded()
            registrations_kept(registered)

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

        with subtest("with pbx_ael loaded, a deploy of extensions.conf or extensions.ael reloads pbx_config and then pbx_ael, and the AEL globals stay"):
            # pbx_config's reload clears every global, and pbx_ael sets its own
            # when it loads extensions.ael
            ael.wait_for_unit("asterisk.service")
            ael_base = ael.succeed("readlink -f /run/current-system").strip()
            both = {"AEL": "ael", "CONF": "conf"}
            for specialisation, more in (("conf", False), (None, False), ("ael", True), (None, False)):
                cursor = journal_cursor(ael)
                switch(specialisation, ael, ael_base)
                journal = journal_since(ael, cursor)
                assert not re.search(r"asterisk-config: .* failed", journal), journal
                commands = re.findall(r"asterisk-config: (module reload \S+|core reload)$", journal, re.M)
                assert commands == ["module reload pbx_config.so", "module reload pbx_ael.so"], (specialisation, commands)
                found = dict(re.findall(r"^   (\w+)=(.*)$", asterisk(ael, "dialplan show globals"), re.M))
                assert found == both, (specialisation, found)
                assert ("Context 'more-ael'" in asterisk(ael, "dialplan show more-ael")) == more, specialisation

        def db(family, key):
            match = re.search(r"^Value: (.*)$", asterisk(office, f"database get {family} {key}"), re.M)
            return match.group(1) if match else None

        def hours():
            """What pbx-hours-office returns now on the office."""
            asterisk(office, "database del hourstest result")
            asterisk(office, "channel originate Local/s@hourstest application Wait 5")
            office.wait_until_succeeds("asterisk -rx 'database get hourstest result' | grep -q '^Value: '", timeout=30)
            return db("hourstest", "result")

        def quiet(journal):
            """Asterisk logged no warning and no error."""
            assert not re.search(r"(WARNING|ERROR)\[", journal), journal

        def trunk_registered():
            office.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -qE '^ provider/sip:10\\.1\\.0\\.5[^ ]* .* Registered'", timeout=60)

        # the phones register for an hour, so a registration after the reboot
        # can only come from astdb
        reception = Phone(provider, "201", "201", "pw-201", "10.1.0.10", sip_port=5070, cli_port=2300)
        sales = Phone(provider, "202", "202", "pw-202", "10.1.0.10", sip_port=5071, cli_port=2301)

        with subtest("on a pbx layer system, closing early and a queue member added at runtime are kept in astdb"):
            trunk_registered()
            provider.succeed("\n".join(p.start_command("--reg-timeout=3600") for p in (reception, sales)))
            wait_registrations({reception: 200, sales: 200})
            office_registered = registers(reception, sales)
            reception.call("*28")
            office.wait_until_succeeds("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'")
            assert hours() == "closed"
            asterisk(office, "queue add member PJSIP/202 to support")
            assert re.search(r"PJSIP/202.*\(dynamic\)", asterisk(office, "queue show support"))
            assert db("CustomDevstate", "pbx-hours-office") == "INUSE"
            assert db("Queue/PersistentMembers", "support").startswith("PJSIP/202;")
            wait_idle(office)

        with subtest("a deploy that removes the hours and the queue keeps their astdb keys, and Asterisk logs nothing"):
            office_pid, cursor = main_pid(office), journal_cursor(office)
            assert switch("changed", office, office_base) == ["reloading"]
            assert main_pid(office) == office_pid, "asterisk was restarted"
            quiet(journal_since(office, cursor))
            assert "No hints matching extension *28" in asterisk(office, "core show hint *28")
            assert "No such queue: support." in asterisk(office, "queue show support")
            assert db("CustomDevstate", "pbx-hours-office") == "INUSE"
            assert db("Queue/PersistentMembers", "support").startswith("PJSIP/202;")
            office.succeed("ss -Hltn 'sport = :8088' | grep -q .")
            assert "Rule: ramp" in asterisk(office, "queue show rules")

        with subtest("switching back brings the hours back closed, and turns off the HTTP server and removes the rule"):
            cursor = journal_cursor(office)
            assert switch(None, office, office_base) == ["reloading"]
            assert main_pid(office) == office_pid, "asterisk was restarted"
            quiet(journal_since(office, cursor))
            assert "State:InUse" in asterisk(office, "core show hint *28")
            assert hours() == "closed"
            # app_queue reads the members astdb keeps only when it loads
            # (apps/app_queue.c load_module), so the runtime member waits for
            # the next start
            queue = asterisk(office, "queue show support")
            assert "PJSIP/201" in queue and "PJSIP/202" not in queue, queue
            office.fail("ss -Hltn 'sport = :8088' | grep -q .")
            assert "Rule: ramp" not in asterisk(office, "queue show rules")

        with subtest("after a reboot, asterisk waits for its address, the registrations come back from astdb, the trunk registers, the state is back, and a call from the provider reaches the phone of the closed destination"):
            office.shutdown()
            office.start()
            address_comes_late()
            for phone in (reception, sales):
                office.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE ' {phone.user}/sip:{phone.user}@[^ ]+ +[^ ]+ +Avail '")
            assert registers(reception, sales) == office_registered
            trunk_registered()
            assert "State:InUse" in asterisk(office, "core show hint *28")
            assert hours() == "closed"
            assert re.search(r"PJSIP/202.*\(dynamic\)", asterisk(office, "queue show support"))
            answered = sales.confirmed()
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            sales.wait_confirmed(after=answered)
            wait_bridged(office, "provider", "202")
            assert reception.requests("INVITE") == 0
            sales.hangup()
            wait_idle(office)
      '';
  }
