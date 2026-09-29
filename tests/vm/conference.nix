# ConfBridge rooms built from the typed profiles and pbx.conferences, checked
# by what each phone hears: seven phones on G.711 and one on G.722 in a
# recorded room hear each other at their own pitch and never themselves, and
# the recording holds all eight; guests wait muted for a chair, who hears
# none of them until one unmutes, kicks the last guest with a DTMF menu and
# ends the meeting by leaving; a room behind a PIN from a secret, dialled from
# the core dialplan or its pbx number, turns away a wrong PIN and, once full,
# further callers but not an admin; the default profiles, through a pbx
# conference and the core dialplan: music on hold for a caller alone, the
# number of the others for the next, join sounds in the room's language but
# none for a quiet user, and the room's limit; each action of a user's DTMF
# menu but the two that reset a volume, and of an admin's
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = map toString (lib.range 401 408);
  # the codec of each phone: G.722 on 408, G.711 in either law on the others
  codecs = lib.genAttrs extensions (extension:
    if extension == "408"
    then "g722"
    else if extension < "405"
    then "ulaw"
    else "alaw");

  # tones above those of the phones (tests/vm/phone.py): music on hold, the
  # prompts the user menu plays and the join sound in language xx
  tones = {
    moh = 2300;
    one = 2500;
    two = 2700;
    three = 2900;
    four = 3100;
    join = 3300;
  };
  # files of 8 kHz signed linear audio, each `seconds` of `tone`
  toneFiles = name: files:
    pkgs.runCommand name {nativeBuildInputs = [pkgs.sox];} (lib.concatStrings (lib.mapAttrsToList (path: file: ''
        mkdir -p "$(dirname $out/${path})"
        sox -n -r 8000 -b 16 -c 1 -e signed-integer -t raw $out/${path} synth ${toString file.seconds} sine ${toString file.tone} vol 0.5
      '')
      files));
  moh = toneFiles "test-moh" {
    "tone.sln" = {
      seconds = 1;
      tone = tones.moh;
    };
  };
  sounds = toneFiles "test-conference-sounds" {
    "sounds/test/one.sln" = {
      seconds = 0.5;
      tone = tones.one;
    };
    "sounds/test/two.sln" = {
      seconds = 0.5;
      tone = tones.two;
    };
    # long enough to be cut short by a key
    "sounds/test/three.sln" = {
      seconds = 5;
      tone = tones.three;
    };
    "sounds/test/four.sln" = {
      seconds = 0.5;
      tone = tones.four;
    };
    "sounds/xx/confbridge-join.sln" = {
      seconds = 0.5;
      tone = tones.join;
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-conference";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {conference-pin = "4321";}
              // lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        pbx = {
          enable = true;
          conferences = {
            # the room 820 of the core dialplan, with the same profiles
            "820" = {
              number = "825";
              bridgeProfile = "small";
              userProfile = "pinned";
            };
            lobby.number = "870";
          };
        };

        services.asterisk = {
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
              allow = [codecs.${extension}];
            });
          };

          musicOnHold.classes.default.directory = moh;
          sounds.packages = [sounds];

          confbridge = {
            bridges = {
              default_bridge = {
                maxMembers = 3;
                language = "xx";
              };
              recorded.recordConference = true;
              meeting = {};
            };
            users = {
              default_user = {
                musicOnHoldWhenEmpty = true;
                announceUserCount = true;
              };
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
              member = {};
              hush.quiet = true;
            };
            menus = {
              chair_menu = {
                "*1" = "admin_kick_last";
                "*2" = "admin_toggle_conference_lock";
                "*3" = "admin_toggle_mute_participants";
              };
              user_menu = {
                "1" = "toggle_mute";
                "2" = "no_op";
                "3" = "decrease_listening_volume";
                "4" = "increase_listening_volume";
                "5" = "reset_listening_volume";
                "6" = "decrease_talking_volume";
                "7" = "increase_talking_volume";
                "8" = "reset_talking_volume";
                "9" = "participant_count";
                # a key during the prompt of * runs the entry of * and that key
                "*" = "playback_and_continue(test/three)";
                "*1" = "playback(test/one&test/two)";
                "*2" = "dialplan_exec(office,850,1)";
                "0" = "leave_conference";
              };
            };
          };
          # a bridge profile written in settings, as pbx.conferences."820" names it
          settings."confbridge.conf".small = {
            type = "bridge";
            max_members = 3;
          };

          dialplan.contexts.office = {
            includes = ["pbx-internal"];
            extensions = {
              "800" = [
                "Answer()"
                "ConfBridge(800,recorded,member)"
                "Hangup()"
              ];
              # guests dial 810, the chair 811
              "810" = [
                "Answer()"
                "ConfBridge(810,meeting,guest,user_menu)"
                "Hangup()"
              ];
              "811" = [
                "Answer()"
                "ConfBridge(810,meeting,chair,chair_menu)"
                "Hangup()"
              ];
              "820" = [
                "Answer()"
                "ConfBridge(820,small,pinned)"
                "Hangup()"
              ];
              # an admin, who needs no PIN
              "821" = [
                "Answer()"
                "ConfBridge(820,small,chair)"
                "Hangup()"
              ];
              "840" = [
                "Answer()"
                "ConfBridge(840,meeting,member,user_menu)"
                "Set(DB(test/left)=\${CONFBRIDGE_RESULT})"
                "Hangup()"
              ];
              "841" = [
                "Answer()"
                "ConfBridge(840,meeting,chair,chair_menu)"
                "Hangup()"
              ];
              # what the user menu's dialplan_exec runs
              "850" = [
                "Set(DB(test/exec)=\${CHANNEL(name)})"
                "Playback(test/four)"
              ];
              # the room of pbx.conferences.lobby
              "871" = [
                "Answer()"
                "ConfBridge(lobby)"
                "Hangup()"
              ];
              "872" = [
                "Answer()"
                "ConfBridge(lobby,,hush)"
                "Hangup()"
              ];
            };
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

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        extensions = ${builtins.toJSON extensions}
        CODECS = ${builtins.toJSON codecs}
        TONES = ${builtins.toJSON tones}
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

        def played(cursor, ext):
            """Sound files played to `ext` since `cursor`, in order."""
            return re.findall(rf"<PJSIP/{ext}-[0-9a-f]+> Playing '([^.']+)\.", journal_since(pbx, cursor))

        def announced(cursor):
            """Sound files the room's announcer played since `cursor`."""
            return re.findall(r"<CBAnn/[^>]+> Playing '([^.']+)\.", journal_since(pbx, cursor))

        def level(p):
            """The median RMS of the 100 ms windows of `p`'s last second"""
            end = recorded(p)
            return float(numpy.median(levels(p, end - sample_rate(p) * 2, end)))

        def wait_level(p, expected, timeout=30):
            """Wait until what `p` hears has the RMS `expected`, within 15 %."""
            deadline = time.time() + timeout
            while True:
                found = level(p)
                if abs(found / expected - 1) < 0.15:
                    return
                if time.time() > deadline:
                    raise Exception(f"{p.name} hears {found:.0f} RMS, expected {expected:.0f}")
                time.sleep(0.5)

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(extensions))

        with subtest("seven phones on G.711 and one on G.722 in a recorded conference hear each other at their own pitch and never themselves, and the recording holds all eight"):
            cli_parallel([(p, f"call new {p.uri('800')}") for p in phone.values()])
            wait_members("800", {ext: "" for ext in extensions})
            stats = wait_for_media_both_ways(pbx, list(phone.values()))
            assert {endpoint_of(channel): s["codec"] for channel, s in stats.items()} == CODECS, stats
            everyone = [p.tone for p in phone.values()]
            for p in phone.values():
                wait_hears(p, [tone for tone in everyone if tone != p.tone])
            cli_parallel([(p, "call hangup_all") for p in phone.values()])
            wait_idle(pbx)
            # 8 kHz signed linear after a 44 byte header
            recording = pbx.succeed("ls /var/lib/asterisk/spool/monitor/confbridge-800-*.wav").strip()
            raw = base64.b64decode(pbx.succeed(f"base64 -w0 {recording}"))
            windows = tones_in(numpy.frombuffer(raw[HEADER:], dtype="<i2").astype(float), 8000)
            # a second of all eight at once
            assert any(all(same(w, everyone) for w in windows[i : i + 10]) for i in range(len(windows) - 9)), windows

        with subtest("guests wait muted for the chair, who hears none of them until one unmutes, kicks the last guest and ends the meeting by leaving"):
            chair = phone["401"]
            guests = ["402", "403", "404"]
            ended = {ext: phone[ext].disconnects() for ext in guests}
            # one after the other, so 404 is the last to join
            for i, ext in enumerate(guests):
                phone[ext].call("810")
                wait_members("810", {guest: "WEmw" for guest in guests[: i + 1]})
            chair.call("811")
            wait_members("810", {"401": "AM", **{guest: "WEm" for guest in guests}})
            for ext in guests:
                wait_hears(phone[ext], [chair.tone])
            mark = recorded(chair)
            wait_hears(chair, [])
            assert not hears_any(heard(chair, mark), [phone[ext].tone for ext in guests]), heard(chair, mark)
            # toggle_mute of the guests' menu
            phone["403"].dtmf("1")
            wait_members("810", {"401": "AM", "402": "WEm", "403": "WE", "404": "WEm"})
            wait_hears(chair, [phone["403"].tone])
            wait_hears(phone["402"], [chair.tone, phone["403"].tone])
            chair.dtmf("*1")
            wait_members("810", {"401": "AM", "402": "WEm", "403": "WE"})
            phone["404"].wait_disconnected(after=ended["404"])
            chair.hangup()
            for ext in ["402", "403"]:
                phone[ext].wait_disconnected(after=ended[ext])
            wait_idle(pbx)

        with subtest("a room behind a PIN, dialled from the core dialplan or its pbx number, rejects a wrong PIN and turns callers away once full, but not an admin"):
            cursor = journal_cursor(pbx)
            phone["405"].call("820")
            wait_prompt(cursor, "405", "conf-getpin")
            phone["405"].dtmf("1111#")
            wait_prompt(cursor, "405", "conf-invalidpin")
            wait_prompt(cursor, "405", "conf-getpin", count=2)
            phone["405"].dtmf("4321#")
            wait_members("820", {"405": ""})
            # the pbx number, then the core dialplan's
            for ext, number in [("406", "825"), ("407", "820")]:
                phone[ext].call(number)
                wait_prompt(cursor, ext, "conf-getpin")
                phone[ext].dtmf("4321#")
            wait_members("820", {"405": "", "406": "", "407": ""})
            ended = phone["408"].disconnects()
            phone["408"].call("825")
            wait_prompt(cursor, "408", "conf-getpin")
            phone["408"].dtmf("4321#")
            wait_prompt(cursor, "408", "conf-locked")
            phone["408"].wait_disconnected(after=ended)
            assert set(members("820")) == {"405", "406", "407"}
            phone["401"].call("821")
            wait_members("820", {"401": "AM", "405": "", "406": "", "407": ""})
            cli_parallel([(phone[ext], "call hangup_all") for ext in ["401", "405", "406", "407"]])
            wait_idle(pbx)

        with subtest("the default profiles, through a pbx conference and the core dialplan: music on hold alone, the number of the others for the next caller, join sounds in the room's language but none for a quiet user, and the room's limit"):
            first, second, quiet, late = (phone[ext] for ext in ["405", "406", "407", "408"])
            cursor = journal_cursor(pbx)
            first.call("870")
            wait_prompt(cursor, "405", "conf-onlyperson")
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/405-")
            wait_hears(first, [TONES["moh"]])
            mark = recorded(first)
            second.call("871")
            wait_members("lobby", {"405": "", "406": ""})
            wait_hears(first, [second.tone])
            wait_hears(second, [first.tone])
            assert "conf-onlyone" in played(cursor, "406"), played(cursor, "406")
            # the announcer plays the join sound in xx, the room's language
            assert hears_any(heard(first, mark), [TONES["join"]]), heard(first, mark)
            joins = announced(cursor).count("confbridge-join")
            mark = recorded(first)
            quiet.call("872")
            wait_members("lobby", {"405": "", "406": "", "407": ""})
            wait_hears(first, [second.tone, quiet.tone])
            assert announced(cursor).count("confbridge-join") == joins, announced(cursor)
            assert not hears_any(heard(first, mark), [TONES["join"]]), heard(first, mark)
            ended = late.disconnects()
            late.call("870")
            wait_prompt(cursor, "408", "conf-locked")
            late.wait_disconnected(after=ended)
            cli_parallel([(p, "call hangup_all") for p in (first, second, quiet)])
            wait_idle(pbx)

        # the user menu's subtests: 402 presses keys, 403 listens, in one call
        user, other = phone["402"], phone["403"]

        with subtest("a user's DTMF menu: toggle_mute mutes and unmutes, no_op does nothing"):
            asterisk(pbx, "database del test exec")
            asterisk(pbx, "database del test left")
            user.call("840")
            other.call("840")
            wait_members("840", {"402": "", "403": ""})
            wait_hears(user, [other.tone])
            wait_hears(other, [user.tone])
            cursor = journal_cursor(pbx)
            user.dtmf("1")
            wait_prompt(cursor, "402", "conf-muted")
            wait_members("840", {"402": "m", "403": ""})
            wait_hears(other, [])
            wait_hears(user, [other.tone])
            user.dtmf("1")
            wait_prompt(cursor, "402", "conf-unmuted")
            wait_hears(other, [user.tone])
            cursor = journal_cursor(pbx)
            user.dtmf("2")
            wait_hears(other, [user.tone])
            assert members("840") == {"402": "", "403": ""}, members("840")
            assert played(cursor, "402") == [], played(cursor, "402")

        # a key adds 1 or -1 to the gain, and a gain of 1 or -1 leaves the
        # audio as it is (main/frame.c ast_frame_adjust_volume_float): two
        # keys halve or double it
        # TODO: press the reset keys once they reset the gain; they add 0 to it
        # (main/audiohook.c ast_audiohook_volume_set), so they change nothing
        with subtest("a user's DTMF menu: the listening and talking volume go down and up"):
            for listener, down, up in [(user, "3", "4"), (other, "6", "7")]:
                normal = level(listener)
                user.dtmf(down * 2)
                wait_level(listener, normal / 2)
                user.dtmf(up * 4)
                wait_level(listener, normal * 2)
                user.dtmf(down * 2)
                wait_level(listener, normal)

        with subtest("a user's DTMF menu: participant_count, playback_and_continue, playback, dialplan_exec and leave_conference"):
            cursor = journal_cursor(pbx)
            user.dtmf("9")
            wait_prompt(cursor, "402", "conf-onlyone")
            # * runs at once, as it is an entry of its own, and the 1 that
            # follows ends its 5 s prompt and runs *1
            mark, other_mark = recorded(user), recorded(other)
            user.dtmf("*1")
            wait_prompt(cursor, "402", "test/two")
            wait_hears(user, [other.tone])
            assert bursts(user, mark, TONES.values()) == [TONES["three"], TONES["one"], TONES["two"]], heard(user, mark)
            prompt = [w for w in heard(user, mark) if w and abs(w[0] - TONES["three"]) <= TOLERANCE]
            assert len(prompt) < 40, heard(user, mark)
            assert not hears_any(heard(other, other_mark), TONES.values()), heard(other, other_mark)
            mark = recorded(user)
            user.dtmf("*2")
            pbx.wait_until_succeeds("asterisk -rx 'database get test exec' | grep -q '^Value: PJSIP/402-'")
            wait_prompt(cursor, "402", "test/four")
            # back in the room
            wait_hears(other, [user.tone])
            wait_hears(user, [other.tone])
            assert bursts(user, mark, TONES.values()) == [TONES["three"], TONES["four"]], heard(user, mark)
            ended = user.disconnects()
            user.dtmf("0")
            user.wait_disconnected(after=ended)
            pbx.wait_until_succeeds("asterisk -rx 'database get test left' | grep -q '^Value: DTMF$'")
            wait_members("840", {"403": ""})
            other.hangup()
            wait_idle(pbx)

        with subtest("an admin's DTMF menu locks the room, which then takes only admins, and mutes everyone but admins"):
            chair, user, other, admin = phone["401"], phone["402"], phone["403"], phone["404"]
            cursor = journal_cursor(pbx)
            user.call("840")
            wait_members("840", {"402": ""})
            chair.call("841")
            wait_members("840", {"401": "AM", "402": ""})
            chair.dtmf("*2")
            wait_prompt(cursor, "401", "conf-lockednow")
            ended = other.disconnects()
            other.call("840")
            wait_prompt(cursor, "403", "conf-locked")
            other.wait_disconnected(after=ended)
            admin.call("841")
            wait_members("840", {"401": "AM", "402": "", "404": "AM"})
            chair.dtmf("*2")
            wait_prompt(cursor, "401", "conf-unlockednow")
            other.call("840")
            wait_members("840", {"401": "AM", "402": "", "403": "", "404": "AM"})
            chair.dtmf("*3")
            wait_members("840", {"401": "AM", "402": "m", "403": "m", "404": "AM"})
            wait_hears(chair, [admin.tone])
            wait_hears(user, [chair.tone, admin.tone])
            chair.dtmf("*3")
            wait_members("840", {"401": "AM", "402": "", "403": "", "404": "AM"})
            wait_hears(chair, [user.tone, other.tone, admin.tone])
            cli_parallel([(p, "call hangup_all") for p in (chair, user, other, admin)])
            wait_idle(pbx)

        with subtest("the PIN is a secret"):
            pbx.fail("grep -R 4321 /etc/asterisk/")
            pbx.succeed("grep -q '^pin = 4321$' /run/asterisk/config/confbridge.conf")
      '';
  }
