# 1000 phones register within 10 s, sent by SIPp at 200 a second; their
# password comes from one secret, as systemd holds at most 256 credentials
# for a service. Calls from phone to phone with audio, 40 a second for 20 s,
# run five times over. Then calls per second are raised step by step, phone
# to phone and from a carrier to a phone, each from a fresh Asterisk, until
# calls fail or Asterisk ends; the rate before is the limit. Durations,
# Asterisk's CPU, resident memory, heap in use once the calls ended and most
# calls at once, the host's load and each step are printed and written to
# load.json in the result.
#
#   VLAN 1  pbx, traffic (SIPp: phones 1000-1999 and 3000-3009 on its first
#           address, the carrier on 192.168.1.100)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  phones = map toString (lib.range 1000 1999);
  # phones that answer at SIPp's address without registering
  callees = map toString (lib.range 3000 3009);
  load = import ./load-nodes.nix {inherit lib;};
  inherit (load) carrier;

  # calls per second of each step, 20 s each
  rates = [
    20
    40
    80
    120
    160
    200
    250
    300
    400
    500
  ];
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-load";

    nodes = {
      pbx = {
        config,
        nodes,
        ...
      }: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {fixed.sip-phones = "pw-phones";})
          load.pbx
        ];
        virtualisation.memorySize = 4096;
        # the test VMs panic when out of memory; a server's OOM killer ends
        # Asterisk instead, and systemd starts it again
        boot.kernel.sysctl."vm.panic_on_oom" = 0;

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {};
            endpoints = lib.mkMerge [
              (lib.genAttrs phones (_: {
                context = "office";
                allow = ["ulaw"];
                auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-phones";
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

          dialplan.contexts = {
            office.extensions."_30XX" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "Hangup()"
            ];
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
        RATES = ${builtins.toJSON rates}
        phones = ${builtins.toJSON phones}
        callees = ${builtins.toJSON callees}

        start_all()
        pbx.wait_for_unit("asterisk.service")
        traffic.wait_for_unit("multi-user.target")
        steps = []
        limits = {}

        def run(name, *args):
            """Run SIPp until it ends and return its statistics, the SIP
            responses of the calls that failed by count, and the most
            memory and calls Asterisk had meanwhile, sampled every 2 s."""
            status = f"/tmp/sipp-{name}.status"
            traffic.succeed(
                f"rm -f /tmp/sipp-{name}.csv /tmp/sipp-{name}.errors {status}; systemd-run --unit=sipp-{name} --collect -E PATH sh -c "
                + shlex.quote(
                    f"sipp {shlex.join(args)} -nostdin -timeout 300 -timeout_error -trace_stat -stf /tmp/sipp-{name}.csv -fd 1 "
                    + f"-trace_err -error_file /tmp/sipp-{name}.errors > /dev/null; echo $? > {status}"
                )
            )
            peak = {"rss_kib": 0.0, "calls": 0.0, "threads": 0.0}
            while traffic.execute(f"test -f {status}")[0] != 0:
                try:
                    sample = usage(pbx)
                    peak = {key: max(peak[key], sample[key]) for key in peak}
                except Exception:
                    # there is nothing to sample while systemd starts Asterisk
                    # again after the kernel killed it out of memory, which
                    # the step records
                    if pbx.execute("journalctl -u asterisk.service | grep -q \"Failed with result 'oom-kill'\"")[0] != 0:
                        raise
                time.sleep(2)
            stats = sipp_statistics(traffic, f"/tmp/sipp-{name}.csv")
            responses = traffic.succeed(
                f"grep -ahoE '^SIP/2.0 [0-9]{{3}}' /tmp/sipp-{name}.errors 2>/dev/null | sort | uniq -c || true"
            ).strip()
            hours, minutes, seconds = stats["ElapsedTime(C)"].split(":")
            return {
                "sipp_status": int(traffic.succeed(f"cat {status}")),
                "ok": int(stats["SuccessfulCall(C)"]),
                "failed": int(stats["FailedCall(C)"]),
                "retransmissions": int(stats["Retransmissions(C)"]),
                "response_time": stats.get("ResponseTime1(C)", ""),
                "seconds": float(hours) * 3600 + float(minutes) * 60 + float(seconds),
                "failed_responses": responses,
                "peak_rss_kib": peak["rss_kib"],
                "peak_calls": peak["calls"],
                "peak_threads": peak["threads"],
            }

        def main_pid():
            return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

        def measured(action):
            """What `action` returns, with Asterisk's CPU seconds and memory
            before and after it, and the host's load."""
            before = usage(pbx)
            result = action()
            pbx.wait_until_succeeds("asterisk -rx 'core waitfullybooted'", timeout=120)
            after = usage(pbx)
            result.update(
                asterisk_cpu_s=round(after["cpu_s"] - before["cpu_s"], 2),
                rss_kib_before=before["rss_kib"],
                rss_kib_after=after["rss_kib"],
                threads_after=after["threads"],
                host_load_before=before["host_load1"],
                host_load_after=after["host_load1"],
                vm_load_after=after["vm_load1"],
            )
            return result

        def settled_heap():
            """Asterisk's heap in use once the calls ended and it came back
            down, about 35 s later in a lab run."""
            wait_idle(pbx, timeout=300)
            time.sleep(40)
            return heap_in_use(pbx)

        with subtest("1000 phones register within 10 s"):
            sipp_injection(traffic, "/tmp/phones.csv", [(phone, "pw-phones") for phone in phones])

            def register():
                # timed on the traffic machine: SIPp ends once each registration has its 200
                seconds = traffic.succeed(
                    "start=$(date +%s.%N); "
                    + shlex.join([
                        "sipp", PBX, "-sf", "/etc/sipp/register.xml", "-inf", "/tmp/phones.csv", "-key", "expires", "3600",
                        "-i", SIPP, "-p", "5070", "-r", "200", "-m", "1000", "-nostdin", "-timeout", "60", "-timeout_error",
                        "-trace_stat", "-stf", "/tmp/sipp-register.csv",
                    ])
                    + ' > /dev/null && awk "BEGIN {print $(date +%s.%N) - $start}"'
                )
                stats = sipp_statistics(traffic, "/tmp/sipp-register.csv")
                # the callees' static contacts count too
                wait_contacts(pbx, len(phones) + len(callees), timeout=10)
                return {
                    "ok": int(stats["SuccessfulCall(C)"]),
                    "failed": int(stats["FailedCall(C)"]),
                    "retransmissions": int(stats["Retransmissions(C)"]),
                    "until_all_registered_s": round(float(seconds), 2),
                }

            registration = measured(register)
            print(f"registration: {registration}")
            assert registration["ok"] == 1000 and registration["failed"] == 0, registration
            assert registration["until_all_registered_s"] <= 10, registration

        traffic.succeed(f"systemd-run --unit=sipp-uas -E PATH sh -c 'exec sipp -sn uas -i {SIPP} -p 5080 -mi {SIPP} -mp 6000 -rtp_echo -nostdin > /dev/null'")
        sipp_injection(traffic, "/tmp/calls.csv", [
            (caller, "pw-phones", callee) for caller, callee in zip(phones[:10], callees)
        ])
        kinds = {
            "phone to phone": lambda rate: run(
                "calls", PBX, "-sf", "/etc/sipp/call.xml", "-inf", "/tmp/calls.csv", "-i", SIPP, "-p", "5090", "-mi", SIPP,
                "-min_rtp_port", "20000", "-max_rtp_port", "40000", "-r", str(rate), "-m", str(rate * 20), "-d", "1000"),
            "carrier to phone": lambda rate: run(
                "carrier", PBX, "-sn", "uac", "-s", callees[0], "-i", CARRIER, "-p", "5060", "-mi", CARRIER,
                "-r", str(rate), "-m", str(rate * 20), "-d", "1000"),
        }
        with subtest("the same 20 s at 40 calls per second five times"):
            heap_before = heap_in_use(pbx)
            print(f"heap in use before the calls: {heap_before} KiB")
            for _ in range(5):
                step = measured(lambda: kinds["phone to phone"](40))
                step.update(kind="phone to phone, repeated", rate=40, heap_kib_after=settled_heap())
                print(f"step: {step}")
                steps.append(step)

        for kind, calls in kinds.items():
            with subtest(f"calls per second {kind}, raised until calls fail"):
                # each kind starts from a fresh Asterisk; registrations are kept in astdb
                pbx.succeed("systemctl restart asterisk.service")
                pid = main_pid()
                limit = None
                # the first rate at which Asterisk answers later than SIPp's 500 ms
                retransmitting = None
                for rate in RATES:
                    step = measured(lambda: calls(rate))
                    step.update(kind=kind, rate=rate, restarted=main_pid() != pid)
                    if not step["restarted"]:
                        step["heap_kib_after"] = settled_heap()
                    print(f"step: {step}")
                    steps.append(step)
                    if retransmitting is None and step["retransmissions"] > 0:
                        retransmitting = rate
                    if step["failed"] > 0 or step["restarted"]:
                        break
                    limit = rate
                print(f"{kind}: {limit} calls per second without a failed call, SIPp retransmitting from {retransmitting}")
                limits[kind] = {"limit": limit, "retransmitting": retransmitting}

        with open(driver.out_dir / "load.json", "w") as output:
            json.dump({"registration": registration, "heap_kib_before": heap_before, "steps": steps, "limits": limits}, output, indent=2)
      '';
  }
