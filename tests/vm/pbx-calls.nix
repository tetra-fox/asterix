# Calls through the trunks of the pbx layer, checked by who rings and what
# the provider receives on the wire. Inbound: a number a trunk sends, written
# with a +, reaches its destination, and so does the number of a second
# trunk to the same provider, which the line parameter tells apart.
# Outbound: the provider gets the number without the prefix #, with
# services.asterix.outbound's caller ID in P-Asserted-Identity and the account in From.
# Recording: a call out from 203, which records, is recorded from the
# answer into a file only the asterisk user reads, which the timer of
# keepDays deletes a day later.
# Emergency: each number, with and without the prefix, leaves for the
# provider within a second of the phone's INVITE from every extension, with
# services.asterix.outbound's caller ID as it has none of its own, while notify rings the
# other extensions, one of them not registered, but not the caller's own,
# with the caller's name as written, quotes and letters outside ASCII
# included.
#
#   pbx       10.2.0.10, trunks provider and second
#   provider  10.2.0.5, accounts office (provider) and 5552000 (second)
#   phones    10.2.0.21, runs 201 and 202 (ring) and 203 (answers); 205 is
#             never registered
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  names = {
    "201" = ''Front "Desk"'';
    "202" = builtins.fromJSON ''"J\u00fcrgen M\u00fcller"'';
    "203" = builtins.fromJSON ''"\u53d7\u4ed8 \u5c71\u7530"'';
    "205" = "Store";
  };

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
    name = "asterisk-pbx-calls";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {
                sip-provider = "provider-password";
                sip-second = "second-password";
                vm-200 = "4200";
              }
              // lib.concatMapAttrs (extension: _: {
                "sip-${extension}" = "pw-${extension}";
                "vm-${extension}" = "4${extension}";
              })
              names;
          })
          (onlyAddress "10.2.0.10")
        ];

        # a user who copies the recordings elsewhere
        users.groups.archive = {};
        users.users.archiver = {
          isSystemUser = true;
          group = "archive";
        };

        services.asterix = {
          enable = true;
          extensions =
            lib.mapAttrs (extension: name: {
              inherit name;
              password = secret "sip-${extension}";
              voicemail.pin = secret "vm-${extension}";
              record = extension == "203";
            })
            names;
          recordings = {
            keepDays = 1;
            group = "archive";
          };

          voicemail.mailboxes."200" = {
            name = "Front desk";
            pin = secret "vm-200";
          };

          inbound = {
            "+15551001" = {
              trunk = "provider";
              destination.extension = "201";
            };
            "5552000" = {
              trunk = "second";
              destination.voicemail = "200";
            };
          };

          outbound = {
            prefix = "#";
            trunk = "provider";
            callerId = "5551000";
          };

          emergency = {
            numbers = [
              "911"
              "112"
            ];
            trunk = "provider";
            # without a callerId of its own, emergency calls present
            # services.asterix.outbound.callerId
            notify = [
              "201"
              "202"
              "205"
            ];
          };

          trunks = {
            provider = {
              host = "10.2.0.5";
              # not the office's number, so the provider cannot take the
              # caller ID from the account
              username = "office";
              password = secret "sip-provider";
              registration.contactUser = "5551000";
            };
            # the same provider: a call to either registration carries its
            # line parameter, which Asterisk checks before the address
            second = {
              host = "10.2.0.5";
              username = "5552000";
              password = secret "sip-second";
              registration.contactUser = "5552000";
            };
          };
        };

        services.asterisk = {
          openFirewall = true;
          # the journal shows where each call went
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
        };
      };

      provider = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.asterisk
          ./common.nix
          (import ./secrets.nix {
            fixed = {
              provider = "provider-password";
              second = "second-password";
            };
          })
          (onlyAddress "10.2.0.5")
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            # the office's accounts; an endpoint's name is its user name
            endpoints = {
              office = {
                context = "carrier";
                auth.password = secret "provider";
              };
              "5552000" = {
                context = "carrier";
                auth.password = secret "second";
              };
            };
          };
          dialplan.contexts = {
            # calls from the office, which the test hangs up
            carrier.extensions."_X." = [
              "Answer()"
              "Wait(120)"
            ];
            # calls to the office, which the test hangs up
            feed.extensions.s = ["Wait(120)"];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddress "10.2.0.21")
        ];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        provider.wait_for_unit("asterisk.service")

        NAMES = ${builtins.toJSON names}

        desk = Phone(phones, "201", "201", "pw-201", "10.2.0.10", sip_port=5060, cli_port=2300, auto_answer=180)
        sales = Phone(phones, "202", "202", "pw-202", "10.2.0.10", sip_port=5061, cli_port=2301, auto_answer=180)
        boss = Phone(phones, "203", "203", "pw-203", "10.2.0.10", sip_port=5062, cli_port=2302)
        everyone = [desk, sales, boss]

        def invites(phones):
            return {p.name: p.requests("INVITE") for p in phones}

        def sent(mark, start, destination):
            """Messages starting with `start` that the pbx sent to an address
            starting with `destination`, after the first `mark` messages of
            its capture."""
            return [
                m for m in sip_messages(pbx)[mark:]
                if m["source"].startswith("10.2.0.10:") and m["destination"].startswith(destination) and m["text"].startswith(start)
            ]

        def wait_sent(mark, start, destination, timeout=30):
            deadline = time.time() + timeout
            while not (found := sent(mark, start, destination)):
                if time.time() > deadline:
                    raise Exception(f"the pbx sent no {start!r} to {destination}")
                time.sleep(0.5)
            return found

        def header(message, name):
            match = re.search(rf"^{name}: (.*?)\r$", message["text"], re.M)
            assert match, message["text"]
            return match.group(1)

        def quoted(name):
            """A display name as a SIP quoted string"""
            return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'

        def hang_up(*phones):
            cli_parallel([(p, "call hangup_all") for p in phones])
            asterisk(provider, "channel request hangup all")
            wait_idle(pbx)

        with subtest("the trunks and the phones register"):
            pbx.wait_until_succeeds("test $(asterisk -rx 'pjsip show registrations' | grep -c Registered) -eq 2", timeout=120)
            # calls only go to a reachable contact
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -q 'provider/sip:10.2.0.5.* Avail'", timeout=60)
            start_phones(everyone)
            wait_registrations({p: 200 for p in everyone})

        with subtest("a number a trunk sends, written with a +, reaches its destination, and so does the number of a second trunk to the same provider"):
            before = invites([desk])
            asterisk(provider, "channel originate PJSIP/+15551001@office extension s@feed")
            desk.wait_request("INVITE", after=before["201"])
            hang_up()
            # through the second trunk, which the line parameter tells apart
            asterisk(provider, "channel originate PJSIP/5552000@5552000 extension s@feed")
            channel = wait_channel(pbx, "second", app="VoiceMail", timeout=30)
            assert channel["data"] == "200@default,u", channel
            hang_up()

        def presents_office(invite):
            """The pbx's INVITE to the provider has services.asterix.outbound's caller ID
            in P-Asserted-Identity, and the account in From."""
            assert "<sip:5551000@" in header(invite, "P-Asserted-Identity"), invite["text"]
            assert "<sip:office@" in header(invite, "From"), invite["text"]

        with subtest("the provider gets a number outside without the prefix #, and the office number"):
            mark = len(sip_messages(pbx))
            boss.call("#5559999")
            presents_office(wait_sent(mark, "INVITE sip:5559999@10.2.0.5", "10.2.0.5:")[0])
            hang_up(boss)

        with subtest("a call of a phone that records is recorded once it is answered, and a day later deleted"):
            monitor = "/var/lib/asterisk/spool/monitor"
            pbx.succeed(f"rm -f {monitor}/*")
            boss.call("#5559998")
            # the provider answers at once, and the recording starts with the answer
            pbx.wait_until_succeeds(f"ls {monitor} | grep -q -- -203-5559998-", timeout=30)
            time.sleep(2)
            hang_up(boss)
            (name,) = pbx.succeed(f"ls {monitor}").split()
            assert re.fullmatch(r"\d{8}-\d{6}-203-5559998-\d+\.\d+\.wav", name), name
            # the asterisk user's, which recordings.group can only read
            assert pbx.succeed(f"stat -c '%U %G' {monitor} {monitor}/{name}").split() == ["asterisk"] * 4
            pbx.succeed(f"runuser -u archiver -- cat {monitor}/{name} > /dev/null")
            pbx.fail(f"runuser -u archiver -- rm -f {monitor}/{name}")
            pbx.fail("runuser -u archiver -- ls /var/lib/asterisk/spool/voicemail")
            pbx.fail(f"runuser -u nobody -- cat {monitor}/{name}")
            size = pbx.succeed(f"stat -c %s {monitor}/{name}")
            # more than the WAV header
            assert int(size) > 44, size
            pbx.succeed(f"touch -d '25 hours ago' {monitor}/{name}", f"runuser -u asterisk -- touch {monitor}/recent.wav")
            pbx.succeed("systemctl start asterisk-recordings-expire.service")
            assert pbx.succeed(f"ls {monitor}").split() == ["recent.wav"]

        def emergency(caller, dialled, number):
            """Places an emergency call, and returns the seconds from the
            phone's first INVITE to the pbx's first INVITE to the provider."""
            mark = len(sip_messages(pbx))
            caller.call(dialled)
            out = wait_sent(mark, f"INVITE sip:{number}@10.2.0.5", "10.2.0.5:")[0]
            presents_office(out)
            # the phone sends # as %23
            request = dialled.replace("#", "%23")
            dialling = next(
                m for m in sip_messages(pbx)[mark:]
                if m["source"] == f"10.2.0.21:{caller.sip_port}" and m["text"].startswith(f"INVITE sip:{request}@")
            )
            return out["time"] - dialling["time"]

        with subtest("each emergency number, with and without the prefix, leaves within a second from every extension, and notify rings the others but not the caller"):
            for caller, dialled, number in [(desk, "911", "911"), (sales, "#112", "112")]:
                (other,) = [p for p in (desk, sales) if p is not caller]
                before = invites([desk, sales])
                delay = emergency(caller, dialled, number)
                assert delay < 1, f"{caller.name} dialled {dialled}: the call left after {delay:.2f} s"
                other.wait_request("INVITE", after=before[other.name])
                invite = other.received("INVITE")[-1]
                assert f"From: {quoted(NAMES[caller.name])} <sip:{caller.name}@" in invite, invite
                # a notify call to the caller would leave within milliseconds
                # of the other's
                time.sleep(1)
                assert caller.requests("INVITE") == before[caller.name], f"{caller.name} was notified of its own emergency call"
                hang_up(desk, sales)
      '';
  }
