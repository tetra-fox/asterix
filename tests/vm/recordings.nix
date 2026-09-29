# Recordings on a small filesystem that fills up mid-call: a call recorded
# with MixMonitor and a recorded conference go on, the phones hearing each
# other, once no more audio fits; each recording holds what the call carried
# until then, and the journal says why it stopped.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = [
    "901"
    "902"
    "903"
  ];

  # room for about 3 s of the 8 kHz 16 bit audio a .wav recording holds
  monitorBytes = 48 * 1024;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-recordings";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        # where MixMonitor and ConfBridge write recordings
        virtualisation.fileSystems."/var/lib/asterisk/spool/monitor" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [
            "size=${toString monitorBytes}"
            "mode=0750"
            "uid=${toString config.ids.uids.asterisk}"
            "gid=${toString config.ids.gids.asterisk}"
          ];
        };

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
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          # quiet users enter the room at once, without a prompt that they are
          # alone, so the recording holds all of them before the disk fills up
          confbridge = {
            bridges.recorded.recordConference = true;
            users.quiet.quiet = true;
          };

          dialplan.contexts.office.extensions = {
            "700" = [
              "MixMonitor(call.wav)"
              "Dial(PJSIP/902,20)"
              "Hangup()"
            ];
            "800" = [
              "Answer()"
              "ConfBridge(800,recorded,quiet)"
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

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        MONITOR = "/var/lib/asterisk/spool/monitor"
        phone = {
            ext: Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(${builtins.toJSON extensions})
        }

        def wav(path):
            """The data size the header of the WAV file at `path` gives, and the
            samples the file holds"""
            raw = base64.b64decode(pbx.succeed(f"base64 -w0 {path}"))
            assert raw[:4] == b"RIFF" and raw[36:40] == b"data", raw[:44]
            return int.from_bytes(raw[40:44], "little"), numpy.frombuffer(raw[44:], dtype="<i2").astype(float)

        def fills_up(cursor, talkers):
            """Wait until Asterisk logs, with the call's id, that it can write
            no more, then until the call has gone on for 3 s, in which none of
            `talkers` hears a gap, and each hears the others."""
            wait_journal(pbx, cursor, r"\[C-[0-9]+\]: format_wav\.c:[0-9]+ wav_write: Bad write \([0-9]+\): No space left on device")
            marks = {p.name: recorded(p) for p in talkers}
            for p in talkers:
                wait_recorded(p, marks[p.name], 3)
                assert all(heard(p, marks[p.name])), heard(p, marks[p.name])
                wait_hears(p, [q.tone for q in talkers if q is not p])

        def holds(path, tones):
            """The recording at `path` counts in its header all the audio it
            holds: about as much as fits, the last second of it `tones`."""
            size, samples = wav(path)
            assert size == len(samples) * 2, (size, len(samples))
            windows = tones_in(samples, 8000)
            # the last 100 ms may end where the disk filled up. A window has weaker
            # peaks where MixMonitor took one direction alone, the other's frame
            # being late (main/audiohook.c audiohook_read_frame_both).
            assert len(windows) >= 25 and all(same(w[: len(tones)], tones) for w in windows[-11:-1]), windows

        with subtest("phones register"):
            start_phones(list(phone.values()))
            wait_contacts(pbx, len(phone))

        with subtest("a call recorded with MixMonitor goes on once the disk is full, and its recording holds both phones until then"):
            caller, callee = phone["901"], phone["902"]
            cursor = journal_cursor(pbx)
            caller.call("700")
            wait_bridged(pbx, "901", "902")
            fills_up(cursor, [caller, callee])
            caller.hangup()
            wait_idle(pbx)
            holds(f"{MONITOR}/call.wav", [caller.tone, callee.tone])

        with subtest("a recorded conference goes on once the disk is full, and its recording holds the three phones until then"):
            pbx.succeed(f"rm {MONITOR}/call.wav")
            cursor = journal_cursor(pbx)
            cli_parallel([(p, f"call new {p.uri('800')}") for p in phone.values()])
            fills_up(cursor, list(phone.values()))
            cli_parallel([(p, "call hangup_all") for p in phone.values()])
            wait_idle(pbx)
            recording = pbx.succeed(f"ls {MONITOR}/confbridge-800-*.wav").strip()
            holds(recording, [p.tone for p in phone.values()])
      '';
  }
