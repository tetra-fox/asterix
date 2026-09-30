# 45 minutes of mixed traffic from SIPp, to measure what each call leaves
# on disk: 200 phones registering once a minute and answering the pbx's
# qualify, a call every 2 s lasting 30 s with audio both ways, to a phone,
# to Echo() or to a conference, and a call from a carrier every 5 s. The
# pbx logs to two file channels, as Asterisk's sample logger.conf has them,
# and records CDRs and CEL events in SQLite. Every minute the log files,
# master.db with its rows, astdb and Asterisk's journal are measured, with
# its memory, descriptors, threads, channels, bridges and taskprocessors,
# into traffic.csv in the result, and the growth per call and per day is
# printed. No call fails, Asterisk keeps its PID, and once the traffic
# stops it has no channels or bridges left and as many descriptors as
# before it began.
#
#   VLAN 1  pbx, traffic (SIPp: phones 2000-2199 and 3000-3009 on its first
#           address, the carrier on 192.168.1.100)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  minutes = 45;

  # phones that register; the first ten also call
  phones = map toString (lib.range 2000 2199);
  # phones that answer at SIPp's address without registering
  callees = map toString (lib.range 3000 3009);
  load = import ./load-nodes.nix {inherit lib;};
  inherit (load) carrier;
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-traffic";
    globalTimeout = (minutes + 30) * 60;

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (phone: lib.nameValuePair "sip-${phone}" "pw-${phone}") phones);
          })
          load.pbx
        ];
        virtualisation.memorySize = 4096;
        environment.systemPackages = [pkgs.sqlite];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          logger.channels = {
            messages = [
              "notice"
              "warning"
              "error"
            ];
            full = [
              "notice"
              "warning"
              "error"
              "verbose"
            ];
          };
          settings."asterisk.conf".options.verbose = 3;

          cdr.sqlite.enable = true;
          cel = {
            enable = true;
            sqlite.enable = true;
          };

          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.genAttrs phones (phone: {
                context = "office";
                allow = ["ulaw"];
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${phone}";
              }))
              (lib.genAttrs callees (phone: {
                context = "office";
                allow = ["ulaw"];
                aor = {
                  contacts = ["sip:${phone}@${nodes.traffic.networking.primaryIPAddress}:5080"];
                  qualifyFrequency = 0;
                };
              }))
              {
                carrier = {
                  context = "from-carrier";
                  allow = ["ulaw"];
                  identify.match = [carrier];
                };
              }
            ];
          };

          confbridge.users.quiet.quiet = true;

          dialplan.contexts = {
            office.extensions = {
              "_30XX" = [
                "Dial(PJSIP/\${EXTEN},20)"
                "Hangup()"
              ];
              "7000" = [
                "Answer()"
                "Echo()"
              ];
              "8000" = [
                "Answer()"
                "ConfBridge(8000,,quiet)"
                "Hangup()"
              ];
            };
            from-carrier.extensions."_30XX" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "Hangup()"
            ];
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
        CARRIER = "${carrier}"
        MINUTES = ${toString minutes}
        phones = ${builtins.toJSON phones}
        callees = ${builtins.toJSON callees}

        start_all()
        pbx.wait_for_unit("asterisk.service")
        traffic.wait_for_unit("multi-user.target")
        pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        def start(name, *args):
            """Run SIPp as the unit sipp-`name`, with its statistics every 10 s
            in /tmp/sipp-`name`.csv."""
            traffic.succeed(
                f"systemd-run --unit=sipp-{name} -E PATH sh -c "
                + shlex.quote(
                    f"exec sipp {shlex.join(args)} -nostdin -trace_stat -stf /tmp/sipp-{name}.csv -fd 10 "
                    + f"-trace_err -error_file /tmp/sipp-{name}.errors > /dev/null"
                )
            )

        def finish(name):
            """Stop placing calls, let the calls in progress end and wait for SIPp to exit."""
            traffic.succeed(f"systemctl kill -s USR1 sipp-{name}")
            traffic.wait_until_succeeds(f"! systemctl is-active sipp-{name}", timeout=120)

        def counts(name):
            stats = sipp_statistics(traffic, f"/tmp/sipp-{name}.csv")
            return {"ok": int(stats["SuccessfulCall(C)"]), "failed": int(stats["FailedCall(C)"])}

        def records():
            """Rows of the CDR and CEL tables and the size of master.db."""
            db = "/var/log/asterisk/master.db"
            # Asterisk waits up to 1 s (busy_timeout) for a reader to let go
            cdr, cel = pbx.succeed(f"sqlite3 -readonly -cmd '.timeout 500' {db} 'select count(*) from cdr' 'select count(*) from cel'").split()
            return {"cdr_rows": int(cdr), "cel_rows": int(cel), "master_db_bytes": int(pbx.succeed(f"stat -c %s {db}"))}

        def descriptors():
            return pbx.succeed("ls -l /proc/$(systemctl show -P MainPID asterisk.service)/fd | sed 's/.* -> //' | sort")

        before = usage(pbx)
        descriptors_before = lasting_descriptors(pbx)
        opened_before = descriptors()
        print(f"before the traffic: {before}")

        start("uas", "-sn", "uas", "-i", SIPP, "-p", "5080", "-mi", SIPP, "-mp", "6000", "-rtp_echo")
        sipp_injection(traffic, "/tmp/phones.csv", [(phone, f"pw-{phone}") for phone in phones])
        # 200 registrations a minute, each phone's once a minute for 120 s
        start("register", PBX, "-sf", "/etc/sipp/register.xml", "-inf", "/tmp/phones.csv", "-key", "expires", "120",
              "-i", SIPP, "-p", "5070", "-r", "10", "-rp", "3000", "-aa")
        # the callees' static contacts count too
        wait_contacts(pbx, len(phones) + len(callees), timeout=120)
        # eight calls to phones, one to Echo() and one to the conference, in turn
        sipp_injection(traffic, "/tmp/calls.csv", [
            (caller, f"pw-{caller}", destination)
            for caller, destination in zip(phones[:10], callees[:8] + ["7000", "8000"])
        ])
        start("calls", PBX, "-sf", "/etc/sipp/call.xml", "-inf", "/tmp/calls.csv", "-i", SIPP, "-p", "5090",
              "-mi", SIPP, "-min_rtp_port", "20000", "-max_rtp_port", "40000", "-r", "1", "-rp", "2000", "-d", "30000")
        start("carrier", PBX, "-sn", "uac", "-s", callees[8], "-i", CARRIER, "-p", "5060", "-mi", CARRIER,
              "-r", "1", "-rp", "5000", "-d", "20000")

        with subtest("audio flows both ways"):
            pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -qE '^[1-9][0-9]* active calls'", timeout=60)
            time.sleep(10)
            stats = channel_stats(pbx)
            assert any(s["rx"] > 0 and s["tx"] > 0 for s in stats.values()), stats

        samples = []
        output = open(driver.out_dir / "traffic.csv", "w", newline="")
        began = time.time()
        with subtest(f"{MINUTES} minutes of traffic"):
            for minute in range(MINUTES + 1):
                sample = {"minute": minute, **usage(pbx), **records()}
                for name in ["calls", "carrier", "register"]:
                    for key, value in counts(name).items():
                        sample[f"{name}_{key}"] = value
                if not samples:
                    output.write(",".join(sample) + "\n")
                samples.append(sample)
                output.write(",".join(str(sample.get(column, "")) for column in samples[0]) + "\n")
                output.flush()
                print(f"traffic sample: {sample}")
                assert sample["pid"] == float(pid), f"Asterisk restarted: {sample['pid']} is not {pid}"
                time.sleep(max(0, began + 60 * (minute + 1) - time.time()))
        output.close()

        with subtest("the traffic ends without failed calls and leaves nothing behind"):
            for name in ["calls", "carrier", "register"]:
                finish(name)
            wait_idle(pbx, timeout=120)
            after = usage(pbx)
            print(f"after the traffic: {after}")
            for name in ["calls", "carrier", "register"]:
                assert counts(name)["failed"] == 0, (name, counts(name), traffic.succeed(f"tail -n 50 /tmp/sipp-{name}.errors || true"))
            assert after["channels"] == 0 and after["bridges"] == 0, after
            descriptors_after = lasting_descriptors(pbx)
            assert descriptors_after == descriptors_before, f"descriptors before the traffic:\n{opened_before}\nafter it:\n{descriptors()}"

        with subtest("what each call leaves on disk, and whether anything rotates it"):
            # from the tenth minute on, past the start of the calls
            first, last = samples[10], samples[-1]
            calls = last["processed"] - first["processed"]
            hours = (last["minute"] - first["minute"]) / 60
            for key in ["log_full_bytes", "log_messages_bytes", "master_db_bytes", "cdr_rows", "cel_rows", "astdb_entries", "astdb_bytes", "journal_bytes"]:
                grown = last[key] - first[key]
                print(f"growth of {key}: {grown / calls:.1f} per call, {grown / hours:.0f} per hour, {grown / hours * 24 / 1e6:.2f} M per day at this traffic")
            print(f"{calls:.0f} calls in {hours:.2f} h")
            print("logrotate: " + pbx.execute("systemctl cat logrotate.service 2>&1; grep -r asterisk /etc/logrotate.conf /etc/logrotate.d 2>&1")[1])
            print("files under /var/log/asterisk: " + pbx.succeed("ls -la /var/log/asterisk"))
      '';
  }
