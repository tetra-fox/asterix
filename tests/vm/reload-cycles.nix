# 600 cycles of asterix's reload path while four calls stay up. In each
# round of ten: a deploy that changes extensions.conf and one back, a reload
# with nothing changed, two reloads at once, a rotated password file, a
# rotated systemd credential, a deploy with an endpoint Asterisk rejects
# (checkConfig off) and one back, a deploy of a file a module rejects as a
# whole, which fails, and a reload while a secret file is missing, which
# fails, and one once it is back. After each cycle the entries and bytes
# under /run/asterisk (the config trees asterix renders) and under the
# unit's credentials directory, Asterisk's descriptors and memory, and the
# unit's state are recorded into cycles.csv in the result. Nothing asterix
# keeps grows from round to round, Asterisk keeps its PID and descriptors,
# and the calls stay up.
#
#   VLAN 1  pbx, traffic (SIPp: phones 101-104 and 3000-3003)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  cycles = 600;
  phones = map toString (lib.range 101 104);
  callees = map toString (lib.range 3000 3003);
  load = import ./load-nodes.nix {inherit lib;};
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-reload-cycles";
    globalTimeout = 2 * 3600;

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: let
        inherit (config.lib.asterisk) credential secret;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (phone: lib.nameValuePair "sip-${phone}" "pw-${phone}") phones);
          })
          load.pbx
        ];
        virtualisation.memorySize = 2048;
        environment.systemPackages = [pkgs.curl];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.genAttrs phones (phone: {
                context = "office";
                allow = ["ulaw"];
                auth.password = secret "/run/test-secrets/sip-${phone}";
              }))
              (lib.genAttrs callees (phone: {
                context = "office";
                allow = ["ulaw"];
                aor = {
                  contacts = ["sip:${phone}@${nodes.traffic.networking.primaryIPAddress}:5080"];
                  qualifyFrequency = 0;
                };
              }))
            ];
          };
          confbridge.users.quiet.quiet = true;
          dialplan.contexts.office.extensions."_30XX" = [
            "Dial(PJSIP/\${EXTEN},20)"
            "Hangup()"
          ];
          http.enable = true;
          ari = {
            enable = true;
            users.app.password = credential "ari-password";
          };
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
            printf ari-0 | systemd-creds encrypt --with-key=host --name=ari-password - /var/lib/test-credentials/ari-password
          '';
        };
        systemd.services.asterisk.serviceConfig.LoadCredentialEncrypted = ["ari-password:/var/lib/test-credentials/ari-password"];

        specialisation = {
          changed.configuration.services.asterisk.dialplan.contexts.office.extensions."199" = [
            "Answer()"
            "Hangup()"
          ];
          # settings Asterisk rejects, which only reach it without the check
          bad-endpoint.configuration.services.asterisk = {
            checkConfig = false;
            pjsip.endpoints."101".settings.direct_mdia = false;
          };
          rejected.configuration.services.asterisk = {
            checkConfig = false;
            confbridge.bridges.reload_check.settings.max_membres = 5;
          };
        };
      };

      traffic = load.sipp;
    };

    testScript = {nodes, ...}:
      builtins.readFile ./phone.py
      + builtins.readFile ./usage.py
      + ''
        PBX = "${nodes.pbx.networking.primaryIPAddress}:5060"
        SIPP = "${nodes.traffic.networking.primaryIPAddress}"
        CYCLES = ${toString cycles}
        phones = ${builtins.toJSON phones}
        callees = ${builtins.toJSON callees}

        start_all()
        pbx.wait_for_unit("asterisk.service")
        traffic.wait_for_unit("multi-user.target")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        # four calls that last the whole test
        traffic.succeed(f"systemd-run --unit=sipp-uas -E PATH sh -c 'exec sipp -sn uas -i {SIPP} -p 5080 -mi {SIPP} -mp 6000 -rtp_echo -nostdin > /dev/null'")
        sipp_injection(traffic, "/tmp/calls.csv", [(phone, f"pw-{phone}", callee) for phone, callee in zip(phones, callees)])
        traffic.succeed(
            f"systemd-run --unit=sipp-calls -E PATH sh -c 'exec sipp {PBX} -sf /etc/sipp/call.xml -inf /tmp/calls.csv -i {SIPP} -p 5090 -mi {SIPP} "
            + "-min_rtp_port 20000 -max_rtp_port 40000 -r 4 -m 4 -d 36000000 -nostdin -trace_stat -stf /tmp/calls.csv.stat -fd 10 > /dev/null'"
        )
        pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -qx '4 active calls'", timeout=60)

        def switch(specialisation=None):
            """Deploy a specialisation, or the base system: switch-to-configuration's status and output."""
            target = f"{base}/specialisation/{specialisation}" if specialisation else base
            return pbx.execute(f"{target}/bin/switch-to-configuration test 2>&1")

        def reload():
            return pbx.execute("systemctl reload asterisk.service 2>&1")

        def rotate_password(cycle):
            pbx.succeed(f"printf pw-104-{cycle:04d} > /run/test-secrets/sip-104")
            status, output = reload()
            assert f"pw-104-{cycle:04d}" in asterisk(pbx, "pjsip show auth 104"), "the rotated password is not in use"
            return status, output

        def rotate_credential(cycle):
            pbx.succeed(f"printf ari-{cycle:04d} | systemd-creds encrypt --with-key=host --name=ari-password - /var/lib/test-credentials/ari-password")
            status, output = reload()
            pbx.succeed(f"curl -sf -u app:ari-{cycle:04d} http://127.0.0.1:8088/ari/applications > /dev/null")
            return status, output

        def missing_secret(_):
            pbx.succeed("mv /run/test-secrets/sip-102 /run/test-secrets/sip-102.away")
            missing = reload()
            pbx.succeed("mv /run/test-secrets/sip-102.away /run/test-secrets/sip-102")
            status, output = reload()
            assert missing[0] != 0, f"a reload with a missing secret file succeeded: {missing[1]}"
            return status, output

        # the action of each cycle in a round, and whether it succeeds
        actions = [
            ("deploy changed", lambda _: switch("changed"), True),
            ("deploy back", lambda _: switch(), True),
            ("reload, nothing changed", lambda _: reload(), True),
            ("two reloads at once", lambda _: pbx.execute("systemctl reload asterisk.service & systemctl reload asterisk.service; wait"), True),
            ("rotated password file", rotate_password, True),
            ("rotated systemd credential", rotate_credential, True),
            ("deploy with a rejected endpoint", lambda _: switch("bad-endpoint"), True),
            ("deploy back", lambda _: switch(), True),
            ("deploy of a rejected file", lambda _: switch("rejected"), False),
            ("reload with a missing secret file, and once it is back", missing_secret, True),
        ]

        STATE_SCRIPT = r"""
        find /run/asterisk -mindepth 1 | wc -l
        du -sb /run/asterisk | cut -f1
        ls -d /run/asterisk/.config.* | wc -l
        find /run/credentials/asterisk.service -mindepth 1 | wc -l
        du -sb /run/credentials/asterisk.service | cut -f1
        systemctl show -P ActiveState asterisk.service
        systemctl show -P NRestarts asterisk.service
        awk '/^VmRSS/ {print $2}' /proc/1/status
        """

        def state():
            keys = ["runtime_entries", "runtime_bytes", "config_trees", "credential_entries", "credential_bytes", "active", "restarts", "systemd_rss_kib"]
            values = pbx.succeed(STATE_SCRIPT).split()
            return {key: (value if key == "active" else int(value)) for key, value in zip(keys, values)}

        samples = []
        output = open(driver.out_dir / "cycles.csv", "w", newline="")
        began = time.time()
        with subtest(f"{CYCLES} cycles of reloads, deploys and rotations"):
            for cycle in range(CYCLES):
                what, action, succeeds = actions[cycle % len(actions)]
                start = time.time()
                status, result = action(cycle)
                seconds = time.time() - start
                assert (status == 0) == succeeds, f"cycle {cycle}, {what}: status {status}\n{result}"
                u = usage(pbx)
                sample = {
                    "cycle": cycle,
                    "action": what,
                    "status": status,
                    "seconds": round(seconds, 1),
                    **state(),
                    "pid": int(u["pid"]),
                    "fds": lasting_descriptors(pbx),
                    "rss_kib": int(u["rss_kib"]),
                    "heap_kib": heap_in_use(pbx) if cycle % 10 == 9 else "",
                    "threads": int(u["threads"]),
                    "taskprocessors": int(u["taskprocessors"]),
                    "calls": int(u["calls"]),
                    "host_load1": round(u["host_load1"], 1),
                }
                if not samples:
                    output.write(",".join(sample) + "\n")
                samples.append(sample)
                output.write(",".join(str(sample[column]) for column in samples[0]) + "\n")
                output.flush()
                print(f"cycle sample: {sample}")
                assert sample["pid"] == int(pid) and sample["active"] == "active", sample
                assert sample["calls"] == 4, sample
        output.close()
        print(f"{CYCLES} cycles in {(time.time() - began) / 60:.1f} min")

        with subtest("nothing asterix keeps grows from round to round, and the calls stay up"):
            ends = [s for s in samples if s["cycle"] % len(actions) == len(actions) - 1]
            for key in ["runtime_entries", "runtime_bytes", "config_trees", "credential_entries", "credential_bytes", "fds", "restarts"]:
                values = [s[key] for s in ends]
                print(f"{key} at the end of each round: {values}")
                assert len(set(values[1:])) == 1, f"{key} changes from round to round: {values}"
            for key in ["rss_kib", "heap_kib", "threads", "taskprocessors", "systemd_rss_kib"]:
                print(f"{key} at the end of each round: {[s[key] for s in ends]}")
            stats = sipp_statistics(traffic, "/tmp/calls.csv.stat")
            assert stats["FailedCall(C)"] == "0", stats
      '';
  }
