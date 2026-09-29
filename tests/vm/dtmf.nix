# DTMF in every dtmfMode, each key once and in order: from a phone in each
# mode into a voice menu, and by SIP INFO and inband into a voicemail PIN, a
# conference menu and a transfer feature code with the number after it; from
# phone to phone, both ways where both can send, including from a G.711 phone
# to a G.722 one and back; and over a trunk in each mode to a second Asterisk,
# into the confirmation of a ring group's outside member and both ways once
# the call is up, where auto falls back to inband and auto_info to SIP INFO
# for an Asterisk that offers no RFC 4733. The inband phone allows ulaw and
# alaw only, as the evaluation warning about it asks; one with the default
# codecs gets a g722 call, and no key of it reaches the menu. Phones send RFC
# 4733 and SIP INFO with pjsua's commands and inband keys as a WAV file of
# tones, and the keys a phone gets are read from its log, or from its
# recording when they come as tones.
#
#   pbx       10.3.0.10
#   provider  10.3.0.5, the far end of the trunks: it answers, presses 1 to
#             take the call, reads keys until # and sends keys back
#   phones    10.3.0.21
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # extension -> dtmfMode of its endpoint; 307 keeps the default codecs
  modes = {
    "301" = "rfc4733";
    "302" = "info";
    "303" = "inband";
    "304" = "auto";
    "305" = "auto_info";
    "306" = "rfc4733";
    "307" = "inband";
  };

  # trunk -> its dtmfMode, the provider's for its account, and the number of
  # the ring group whose outside member it calls. The provider offers no RFC
  # 4733 in inband and info mode, so auto and auto_info fall back.
  trunks = {
    t4733 = {
      pbx = "rfc4733";
      provider = "rfc4733";
      group = "600";
    };
    tinfo = {
      pbx = "info";
      provider = "info";
      group = "610";
    };
    tinband = {
      pbx = "inband";
      provider = "inband";
      group = "620";
    };
    tauto = {
      pbx = "auto";
      provider = "inband";
      group = "630";
    };
    tautoinfo = {
      pbx = "auto_info";
      provider = "info";
      group = "640";
    };
  };

  # what phones send, every key and two equal ones in a row, and what the
  # provider sends back
  keys = "01234456789*#";
  back = "#*9876543210";
  pin = number: "4${number}";

  # the keys phones of extension 303 press as tones, from the start of a call:
  # seconds of silence and keys (tests/vm/dtmf-tones.py)
  keypads = {
    "keys.wav" = [1.5 keys];
    "pin.wav" = [2.5 "${pin "303"}#"];
    "conference.wav" = [1.5 "*1" 5.0 "*1"];
    "transfer.wav" = [1.5 "#1" 2.0 "304"];
  };
  keypadFiles =
    pkgs.runCommand "test-dtmf-keypads" {
      nativeBuildInputs = [(pkgs.python3.withPackages (p: [p.numpy]))];
      keypads = builtins.toJSON keypads;
    } ''
      mkdir $out
      cp ${./tones.py} tones.py
      PYTHONPATH=. python3 ${./dtmf-tones.py} "$out" "$keypads"
    '';

  # the menu's prompt is a tone above those of the phones (tests/vm/phone.py)
  prompts = pkgs.runCommand "test-prompts" {nativeBuildInputs = [pkgs.sox];} ''
    mkdir -p $out/sounds/test
    sox -n -r 8000 -b 16 -c 1 -e signed-integer -t raw $out/sounds/test/keys.sln synth 0.5 sine 2500 vol 0.5
  '';

  menuKeys = [
    "0"
    "1"
    "2"
    "3"
    "4"
    "5"
    "6"
    "7"
    "8"
    "9"
    "*"
  ];

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
    name = "asterisk-dtmf";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed =
              lib.concatMapAttrs (number: _: {
                "sip-${number}" = "pw-${number}";
                "vm-${number}" = pin number;
              })
              modes
              // lib.mapAttrs' (trunk: _: lib.nameValuePair "trunk-${trunk}" "pw-${trunk}") trunks;
          })
          (onlyAddress "10.3.0.10")
        ];

        pbx = {
          enable = true;
          extensions =
            lib.mapAttrs (number: _: {
              password = secret "sip-${number}";
              voicemail.pin = secret "vm-${number}";
            })
            modes;
          voicemailMenu = "*97";
          ivrs.keys = {
            number = "700";
            prompt.sound = "test/keys";
            options =
              lib.genAttrs menuKeys (key: {
                context = {
                  context = "landed-keys";
                  extension = key;
                };
              })
              // {"#".hangup = true;};
          };
          ringGroups =
            lib.mapAttrs (trunk: t: {
              number = t.group;
              external = ["5559000"];
              inherit trunk;
              ringTime = 30;
            })
            trunks;
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
          sounds.packages = [prompts];

          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.mapAttrs (_: dtmfMode: {inherit dtmfMode;}) modes)
              {
                "301".allow = ["ulaw"];
                "302".allow = ["g722"];
                "303".allow = [
                  "ulaw"
                  "alaw"
                ];
              }
            ];
            trunks =
              lib.mapAttrs (trunk: t: {
                host = "10.3.0.5";
                username = trunk;
                password = secret "trunk-${trunk}";
                register = false;
                # only the pbx places calls on them
                matchProviderHost = false;
                # Asterisk skips a contact whose last qualify failed, and the
                # provider may start after the pbx first qualifies it
                qualifyFrequency = 5;
                dtmfMode = t.pbx;
                allow = ["ulaw"];
              })
              trunks;
          };

          confbridge = {
            # no announcement, which would drop the keys pressed during it
            users.quiet.quiet = true;
            menus.keys."*1" = "toggle_mute";
          };
          features.featureMap.blindxfer = "#1";

          dialplan.contexts = {
            # notes each key under the caller's number and goes back to the menu
            landed-keys.extensions = lib.genAttrs menuKeys (key: [
              "Set(DB(test/keys-\${CALLERID(num)})=\${DB(test/keys-\${CALLERID(num)})}${key})"
              "Goto(pbx-ivr-keys,s,1)"
            ]);
            pbx-internal.extensions = {
              "800" = [
                "Answer()"
                "ConfBridge(800,,quiet,keys)"
                "Hangup()"
              ];
              # 8 and an extension call it, and the caller may transfer the call
              "_8XXX" = [
                "Dial(PJSIP/\${EXTEN:1},20,T)"
                "Hangup()"
              ];
            };
          };
        };
      };

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.mapAttrs' (trunk: _: lib.nameValuePair "trunk-${trunk}" "pw-${trunk}") trunks;
          })
          (onlyAddress "10.3.0.5")
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options = {
            verbose = 3;
            # silence between and after the tones of SendDTMF, as a phone's
            # microphone would send, without which the pbx cannot tell where
            # one key ends and an equal one starts
            transmit_silence = true;
          };
          pjsip = {
            transports.udp = {};
            # one account per trunk, which the pbx's From user names
            endpoints =
              lib.mapAttrs (trunk: t: {
                context = "carrier";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/trunk-${trunk}";
                dtmfMode = t.provider;
                allow = ["ulaw"];
              })
              trunks;
          };
          dialplan.contexts.carrier.extensions."_X." = [
            "Answer()"
            "Wait(1)"
            "SendDTMF(1)"
            "Read(GOT,,20,,1,20)"
            "Set(DB(got/\${CHANNEL(endpoint)})=\${GOT})"
            "Wait(1)"
            "SendDTMF(${back})"
            "Wait(20)"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddress "10.3.0.21")
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

        MODES = ${builtins.toJSON modes}
        TRUNKS = ${builtins.toJSON (lib.mapAttrs (_: t: t.group) trunks)}
        KEYPADS = "${keypadFiles}"
        KEYS = "${keys}"
        # KEYS without two equal keys in a row, for where the pbx plays the keys
        # as tones. TODO: send KEYS there too once Asterisk keeps the pause
        # between two equal keys it relays from RFC 4733 or SIP INFO as tones:
        # it sends no audio in that pause and closes one under 80 ms in the RTP
        # timestamps (res/res_rtp_asterisk.c:98, 5194-5209), so the far end
        # hears one key
        DISTINCT = "".join(key for key, _ in itertools.groupby(KEYS))
        BACK = "${back}"

        phone = {
            number: Phone(phones, number, number, f"pw-{number}", "10.3.0.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, number in enumerate(MODES)
        }

        def keypad(name, wav, sip_port, user="303"):
            """A phone of the inband extension `user` that presses the keys of
            `wav` as tones from the start of the call it places."""
            pad = Phone(
                phones, name, user, f"pw-{user}", "10.3.0.10", sip_port=sip_port, cli_port=sip_port - 2700,
                tone=f"{KEYPADS}/{wav}", register=False,
            )
            pad.start()
            return pad

        def method(p):
            """How the phone gets keys: pjsua offers RFC 4733, so auto and
            auto_info use it."""
            return "SIP INFO" if MODES[p.user] == "info" else "RFC2833"

        def send(p, keys):
            """The CLI command that sends `keys` in the phone's mode."""
            return (p, f"call {'d_info' if MODES[p.user] == 'info' else 'd_2833'} {keys}")

        def received(p):
            """How many keys `p` got in its mode so far, a mark for wait_dtmf."""
            return len(p.dtmf_received(method(p)))

        def wait_tones(p, mark, keys, timeout=30):
            """Wait until `p` heard `keys` as tones after `mark`, and nothing else."""
            retry(lambda _: len(keys_heard(p, mark)) >= len(keys), timeout_seconds=timeout)
            got = keys_heard(p, mark)
            assert got == keys, f"{p.name} heard {got}, not {keys}"

        def db(machine, family, key):
            match = re.search(r"^Value: (.*)$", asterisk(machine, f"database get {family} {key}"), re.M)
            return match.group(1) if match else None

        def members():
            """Endpoint -> flags of the users of conference 800, m for muted."""
            found = {}
            for line in asterisk(pbx, "confbridge list 800").splitlines():
                if line.startswith("PJSIP/"):
                    found[endpoint_of(line[:30].strip())] = line[31:37].strip()
            return found

        def wait_muted(number, muted):
            retry(lambda _: number in members() and ("m" in members()[number]) == muted, timeout_seconds=30)

        with subtest("phones register and the trunks' far end answers"):
            start_phones(list(phone.values()))
            wait_registrations({p: 200 for p in phone.values()})
            for trunk in TRUNKS:
                pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +{trunk}/sip:.* Avail'", timeout=60)

        with subtest("a voice menu gets every key once and in order from a phone in each mode, and no key sent as tones in a g722 call"):
            pad = keypad("303-menu", "keys.wav", 5090)
            # 307 allows the default codecs, and Asterisk picks g722
            lost = keypad("307-menu", "keys.wav", 5096, user="307")
            callers = [phone[number] for number in ("301", "302", "304", "305")] + [pad]
            for p in callers + [lost]:
                asterisk(pbx, f"database del test keys-{p.user}")
            ended = {p.name: p.disconnects() for p in callers}
            cursor = journal_cursor(pbx)
            cli_parallel([(p, f"call new {p.uri('700')}") for p in callers + [lost]])
            # the menu reads keys from the start of its prompt, which lasts
            # 0.5 s, then while it waits
            for p in callers[:-1]:
                wait_journal(pbx, cursor, rf"<PJSIP/{p.user}-[0-9a-f]+> Playing 'test/keys\.")
            cli_parallel([send(p, KEYS) for p in callers[:-1]])
            # the menu notes every key but #, which hangs up
            for p in callers:
                p.wait_disconnected(after=ended[p.name])
                assert db(pbx, "test", f"keys-{p.user}") == KEYS[:-1], f"{p.name}: {db(pbx, 'test', f'keys-{p.user}')}"
            # the menu plays its prompt again after 5 s without a key, by when
            # 307's keypad sent all of its keys, and Asterisk read none of them
            wait_journal(pbx, cursor, r"<PJSIP/307-[0-9a-f]+> Playing 'test/keys\.", count=2)
            wait_journal(pbx, cursor, r"\(g722 not supported\)")
            assert db(pbx, "test", "keys-307") is None, db(pbx, "test", "keys-307")
            lost.hangup()
            for p in (pad, lost):
                p.stop()
            wait_idle(pbx)

        with subtest("a voicemail PIN arrives by SIP INFO and inband"):
            info = phone["302"]
            pad = keypad("303-pin", "pin.wav", 5091)
            cursor = journal_cursor(pbx)
            cli_parallel([(p, f"call new {p.uri('*97')}") for p in (info, pad)])
            wait_journal(pbx, cursor, r"<PJSIP/302-[0-9a-f]+> Playing 'vm-password\.")
            info.dtmf_info("${pin "302"}#")
            for number in ("302", "303"):
                wait_journal(pbx, cursor, rf"<PJSIP/{number}-[0-9a-f]+> Playing 'vm-youhave\.")
            assert "vm-incorrect" not in journal_since(pbx, cursor)
            cli_parallel([(p, "call hangup_all") for p in (info, pad)])
            pad.stop()
            wait_idle(pbx)

        with subtest("a conference menu toggles mute on its two keys by SIP INFO and inband, and again"):
            info = phone["302"]
            # *1, and *1 again 5 s later
            pad = keypad("303-conference", "conference.wav", 5092)
            cli_parallel([(p, f"call new {p.uri('800')}") for p in (info, pad)])
            wait_muted("303", True)
            wait_muted("302", False)
            info.dtmf_info("*1")
            wait_muted("302", True)
            wait_muted("303", False)
            info.dtmf_info("*1")
            wait_muted("302", False)
            cli_parallel([(p, "call hangup_all") for p in (info, pad)])
            pad.stop()
            wait_idle(pbx)

        with subtest("a transfer feature code and the number after it arrive by SIP INFO and inband"):
            info = phone["302"]
            # calls 305 and transfers it to 304
            pad = keypad("303-transfer", "transfer.wav", 5093)
            cursor = journal_cursor(pbx)
            cli_parallel([(info, f"call new {info.uri('8306')}"), (pad, f"call new {pad.uri('8305')}")])
            wait_bridged(pbx, "302", "306")
            info.dtmf_info("#1")
            wait_journal(pbx, cursor, r"<PJSIP/302-[0-9a-f]+> Playing 'pbx-transfer\.")
            info.dtmf_info("301")
            wait_bridged(pbx, "306", "301")
            wait_bridged(pbx, "305", "304")
            cli_parallel([(phone[number], "call hangup_all") for number in ("301", "304")])
            pad.stop()
            wait_idle(pbx)

        with subtest("keys reach the phone at the other end once and in order, in its mode, between a G.711 and a G.722 phone"):
            g711, g722, auto, inband, other = phone["301"], phone["302"], phone["304"], phone["303"], phone["306"]
            pad = keypad("303-call", "keys.wav", 5094)
            before = {p.name: received(p) for p in (g711, g722, other)}
            mark = recorded(inband)
            cli_parallel([(g711, f"call new {g711.uri('302')}"), (auto, f"call new {auto.uri('303')}"), (pad, f"call new {pad.uri('306')}")])
            for pair in (("301", "302"), ("304", "303"), ("303", "306")):
                wait_bridged(pbx, *pair)
            stats = channel_stats(pbx)
            assert {s["codec"] for name, s in stats.items() if name.startswith(("301-", "302-"))} == {"ulaw", "g722"}, stats
            # the pbx plays the keys to the inband phone as tones
            cli_parallel([send(g711, KEYS), send(auto, DISTINCT)])
            g722.wait_dtmf(KEYS, after=before["302"], method=method(g722))
            wait_tones(inband, mark, DISTINCT)
            other.wait_dtmf(KEYS, after=before["306"], method=method(other))
            g722.dtmf_info(KEYS)
            g711.wait_dtmf(KEYS, after=before["301"], method=method(g711))
            cli_parallel([(p, "call hangup_all") for p in (g711, auto, pad)])
            pad.stop()
            wait_idle(pbx)

        with subtest("keys between an auto and an auto_info phone arrive once and in order both ways"):
            auto, autoinfo = phone["304"], phone["305"]
            before = {p.name: received(p) for p in (auto, autoinfo)}
            autoinfo.call("304")
            wait_bridged(pbx, "305", "304")
            autoinfo.dtmf(KEYS)
            auto.wait_dtmf(KEYS, after=before["304"], method=method(auto))
            auto.dtmf(KEYS)
            autoinfo.wait_dtmf(KEYS, after=before["305"], method=method(autoinfo))
            autoinfo.hangup()
            wait_idle(pbx)

        with subtest("over a trunk in each mode the far end confirms with 1, gets every key once and in order, and sends keys back"):
            asterisk(provider, "database deltree got")
            pad = keypad("303-trunk", "keys.wav", 5095)
            # phone, trunk and what it sends; the pbx plays the keys to tinband
            # and tauto as tones
            plan = [
                (phone["301"], "tinfo", KEYS),
                (phone["302"], "t4733", KEYS),
                (phone["304"], "tinband", DISTINCT),
                (phone["305"], "tauto", DISTINCT),
                (pad, "tautoinfo", KEYS),
            ]
            before = {p.name: received(p) for p, _, _ in plan if p is not pad}
            cli_parallel([(p, f"call new {p.uri(TRUNKS[trunk])}") for p, trunk, _ in plan])
            for p, trunk, _ in plan:
                wait_bridged(pbx, p.user, f"5559000@pbx-ringgroup-{trunk}", timeout=60)
            cli_parallel([send(p, keys) for p, _, keys in plan if p is not pad])
            for p, trunk, keys in plan:
                provider.wait_until_succeeds(f"asterisk -rx 'database get got {trunk}' | grep -q '^Value: '", timeout=60)
                assert db(provider, "got", trunk) == keys[:-1], f"{trunk}: {db(provider, 'got', trunk)}"
                # the keys back come to the keypad as tones
                if p is pad:
                    wait_tones(p, 0, BACK)
                else:
                    p.wait_dtmf(BACK, after=before[p.name], method=method(p))
            cli_parallel([(p, "call hangup_all") for p, _, _ in plan])
            pad.stop()
            wait_idle(pbx)
      '';
  }
