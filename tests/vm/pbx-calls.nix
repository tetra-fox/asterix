# Calls between the phones, two trunks and the emergency service through the
# pbx layer, checked by who rings, what the callers hear and get back, and
# what the provider receives on the wire. Extensions: a phone rings for its
# ring time before the no-answer destination takes the call, one that is not
# registered goes there at once, a phone in a call rings again with call
# waiting and answers busy without it, an extension without a mailbox hangs
# up on callers it does not answer, and names with quotes and letters outside
# ASCII reach the phones as written. Inbound: each number a trunk sends,
# written with a + too, reaches its destination, and a number without a route
# on the trunk it arrives on is refused. Outbound: the provider gets the
# number without the prefix #, and a number too short for the pattern is
# refused as incomplete. Numbers with * and #: phones registered as #1 and *2
# ring when their numbers come as %23 and *, which pjsua sends, or as # and
# %2A, which SIPp sends, and a ring group, queue, conference, voice menu with
# a # key, page, the voicemail menu, a close-early number and an inbound
# number reach their objects. Emergency: each number, with and without the
# prefix, leaves for the provider within a second of the phone's INVITE from
# every extension, and so does a second call during the first, while notify
# rings the other extensions, one of them busy and one not registered; with
# the provider unreachable, the caller learns it once the trunk's INVITE
# times out.
#
#   pbx       10.2.0.10, trunks provider and second
#   provider  10.2.0.5, accounts 5551000 (provider) and 5552000 (second)
#   phones    10.2.0.21, runs 201 (rings, no call waiting), 202 (rings), 203
#             (answers), 204 (rings, no call waiting, no mailbox), #1 and *2
#             (ring, no mailbox) and SIPp; 205 is never registered
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  names = {
    "201" = ''Front "Desk"'';
    "202" = builtins.fromJSON ''"J\u00fcrgen M\u00fcller"'';
    "203" = builtins.fromJSON ''"\u53d7\u4ed8 \u5c71\u7530"'';
    "204" = "Warehouse";
    "205" = "Store";
  };

  # the voice menu's prompt, a tone above those of the phones (tests/vm/phone.py)
  promptTone = 2500;
  prompts = pkgs.runCommand "test-prompts" {nativeBuildInputs = [pkgs.sox];} ''
    mkdir -p $out/sounds/test
    sox -n -r 8000 -b 16 -c 1 -e signed-integer -t raw $out/sounds/test/menu.sln synth 3 sine ${toString promptTone} vol 0.5
  '';

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
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              {
                sip-provider = "provider-password";
                sip-second = "second-password";
                sip-hash = "pw-hash";
                sip-star = "pw-star";
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

        pbx = {
          enable = true;
          extensions = lib.mkMerge [
            (lib.mapAttrs (extension: name: {
                inherit name;
                password = secret "sip-${extension}";
                voicemail = lib.mkIf (extension != "204") {pin = secret "vm-${extension}";};
              })
              names)
            {
              "201" = {
                ringTime = 3;
                noAnswer.ivr = "menu";
              };
              "202".ringTime = 2;
              "204".ringTime = 2;
              "205".noAnswer.extension = "203";
              "#1" = {
                name = "Hash";
                password = secret "sip-hash";
              };
              "*2" = {
                name = "Star";
                password = secret "sip-star";
              };
            }
          ];

          ivrs.menu = {
            number = "#64";
            prompt.sound = "test/menu";
            options."#".extension = "#1";
          };

          # every other kind of number, with * and # in it
          ringGroups.symbols = {
            number = "6*1";
            members = [
              "#1"
              "*2"
            ];
          };
          queues.symbols.number = "6#2";
          conferences.symbols.number = "*63";
          paging.symbols = {
            number = "65#";
            members = [
              "#1"
              "*2"
            ];
          };
          voicemailMenu = "*97";
          hours.office = {
            timezone = "UTC";
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
            closeEarly = "*28#";
          };

          inbound = {
            "5551000" = {
              trunk = "provider";
              destination.extension = "202";
            };
            "+15551001" = {
              trunk = "provider";
              destination.extension = "201";
            };
            "5552000" = {
              trunk = "second";
              destination.voicemail = "200";
            };
            "*5551002#" = {
              trunk = "provider";
              destination.extension = "#1";
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
            callerId = "5551000";
            notify = [
              "201"
              "202"
              "205"
            ];
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
          sounds.packages = [prompts];
          pjsip = {
            transports.udp = {};
            trunks = {
              provider = {
                host = "10.2.0.5";
                username = "5551000";
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
          voicemail.mailboxes."200" = {
            fullName = "Front desk";
            pin = secret "vm-200";
          };
          queues.queues.symbols.members = ["PJSIP/*2"];
        };
      };

      provider = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.default
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
              "5551000" = {
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
          ./sipp.nix
          (onlyAddress "10.2.0.21")
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
        provider.wait_for_unit("asterisk.service")

        NAMES = ${builtins.toJSON names}
        PROMPT = ${toString promptTone}

        desk = Phone(phones, "201", "201", "pw-201", "10.2.0.10", sip_port=5060, cli_port=2300, auto_answer=180, call_waiting=False)
        sales = Phone(phones, "202", "202", "pw-202", "10.2.0.10", sip_port=5061, cli_port=2301, auto_answer=180)
        boss = Phone(phones, "203", "203", "pw-203", "10.2.0.10", sip_port=5062, cli_port=2302)
        warehouse = Phone(phones, "204", "204", "pw-204", "10.2.0.10", sip_port=5063, cli_port=2303, auto_answer=180, call_waiting=False)
        everyone = [desk, sales, boss, warehouse]
        hash_phone = Phone(phones, "hash", "#1", "pw-hash", "10.2.0.10", sip_port=5064, cli_port=2304, auto_answer=180)
        star_phone = Phone(phones, "star", "*2", "pw-star", "10.2.0.10", sip_port=5065, cli_port=2305, auto_answer=180)
        symbols = [hash_phone, star_phone]

        def invites(phones):
            return {p.name: p.requests("INVITE") for p in phones}

        def ended(phone, after):
            """The SIP status the phone's call ended with, once more than
            `after` of its calls have ended."""
            phone.wait_disconnected(after=after)
            return int(re.findall(r"is DISCONNECTED \[reason=(\d+) ", phone.log_text())[-1])

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
            start_phones(everyone + symbols)
            wait_registrations({p: 200 for p in everyone + symbols})

        with subtest("an extension rings for its ring time, then its no-answer destination takes the call, here a voice menu"):
            mark = len(sip_messages(pbx))
            before = invites([desk])
            boss.call("201")
            desk.wait_request("INVITE", after=before["201"])
            invite = desk.received("INVITE")[-1]
            assert f"From: {quoted(NAMES['203'])} <sip:203@" in invite, invite
            wait_hears(boss, [PROMPT])
            rang = wait_sent(mark, "INVITE sip:201@", "10.2.0.21:5060")[0]
            cancel = wait_sent(mark, "CANCEL sip:201@", "10.2.0.21:5060")[0]
            # Dial counts the ring time from before the INVITE leaves, and the
            # CANCEL leaves after it, each a few ms away on an idle machine
            assert 2.7 < cancel["time"] - rang["time"] < 3.3, f"201 rang for {cancel['time'] - rang['time']:.2f} s"
            hang_up(boss)

        with subtest("an extension that is not registered goes to its no-answer destination at once, here another extension"):
            start = time.time()
            sales.call("205")
            wait_bridged(pbx, "202", "203")
            # not after the 20 s ring time
            assert time.time() - start < 8, f"took {time.time() - start:.0f} s"
            hang_up(sales)

        with subtest("a phone in a call rings again with call waiting, then the second call goes to the no-answer destination"):
            sales.call("203")
            wait_bridged(pbx, "202", "203")
            before = invites([sales])
            cancels = sales.requests("CANCEL")
            desk.call("202")
            sales.wait_request("INVITE", after=before["202"])
            channel = wait_channel(pbx, "201", app="VoiceMail", timeout=30)
            assert channel["data"] == "202@default,u", channel
            sales.wait_request("CANCEL", after=cancels)
            wait_bridged(pbx, "202", "203")
            hang_up(desk, sales)

        with subtest("a phone in a call without call waiting answers busy, and the busy destination takes the call"):
            desk.call("203")
            wait_bridged(pbx, "201", "203")
            sales.call("201")
            channel = wait_channel(pbx, "202", app="VoiceMail", timeout=30)
            assert channel["data"] == "201@default,b", channel
            hang_up(desk, sales)

        with subtest("an extension without a mailbox hangs up on callers it does not answer, busy or not"):
            mark = len(sip_messages(pbx))
            done = sales.disconnects()
            confirmed = sales.confirmed()
            sales.call("204")
            assert ended(sales, done) >= 400
            assert sales.confirmed() == confirmed, "the call was answered"
            rang = wait_sent(mark, "INVITE sip:204@", "10.2.0.21:5063")[0]
            cancel = wait_sent(mark, "CANCEL sip:204@", "10.2.0.21:5063")[0]
            assert 1.7 < cancel["time"] - rang["time"] < 2.3, f"204 rang for {cancel['time'] - rang['time']:.2f} s"
            warehouse.call("203")
            wait_bridged(pbx, "204", "203")
            done = sales.disconnects()
            sales.call("204")
            assert ended(sales, done) == 486
            hang_up(warehouse)

        with subtest("each number a trunk sends reaches its destination, written with a + too"):
            for account, number, phone in [("5551000", "5551000", sales), ("5551000", "+15551001", desk)]:
                before = invites([phone])
                asterisk(provider, f"channel originate PJSIP/{number}@{account} extension s@feed")
                phone.wait_request("INVITE", after=before[phone.name])
                hang_up()
            # through the second trunk, which the line parameter tells apart
            asterisk(provider, "channel originate PJSIP/5552000@5552000 extension s@feed")
            channel = wait_channel(pbx, "second", app="VoiceMail", timeout=30)
            assert channel["data"] == "200@default,u", channel
            hang_up()

        with subtest("a number without a route on the trunk it arrives on is refused, and nothing rings"):
            # an unknown number, and the first trunk's number on the second
            for account, number in [("5551000", "5559876"), ("5552000", "5551000")]:
                mark = len(sip_messages(pbx))
                before = invites(everyone)
                asterisk(provider, f"channel originate PJSIP/{number}@{account} extension s@feed")
                refused = wait_sent(mark, "SIP/2.0 404 ", "10.2.0.5:")[0]
                assert f"<sip:{number}@" in header(refused, "To"), refused["text"]
                wait_idle(pbx)
                assert invites(everyone) == before, "a phone rang"

        with subtest("the provider gets a number outside without the prefix #, and the office number"):
            mark = len(sip_messages(pbx))
            boss.call("#5559999")
            out = wait_sent(mark, "INVITE sip:5559999@10.2.0.5", "10.2.0.5:")[0]
            assert "<sip:5551000@" in header(out, "From"), out["text"]
            hang_up(boss)

        with subtest("a number too short for the pattern is refused as incomplete"):
            mark = len(sip_messages(pbx))
            done = boss.disconnects()
            boss.call("#5")
            assert ended(boss, done) == 484
            assert sent(mark, "INVITE", "10.2.0.5:") == [], "the provider was called"

        def request_uris(mark, source):
            """Request-URIs of the INVITEs `source` sent the pbx after the
            first `mark` messages of its capture."""
            return {m["text"].split(" ", 2)[1] for m in sip_messages(pbx)[mark:] if m["source"] == source and m["text"].startswith("INVITE ")}

        def wait_in(endpoint, context, app):
            """Waits until a call of `endpoint` runs `app` in `context`."""
            channel = wait_channel(pbx, endpoint, app=app, timeout=30)
            assert channel["context"] == context, channel

        def call_at_once(calls):
            """Each (phone, number) calls at the same time."""
            cli_parallel([(phone, f"call new {phone.uri(number)}") for phone, number in calls])

        with subtest("phones registered as #1 and *2 ring when their numbers come as %23 or #, and as * or %2A"):
            mark = len(sip_messages(pbx))
            before = invites(symbols)
            call_at_once([(boss, "#1"), (desk, "*2")])
            for phone in symbols:
                phone.wait_request("INVITE", after=before[phone.name])
            hang_up(boss, desk)
            # pjsua sends # as %23 and * as it is
            assert request_uris(mark, "10.2.0.21:5062") == {"sip:%231@10.2.0.10"}, request_uris(mark, "10.2.0.21:5062")
            assert request_uris(mark, "10.2.0.21:5060") == {"sip:*2@10.2.0.10"}, request_uris(mark, "10.2.0.21:5060")
            # SIPp calls as 203, and writes the numbers as given
            for phone, number in [(hash_phone, "#1"), (star_phone, "%2A2")]:
                before = phone.requests("INVITE")
                sipp(phones, "ring", "10.2.0.10", "-s", number, "-key", "caller", "203", "-au", "203", "-ap", "pw-203", "-i", "10.2.0.21", "-p", "5080")
                phone.wait_request("INVITE", after=before)
                wait_idle(pbx)
            assert request_uris(mark, "10.2.0.21:5080") == {"sip:#1@10.2.0.10:5060", "sip:%2A2@10.2.0.10:5060"}, request_uris(mark, "10.2.0.21:5080")

        with subtest("a ring group, queue, page, conference, the voicemail menu, a voice menu's # key, a close-early number and an inbound number with * and # reach their objects"):
            # these ring the same phones, so one after the other
            for number, context, app, ringing in [
                ("6*1", "pbx-ringgroup-symbols", "Dial", symbols),
                ("6#2", "pbx-queue-symbols", "Queue", [star_phone]),
                # Page() puts the caller into a conference
                ("65#", "pbx-paging-symbols", "ConfBridge", symbols),
            ]:
                before = invites(ringing)
                boss.call(number)
                wait_in("203", context, app)
                for phone in ringing:
                    phone.wait_request("INVITE", after=before[phone.name])
                hang_up(boss)
            for phone in symbols:
                invite = phone.received("INVITE")[-1]
                assert "Call-Info: <sip:pbx>;answer-after=0" in invite, invite
            before = hash_phone.requests("INVITE")
            done = warehouse.disconnects()
            call_at_once([(boss, "*63"), (desk, "*97"), (sales, "#64"), (warehouse, "*28#")])
            wait_in("203", "pbx-conference-symbols", "ConfBridge")
            wait_in("201", "pbx-internal", "VoiceMailMain")
            wait_in("202", "pbx-ivr-menu", "BackGround")
            sales.dtmf("#")
            hash_phone.wait_request("INVITE", after=before)
            # the toggle answers, says it closed and hangs up
            warehouse.wait_disconnected(after=done)
            hint = asterisk(pbx, "core show hint *28#")
            assert "State:InUse" in hint, hint
            hang_up(boss, desk, sales)
            before = hash_phone.requests("INVITE")
            asterisk(provider, "channel originate PJSIP/*5551002#@5551000 extension s@feed")
            hash_phone.wait_request("INVITE", after=before)
            hang_up()

        def emergency(caller, dialled, number):
            """Places an emergency call, and returns the seconds from the
            phone's first INVITE to the pbx's first INVITE to the provider."""
            mark = len(sip_messages(pbx))
            caller.call(dialled)
            out = wait_sent(mark, f"INVITE sip:{number}@10.2.0.5", "10.2.0.5:")[0]
            assert "<sip:5551000@" in header(out, "From"), out["text"]
            # the phone sends # as %23
            request = dialled.replace("#", "%23")
            dialling = next(
                m for m in sip_messages(pbx)[mark:]
                if m["source"] == f"10.2.0.21:{caller.sip_port}" and m["text"].startswith(f"INVITE sip:{request}@")
            )
            return out["time"] - dialling["time"]

        with subtest("each emergency number, with and without the prefix, leaves within a second from every extension, and notify rings the others"):
            for caller, dialled, number in [(desk, "911", "911"), (sales, "#911", "911")]:
                (other,) = [p for p in (desk, sales) if p is not caller]
                before = invites([other])
                delay = emergency(caller, dialled, number)
                assert delay < 1, f"{caller.name} dialled {dialled}: the call left after {delay:.2f} s"
                other.wait_request("INVITE", after=before[other.name])
                invite = other.received("INVITE")[-1]
                assert f"From: {quoted(NAMES[caller.name])} <sip:{caller.name}@" in invite, invite
                hang_up(desk, sales)

        with subtest("a second emergency call during the first leaves within a second too, while a notified phone is busy"):
            before = invites([desk, sales])
            first = emergency(boss, "112", "112")
            for p in (desk, sales):
                p.wait_request("INVITE", after=before[p.name])
            # 201 rings for the first call, so it answers the second one busy
            second = emergency(warehouse, "#112", "112")
            assert first < 1 and second < 1, f"the calls left after {first:.2f} s and {second:.2f} s"
            wait_bridged(pbx, "203", "provider")
            wait_bridged(pbx, "204", "provider")
            hang_up(boss, warehouse, desk, sales)

        with subtest("with the provider unreachable, an emergency caller learns it once the trunk's INVITE times out"):
            provider.block()
            mark = len(sip_messages(pbx))
            done = boss.disconnects()
            boss.call("911")
            status = ended(boss, done)
            out = wait_sent(mark, "INVITE sip:911@10.2.0.5", "10.2.0.5:")[0]
            final = wait_sent(mark, f"SIP/2.0 {status} ", f"10.2.0.21:{boss.sip_port}")[-1]
            # pjsip gives up after timer B, 64 times T1 of 0.5 s
            assert status >= 400 and final["time"] - out["time"] < 33, f"{status} after {final['time'] - out['time']:.1f} s"
            hang_up(desk, sales)
      '';
  }
