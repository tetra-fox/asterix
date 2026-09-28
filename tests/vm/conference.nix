# ConfBridge rooms built from the typed profiles: eight phones in a recorded
# room hear each other; guests wait muted for a chair, who kicks the last guest
# with a DTMF menu and ends the meeting by leaving; a room behind a PIN from a
# secret turns away a wrong PIN and, once full, further callers
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = map toString (lib.range 401 408);
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-conference";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {conference-pin = "4321";}
              // lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          # the test follows calls through verbose messages in the journal
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;

          pjsip = {
            transports.udp = {};
            endpoints = lib.genAttrs extensions (extension: {
              context = "office";
              auth.password = secret "/run/test-secrets/sip-${extension}";
            });
          };

          confbridge = {
            bridges = {
              recorded.recordConference = true;
              small.maxMembers = 3;
            };
            users = {
              chair = {
                admin = true;
                marked = true;
              };
              guest = {
                waitMarked = true;
                endMarked = true;
                startMuted = true;
              };
              pinned.pin = secret "/run/test-secrets/conference-pin";
            };
            menus.chair_menu."*1" = "admin_kick_last";
          };

          dialplan.contexts.office.extensions = {
            "800" = [
              "Answer()"
              "ConfBridge(800,recorded)"
              "Hangup()"
            ];
            # guests dial 810, the chair 811
            "810" = [
              "Answer()"
              "ConfBridge(810,,guest)"
              "Hangup()"
            ];
            "811" = [
              "Answer()"
              "ConfBridge(810,,chair,chair_menu)"
              "Hangup()"
            ];
            "820" = [
              "Answer()"
              "ConfBridge(820,small,pinned)"
              "Hangup()"
            ];
          };
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

        extensions = ${builtins.toJSON extensions}
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(extensions)
        }

        def members(conference):
            """Endpoint -> flags of the users in `conference` (A admin, M marked,
            W wait for marked, E end with marked, m muted, w waiting)."""
            found = {}
            for line in asterisk(pbx, f"confbridge list {conference}").splitlines():
                if line.startswith("PJSIP/"):
                    found[endpoint_of(line[:30].strip())] = line[31:37].strip()
            return found

        def wait_members(conference, expected, timeout=90):
            deadline = time.time() + timeout
            while True:
                found = members(conference)
                if found == expected:
                    return
                if time.time() > deadline:
                    raise Exception(f"conference {conference} has {found}, expected {expected}")
                time.sleep(1)

        def wait_prompt(cursor, ext, prompt, count=1):
            wait_journal(pbx, cursor, f"<PJSIP/{ext}-[0-9a-f]+> Playing '{prompt}\\.", count=count)

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(extensions))

        with subtest("eight phones in a recorded conference hear each other"):
            cli_parallel([(p, f"call new {p.uri('800')}") for p in phone.values()])
            wait_members("800", {ext: "" for ext in extensions})
            print(wait_for_media_both_ways(pbx, list(phone.values())))
            cli_parallel([(p, "call hangup_all") for p in phone.values()])
            wait_idle(pbx)
            pbx.succeed("find /var/lib/asterisk/spool/monitor -name 'confbridge-800-*.wav' -size +10k | grep -q .")

        with subtest("guests wait for the chair, who kicks one and ends the meeting by leaving"):
            guests = ["402", "403", "404"]
            ended = {ext: phone[ext].disconnects() for ext in guests}
            # one after the other, so 404 is the last to join
            for i, ext in enumerate(guests):
                phone[ext].call("810")
                wait_members("810", {guest: "WEmw" for guest in guests[: i + 1]})
            phone["401"].call("811")
            wait_members("810", {"401": "AM", **{guest: "WEm" for guest in guests}})
            phone["401"].dtmf("*1")
            wait_members("810", {"401": "AM", "402": "WEm", "403": "WEm"})
            phone["404"].wait_disconnected(after=ended["404"])
            phone["401"].hangup()
            for ext in ["402", "403"]:
                phone[ext].wait_disconnected(after=ended[ext])
            wait_idle(pbx)

        with subtest("a room behind a PIN rejects a wrong PIN and turns callers away when full"):
            cursor = journal_cursor(pbx)
            phone["405"].call("820")
            wait_prompt(cursor, "405", "conf-getpin")
            phone["405"].dtmf("1111#")
            wait_prompt(cursor, "405", "conf-invalidpin")
            wait_prompt(cursor, "405", "conf-getpin", count=2)
            phone["405"].dtmf("4321#")
            wait_members("820", {"405": ""})
            for ext in ["406", "407"]:
                phone[ext].call("820")
                wait_prompt(cursor, ext, "conf-getpin")
                phone[ext].dtmf("4321#")
            wait_members("820", {"405": "", "406": "", "407": ""})
            ended = phone["408"].disconnects()
            phone["408"].call("820")
            wait_prompt(cursor, "408", "conf-getpin")
            phone["408"].dtmf("4321#")
            wait_prompt(cursor, "408", "conf-locked")
            phone["408"].wait_disconnected(after=ended)
            assert set(members("820")) == {"405", "406", "407"}
            cli_parallel([(phone[ext], "call hangup_all") for ext in ["405", "406", "407"]])
            wait_idle(pbx)

        with subtest("the PIN is a secret"):
            pbx.fail("grep -R 4321 /etc/asterisk/")
            pbx.succeed("grep -q '^pin = 4321$' /run/asterisk/config/confbridge.conf")
      '';
  }
