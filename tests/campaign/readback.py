#!/usr/bin/env python3
"""CORE-04 at T1 (P7): every string of the options campaign that evaluates
(options.nix, each option's strings with a tag of their own), read back from
the Asterisk that loads it (readback.nix), many options to a configuration.

    readback.py OUT [--flake DIR] [--only REGEX] [--batch-size 150]
                    [--hints T1] [--workers 2] [--max-memory 1800] [--jobs 4]

A case is read back when its string shows unchanged in what the probe
reads: the output of its commands and the data of its call's steps, which
functions fill in. One whose string shows changed, or not at all, is probed
again alone, and its verdict comes from that run: `changed`, with the lines
that show its tag, `unseen` when nothing shows it, `rejected at T1` when its
configuration does not load, so it cannot be deployed either, `Asterisk
crashed`, or `probe failed` and `probe does not evaluate`, which say nothing
of the case. A configuration that does not load is split in halves
until each part loads or holds one case. --hints, the t1.json of an
options.py run, names the cases that failed at T1 there, which start alone.
OUT gets each round's evaluation and report.json.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True

import options  # noqa: E402

# what the show commands answer for an object they do not find, with the name
# they were given (res/res_pjsip/pjsip_cli.c, main/manager.c, res/ari/cli.c,
# apps/confbridge/conf_config_parser.c, main/named_acl.c)
NOT_FOUND = re.compile(
    r"Unable to find object .*\.|There is no manager called .*|User '.*' not found"
    r"|No conference (user profile|bridge profile|menu) named '.*' found!|Could not find ACL named '.*'"
)


def probed(drv):
    """What a built probe read: each line of its commands' output but those
    that say an object was not found, and each step of its call with the
    data the functions in it returned."""
    out = subprocess.run(["nix-store", "--query", "--outputs", drv], check=True, capture_output=True, text=True).stdout.strip()
    probe = json.loads((pathlib.Path(out) / "probe.json").read_text())
    return [(c["command"], line) for c in probe["commands"] for line in c["output"].splitlines() if not NOT_FOUND.fullmatch(line.strip())] + [
        ("call", f"{step['application']}({step['data']})") for call in probe["calls"] for step in call["steps"]
    ]


def look(case, lines):
    """Whether the case's string shows unchanged, changed (its tag shows) or
    not at all, with the lines that show it."""
    value = case["marker"]
    tag = re.search(r"q7[0-9a-f]{8}", value).group(0)
    # a value that starts with spaces, found after more spaces, may be one
    # without them in a padded column
    shown = re.compile(("(?<!\\s)" if value[0].isspace() else "") + re.escape(value))
    exact = [f"{command}: {line[:300]}" for command, line in lines if shown.search(line)]
    if exact:
        return "unchanged", exact[:3]
    tagged = [f"{command}: {line[:300]}" for command, line in lines if tag in line]
    return ("changed", tagged[:10]) if tagged else ("unseen", [])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--only", help="regular expression the case id must match")
    parser.add_argument("--batch-size", type=int, default=150)
    parser.add_argument("--hints", type=pathlib.Path, help="t1.json of an options.py run")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--max-memory", type=int, default=1800, help="MiB per evaluation worker")
    parser.add_argument("--jobs", type=int, default=4, help="builds at once")
    args = parser.parse_args()

    campaign = options.Campaign(args, "readback.nix")
    manifest = {case["index"]: case for case in campaign.manifest() if not args.only or re.search(args.only, case["id"])}
    print(f"{len(manifest)} strings", flush=True)

    t0 = campaign.jobs("t0", {"indices": sorted(manifest)})
    results, claims = {}, {}
    for i in manifest:
        result, details = options.t0_of(t0.get(f"c{i}"))
        if result != "pass":
            results[i] = {"verdict": "rejected at T0"}
        elif not options.boots(details):
            results[i] = {"verdict": "not booted"}
        else:
            claims[i] = t0[f"c{i}"]["meta"]["claims"]
    hints = json.loads(args.hints.read_text()) if args.hints else {}
    alone = [i for i in claims if hints.get(manifest[i]["id"], {}).get("t1") == "fail"]
    queue = [[i] for i in alone]
    for base in ("core", "pbx"):
        queue += options.pack([i for i in claims if i not in alone and manifest[i]["base"] == base], claims, args.batch_size)

    round_ = 0
    while queue:
        round_ += 1
        print(f"round {round_}: {len(queue)} configurations, {sum(map(len, queue))} cases, {load()}", flush=True)
        jobs = campaign.jobs(f"round{round_}", {"batches": queue})
        drvs = {k: jobs[f"b{k}"]["meta"]["probe"] for k in range(len(queue)) if "meta" in jobs.get(f"b{k}", {})}
        built = campaign.build(drvs.values())
        next_queue = []
        for k, batch in enumerate(queue):
            drv = drvs.get(k)
            if drv in built:
                lines = probed(drv)
                for i in batch:
                    verdict, where = look(manifest[i], lines)
                    if verdict == "unchanged" or len(batch) == 1:
                        results[i] = {"verdict": verdict, "where": where, "batch": len(batch)}
                    else:
                        next_queue.append([i])
            elif len(batch) == 1 and drv:
                log = campaign.log(drv)
                verdict = "rejected at T1"
                if any("Segmentation fault" in line for line in log):
                    verdict = "Asterisk crashed"
                elif any("Traceback" in line for line in log):
                    verdict = "probe failed"
                results[batch[0]] = {"verdict": verdict, "log": log}
            elif len(batch) == 1:
                results[batch[0]] = {"verdict": "probe does not evaluate", "log": [jobs.get(f"b{k}", {}).get("error")]}
            else:
                half = len(batch) // 2
                next_queue += [batch[:half], batch[half:]]
        queue = next_queue

    report = [manifest[i] | results[i] for i in sorted(results)]
    (args.out / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    counts = {}
    for r in report:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    for verdict, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"{n:6} {verdict}")
    print(f"report in {args.out / 'report.json'}, {load()}")


def load():
    """The host's load, printed with every round."""
    return "load " + " ".join(f"{x:.1f}" for x in os.getloadavg())


if __name__ == "__main__":
    main()
