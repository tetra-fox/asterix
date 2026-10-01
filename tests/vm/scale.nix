# 256 phones, each with its own password from a secret: they all register,
# 128 calls run at the same time with audio both ways on all 256 legs, a
# flood of 100000 AMI UserEvents from 4 senders during them reaches two
# listening users whole and in order, as did every event of the calls'
# start, and the calls go on, a reload every 10 s for 5 minutes, each
# applying a rotated password, keeps every call and its audio, and once the
# calls end Asterisk has as many descriptors and no more taskprocessors than
# before them (its heap in use and resident memory are printed); all 256
# phones meet in one conference, and a restart keeps every registration
#
#   VLAN 1  pbx, phones1 to phones4 with 64 phones each (1000-1063, ...)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = map toString (lib.range 1000 1255);
  load = import ./load-nodes.nix {inherit lib;};

  phoneMachine = {
    imports = [
      ./common.nix
      ./phone.nix
      load.sizing
    ];
    virtualisation.memorySize = 2048;
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-scale";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./ami.nix
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
          load.pbx
        ];
        virtualisation.memorySize = 2048;
        environment.systemPackages = [pkgs.jq];

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

          # the flood's two listeners and its sender. The phones take all 256
          # credentials systemd gives a service, so they share 1255's secret
          ami = {
            enable = true;
            users = let
              secret = config.lib.asterisk.secret "/run/test-secrets/sip-1255";
            in {
              calls = {
                inherit secret;
                read = [
                  "call"
                  "user"
                ];
              };
              everything = {
                inherit secret;
                read = ["all"];
              };
              flood = {
                inherit secret;
                write = ["user"];
              };
            };
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
      + builtins.readFile ./usage.py
      + builtins.readFile ./ami-events.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        # UserEvents each of the flood's 4 senders sends
        FLOOD = 25000
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

        idle = usage(pbx)
        idle_descriptors = lasting_descriptors(pbx)
        heap = {"idle": heap_in_use(pbx)}

        with subtest("128 calls at once, with audio both ways on all 256 legs, while two AMI users listen"):
            # one for the call and user classes, one for every class
            ami_listen(pbx, "pw-1255", "calls", "everything")
            cli_parallel([(phone[a], f"call new {phone[a].uri(b)}") for a, b in pairs])
            pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -qx '128 active calls'", timeout=180)
            timed("audio on 256 legs", lambda: wait_for_media_both_ways(pbx, everyone, timeout=300))
            found = sorted(sorted(members) for members in bridges(pbx).values())
            assert found == sorted(sorted(pair) for pair in pairs), found

        with subtest("an AMI flood of 100000 UserEvents during the calls reaches both users whole and in order, as did every start of a call, and the calls go on"):
            calls = channel_stats(pbx)
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            before = usage(pbx)
            began = time.time()
            pbx.succeed(
                "pids=; for sender in 0 1 2 3; do "
                + f"ami run flood pw-1255 --times {FLOOD} UserEvent UserEvent=Flood Sender=$sender > /tmp/flood-$sender.out & pids=\"$pids $!\"; "
                + "done; for pid in $pids; do wait $pid || exit 1; done"
            )
            sent = time.time() - began
            ami_done(pbx, "flood", "pw-1255", "calls", "everything")
            print(f"{4 * FLOOD} UserEvents sent in {sent:.1f} s, and both users had them after {time.time() - began:.1f} s")
            for user in ["calls", "everything"]:
                # sender and ActionID of each UserEvent of the flood
                words = pbx.succeed(f"jq -r 'select(.UserEvent == \"Flood\") | .Sender + \" \" + .ActionID' /tmp/ami-{user}.json").split()
                order = {}
                for sender, action in zip(words[::2], words[1::2]):
                    order.setdefault(sender, []).append(int(action))
                for sender in ["0", "1", "2", "3"]:
                    got = order.get(sender, [])
                    wrong = next((i for i, action in enumerate(got) if action != i), None)
                    assert got == list(range(FLOOD)), f"{user} got {len(got)} UserEvents from sender {sender}, the first out of order at {wrong}"
                counts = {}
                for line in pbx.succeed(f"jq -r 'select(.Channel // \"\" | startswith(\"PJSIP/\")) | .Event' /tmp/ami-{user}.json | sort | uniq -c").splitlines():
                    count, event = line.split()
                    counts[event] = int(count)
                started = {event: counts.get(event) for event in ["Newchannel", "DialBegin", "DialEnd", "BridgeEnter"]}
                assert started == {"Newchannel": 256, "DialBegin": 128, "DialEnd": 128, "BridgeEnter": 256}, (user, counts)
            wait_calls_continue(pbx, everyone, calls, timeout=120)
            assert pbx.succeed("systemctl show -P MainPID asterisk.service").strip() == pid
            print(f"before the flood: {before}, after it: {usage(pbx)}")

        with subtest("a reload every 10 s for 5 minutes, each with a rotated password, keeps the calls"):
            heap["calls"] = heap_in_use(pbx)
            calls = channel_stats(pbx)
            began = time.time()
            for i in range(30):
                cursor = journal_cursor(pbx)
                pbx.succeed(f"printf rotated-{i} > /run/test-secrets/sip-1000")
                timed(f"reload {i}", lambda: pbx.succeed("systemctl reload asterisk.service"))
                assert "asterisk-config: module reload res_pjsip.so" in journal_since(pbx, cursor)
                assert f"rotated-{i}" in asterisk(pbx, "pjsip show auth 1000")
                sample = usage(pbx)
                print(f"after reload {i}: {sample}")
                assert sample["channels"] == 256, sample
                time.sleep(max(0, began + 10 * (i + 1) - time.time()))
            calls = wait_calls_continue(pbx, everyone, calls, timeout=120)
            heap["calls, after the reloads"] = heap_in_use(pbx)
            cli_parallel([(phone[a], "call hangup_all") for a, _ in pairs])
            timed("hanging up", lambda: wait_idle(pbx, timeout=300))
            # a call's serializer goes a moment after its channels
            pbx.wait_until_succeeds(
                f"test $(asterisk -rx 'core show taskprocessors' | sed -n 's/^\\([0-9]*\\) taskprocessors$/\\1/p') -le {int(idle['taskprocessors'])}",
                timeout=60,
            )
            heap["idle again"] = heap_in_use(pbx)
            after = usage(pbx)
            print(f"before the calls: {idle}, after them: {after}")
            print(f"heap in use in KiB: {heap}")
            assert after["bridges"] == 0, after
            descriptors = lasting_descriptors(pbx)
            assert descriptors == idle_descriptors, f"{idle_descriptors} descriptors before the calls, {descriptors} after"
            # phone 1000 kept its old password, so its registration lapsed at
            # its first refresh during the rotations; it registers again once
            # the password matches
            pbx.succeed("printf pw-1000 > /run/test-secrets/sip-1000")
            pbx.succeed("systemctl reload asterisk.service")
            phone["1000"].cli("acc reg")
            wait_contacts(pbx, 256, timeout=60)

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
