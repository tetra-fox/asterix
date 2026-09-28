# 256 phones, each with its own password from a secret: they all register,
# 128 calls run at the same time with audio both ways on all 256 legs, a
# rotated password is applied with a reload while the calls go on, all 256
# phones meet in one conference, and a restart keeps every registration
#
#   VLAN 1  pbx, phones1 to phones4 with 64 phones each (1000-1063, ...)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = map toString (lib.range 1000 1255);

  phoneMachine = {
    imports = [
      ./common.nix
      ./phone.nix
    ];
    virtualisation = {
      memorySize = 2048;
      cores = 4;
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-scale";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];
        virtualisation = {
          memorySize = 2048;
          cores = 4;
        };

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {};
            endpoints = lib.genAttrs extensions (extension: {
              context = "office";
              # the phones' media is cheapest to encode in ulaw
              allow = ["ulaw"];
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          # no join and leave sounds for 256 callers
          confbridge.users.quiet.quiet = true;

          dialplan.contexts.office.extensions = {
            "_1XXX" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "Hangup()"
            ];
            "8000" = [
              "Answer()"
              "ConfBridge(8000,,quiet)"
              "Hangup()"
            ];
          };
        };
      };

      phones1 = phoneMachine;
      phones2 = phoneMachine;
      phones3 = phoneMachine;
      phones4 = phoneMachine;
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        extensions = ${builtins.toJSON extensions}
        machines = [phones1, phones2, phones3, phones4]
        # 64 phones on each machine
        phone = {
            ext: Phone(machines[i // 64], ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i % 64, cli_port=2300 + i % 64)
            for i, ext in enumerate(extensions)
        }
        everyone = list(phone.values())
        # the phones on phones1 and phones2 call those on phones3 and phones4
        pairs = list(zip(extensions[:128], extensions[128:]))

        def timed(what, action):
            start = time.time()
            result = action()
            print(f"{what}: {time.time() - start:.1f} s")
            return result

        with subtest("256 phones register"):
            start_phones(everyone)
            timed("256 registrations", lambda: wait_contacts(pbx, 256, timeout=300))

        with subtest("128 calls at once, with audio both ways on all 256 legs"):
            cli_parallel([(phone[a], f"call new {phone[a].uri(b)}") for a, b in pairs])
            pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -qx '128 active calls'", timeout=180)
            timed("audio on 256 legs", lambda: wait_for_media_both_ways(pbx, everyone, timeout=300))
            found = sorted(sorted(members) for members in bridges(pbx).values())
            assert found == sorted(sorted(pair) for pair in pairs), found

        with subtest("a rotated password is applied with a reload while the calls go on"):
            cursor = journal_cursor(pbx)
            calls = channel_stats(pbx)
            pbx.succeed("printf rotated-1000 > /run/test-secrets/sip-1000")
            timed("reload", lambda: pbx.succeed("systemctl reload asterisk.service"))
            assert "asterisk-config: module reload res_pjsip.so" in journal_since(pbx, cursor)
            assert "rotated-1000" in asterisk(pbx, "pjsip show auth 1000")
            wait_calls_continue(pbx, everyone, calls, timeout=120)
            cli_parallel([(phone[a], "call hangup_all") for a, _ in pairs])
            timed("hanging up", lambda: wait_idle(pbx, timeout=300))
            # the phone still has the old password
            pbx.succeed("printf pw-1000 > /run/test-secrets/sip-1000")
            pbx.succeed("systemctl reload asterisk.service")

        with subtest("all 256 phones in one conference"):
            cli_parallel([(p, f"call new {p.uri('8000')}") for p in everyone])
            pbx.wait_until_succeeds("asterisk -rx 'confbridge list' | grep -qE '^8000 +256 '", timeout=300)
            timed("audio for 256 participants", lambda: wait_for_media_both_ways(pbx, everyone, timeout=300))
            cli_parallel([(p, "call hangup_all") for p in everyone])
            wait_idle(pbx, timeout=300)

        with subtest("a restart keeps all 256 registrations"):
            timed("restart", lambda: pbx.succeed("systemctl restart asterisk.service"))
            # from astdb: the phones only register again after 300 s
            wait_contacts(pbx, 256, timeout=60)
      '';
  }
