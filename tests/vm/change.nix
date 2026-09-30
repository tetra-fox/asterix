# Deploying changes to a pbx whose objects keep state in astdb, and a full
# reboot. A deploy that removes the opening hours while closed early and a
# queue with a member added at runtime leaves their astdb keys alone and logs
# nothing; switching back brings the hours back closed, and the queue without
# its runtime member until the next start. The same deploy turns
# on the HTTP server and adds a queue rule, which switching back turns off and
# removes again. After a reboot, in which Asterisk waits for the address its
# transport binds (D38), the phones' registrations come back from astdb
# without the phones registering again, the trunk registers, the hours are
# still closed, the runtime queue member is back, and a call from the
# provider reaches the phone of the closed destination.
#
#   pbx       10.1.0.10, which its transport binds and which comes up late
#   provider  10.1.0.5, a second Asterisk that takes the pbx's registration
#   phones    10.1.0.21, runs 201 and 202
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  onlyAddress = address: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-change";

    nodes = {
      pbx = {
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

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {fixed.customer = "trunk-password";})
          (onlyAddress "10.1.0.5")
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

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddress "10.1.0.21")
        ];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        # a provider is up before the office starts, as in reality: the office
        # qualifies its trunk within 5 s of starting and only retries a minute later
        provider.start()
        provider.wait_for_unit("asterisk.service")
        start_all()

        def address_comes_late():
            """Asterisk waits for the address its transport binds (D38), which
            the test adds only then, and listens on it once it is there."""
            pbx.wait_until_succeeds("journalctl -b -u asterisk.service | grep -q 'asterisk-config: waiting for address 10.1.0.10'")
            pbx.succeed("ip address add 10.1.0.10/24 dev eth1")
            pbx.wait_for_unit("asterisk.service")
            pbx.succeed("ss -Hlun 'src 10.1.0.10 and sport = :5060' | grep -q .")

        address_comes_late()
        base = pbx.succeed("readlink -f /run/current-system").strip()

        def switch(specialisation=None):
            """Activate a specialisation (or the base system) and return what
            switch-to-configuration did with asterisk.service."""
            target = f"{base}/specialisation/{specialisation}" if specialisation else base
            output = pbx.succeed(f"{target}/bin/switch-to-configuration test 2>&1")
            print(output)
            return [
                line.split(" the following units:")[0]
                for line in output.splitlines()
                if " the following units:" in line and "asterisk.service" in line
            ]

        def main_pid():
            return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        def db(family, key):
            output = asterisk(pbx, f"database get {family} {key}")
            match = re.search(r"^Value: (.*)$", output, re.M)
            return match.group(1) if match else None

        def hours():
            """What pbx-hours-office returns now."""
            asterisk(pbx, "database del hourstest result")
            asterisk(pbx, "channel originate Local/s@hourstest application Wait 5")
            pbx.wait_until_succeeds("asterisk -rx 'database get hourstest result' | grep -q '^Value: '", timeout=30)
            return db("hourstest", "result")

        def quiet(journal):
            """Asterisk logged no warning and no error."""
            assert not re.search(r"(WARNING|ERROR)\[", journal), journal

        def registers():
            """REGISTER requests the phones have sent."""
            return {p.name: p.count("TX [0-9]+ bytes Request msg REGISTER/") for p in (reception, sales)}

        def trunk_registered():
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -qE '^ provider/sip:10\\.1\\.0\\.5[^ ]* .* Registered'", timeout=60)

        # the phones register for an hour, so a registration after the reboot
        # can only come from astdb
        reception = Phone(phones, "201", "201", "pw-201", "10.1.0.10", sip_port=5060, cli_port=2300)
        sales = Phone(phones, "202", "202", "pw-202", "10.1.0.10", sip_port=5061, cli_port=2301)

        with subtest("the trunk and the phones register"):
            trunk_registered()
            phones.succeed("\n".join(p.start_command("--reg-timeout=3600") for p in (reception, sales)))
            wait_registrations({reception: 200, sales: 200})
            registered = registers()

        with subtest("closing early and a queue member added at runtime are kept in astdb"):
            reception.call("*28")
            pbx.wait_until_succeeds("asterisk -rx 'core show hint *28' | grep -q 'State:InUse'")
            assert hours() == "closed"
            asterisk(pbx, "queue add member PJSIP/202 to support")
            assert re.search(r"PJSIP/202.*\(dynamic\)", asterisk(pbx, "queue show support"))
            assert db("CustomDevstate", "pbx-hours-office") == "INUSE"
            assert db("Queue/PersistentMembers", "support").startswith("PJSIP/202;")
            wait_idle(pbx)

        with subtest("a deploy that removes the hours and the queue keeps their astdb keys, and Asterisk logs nothing"):
            pid, cursor = main_pid(), journal_cursor(pbx)
            assert switch("changed") == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            quiet(journal_since(pbx, cursor))
            assert "No hints matching extension *28" in asterisk(pbx, "core show hint *28")
            assert "No such queue: support." in asterisk(pbx, "queue show support")
            assert db("CustomDevstate", "pbx-hours-office") == "INUSE"
            assert db("Queue/PersistentMembers", "support").startswith("PJSIP/202;")
            pbx.succeed("ss -Hltn 'sport = :8088' | grep -q .")
            assert "Rule: ramp" in asterisk(pbx, "queue show rules")

        with subtest("switching back brings the hours back closed, and turns off the HTTP server and removes the rule"):
            cursor = journal_cursor(pbx)
            assert switch() == ["reloading"]
            assert main_pid() == pid, "asterisk was restarted"
            quiet(journal_since(pbx, cursor))
            assert "State:InUse" in asterisk(pbx, "core show hint *28")
            assert hours() == "closed"
            # app_queue reads the members astdb keeps only when it loads
            # (apps/app_queue.c load_module), so the runtime member waits for
            # the next start
            queue = asterisk(pbx, "queue show support")
            assert "PJSIP/201" in queue and "PJSIP/202" not in queue, queue
            pbx.fail("ss -Hltn 'sport = :8088' | grep -q .")
            assert "Rule: ramp" not in asterisk(pbx, "queue show rules")

        with subtest("after a reboot, asterisk waits for its address, the registrations come back from astdb, the trunk registers, and the state is back"):
            pbx.shutdown()
            pbx.start()
            address_comes_late()
            for phone in (reception, sales):
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE ' {phone.user}/sip:{phone.user}@[^ ]+ +[^ ]+ +Avail '")
            assert registers() == registered
            trunk_registered()
            assert "State:InUse" in asterisk(pbx, "core show hint *28")
            assert hours() == "closed"
            assert re.search(r"PJSIP/202.*\(dynamic\)", asterisk(pbx, "queue show support"))

        with subtest("after the reboot, a call from the provider reaches the phone of the closed destination"):
            answered = sales.confirmed()
            provider.succeed("asterisk -rx 'channel originate PJSIP/5551000 extension s@feed'")
            sales.wait_confirmed(after=answered)
            wait_bridged(pbx, "provider", "202")
            assert reception.requests("INVITE") == 0
            sales.hangup()
            wait_idle(pbx)
      '';
  }
