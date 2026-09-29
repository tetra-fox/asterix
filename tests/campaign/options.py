#!/usr/bin/env python3
"""The options campaign: every case of options.nix evaluated (T0), and the
cases that evaluate booted by Asterisk (T1), many to a configuration.

    options.py OUT [--flake DIR] [--only REGEX] [--workers 2]
                   [--max-memory 1800] [--jobs 6] [--batch-size 120]
                   [--full-sample 80] [--seed 1] [--no-t1]

Evaluation runs in nix-eval-jobs inside a systemd scope capped at workers
times --max-memory. OUT gets manifest.json, t0.jsonl (nix-eval-jobs' output),
full.jsonl and faithful.json (the whole NixOS evaluation of a sample against
the light one), t1.json (each case's boot, with the log of every failed
build), report.json: every case whose outcome is not what it expects, and
known.nix for sample.nix.
"""

import argparse
import json
import pathlib
import random
import re
import subprocess
import sys

EXPR = """
let
  flake = builtins.getFlake "{flake}";
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  campaign = import "${{flake}}/tests/campaign/options.nix" {{
    inherit pkgs;
    self = flake;
  }};
in
  {body}
"""

# a batch this small is built case by case instead of split again
SMALL = 3


class Campaign:
    def __init__(self, args):
        self.args = args
        # a copy in the store, so every evaluation sees the same tree
        self.flake = subprocess.run(
            ["nix", "eval", "--raw", "--impure", "--expr",
             f'(builtins.getFlake "{pathlib.Path(args.flake).resolve()}").outPath'],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.out = args.out
        self.out.mkdir(parents=True, exist_ok=True)
        self.eval_jobs = subprocess.run(
            ["nix", "build", "--no-link", "--print-out-paths", "--inputs-from", self.flake, "nixpkgs#nix-eval-jobs"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip() + "/bin/nix-eval-jobs"

    def expr(self, body):
        return EXPR.format(flake=self.flake, body=body)

    def manifest(self):
        text = subprocess.run(
            ["nix", "eval", "--impure", "--json", "--expr", self.expr("campaign.manifest")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        (self.out / "manifest.json").write_text(text)
        return json.loads(text)

    def jobs(self, name, arguments):
        """nix-eval-jobs over campaign.jobs ARGUMENTS; the JSON lines by attribute."""
        path = self.out / f"{name}-arguments.json"
        path.write_text(json.dumps(arguments))
        # a file, since systemd-run would substitute ${...} in an --expr
        expression = self.out / f"{name}.nix"
        expression.write_text(self.expr(f'campaign.jobs (builtins.fromJSON (builtins.readFile "{path}"))'))
        memory = self.args.workers * self.args.max_memory + 512
        command = [
            "systemd-run", "--user", "--scope", "--quiet", "-p", f"MemoryMax={memory}M",
            self.eval_jobs, "--impure", "--meta", "--workers", str(self.args.workers),
            "--max-memory-size", str(self.args.max_memory), str(expression),
        ]
        output = self.out / f"{name}.jsonl"
        with open(output, "w") as stdout, open(self.out / f"{name}.stderr", "w") as stderr:
            code = subprocess.run(command, stdout=stdout, stderr=stderr).returncode
        results = {}
        for line in output.read_text().splitlines():
            job = json.loads(line)
            results[job["attr"]] = job
        if code != 0 and not results:
            sys.exit(f"nix-eval-jobs failed ({code}) without output, see {output}")
        return results

    def build(self, drvs):
        """Build DRVS; the set of those that built."""
        drvs = sorted(set(drvs))
        if not drvs:
            return set()
        subprocess.run(
            ["nix-store", "--realise", "--keep-going", "--max-jobs", str(self.args.jobs), *drvs],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        built = set()
        for drv in drvs:
            outputs = subprocess.run(
                ["nix-store", "--query", "--outputs", drv], check=True, capture_output=True, text=True
            ).stdout.split()
            if all(pathlib.Path(o).exists() for o in outputs):
                built.add(drv)
        return built

    def log(self, drv):
        # Asterisk may log part of a multibyte character
        result = subprocess.run(["nix-store", "--read-log", drv], capture_output=True, text=True, errors="replace")
        lines = result.stdout.splitlines()
        # the config check prints what Asterisk logged, then its own verdict
        return lines[-40:]


def t0_of(job):
    """(result, details) of one nix-eval-jobs line."""
    if job is None:
        return "error", {"error": "no output"}
    if "error" in job:
        message = [line.strip() for line in job["error"].splitlines() if line.strip().startswith("error:")]
        return "error", {"error": message[-1] if message else job["error"][-500:]}
    outcome = job["meta"].get("outcome")
    if outcome is None:
        return "error", {"error": "nix-eval-jobs gave no outcome"}
    if outcome["failed"]:
        return "assertion", outcome
    return "pass", outcome


def prefixes(path):
    """The paths PATH is below. A dot inside a quoted name gives a path no
    claim has, which is harmless."""
    return [path[:i] for i, c in enumerate(path) if c == "."]


class Batch:
    """Cases whose settings do not collide: no path is set to two values,
    and no value is set where another case sets something below it."""

    def __init__(self):
        self.cases, self.taken, self.below = [], {}, set()

    def fits(self, claims):
        for claim in claims:
            path, value = claim["path"], claim["value"]
            if self.taken.get(path, value) != value or path in self.below:
                return False
            if any(p in self.taken for p in prefixes(path)):
                return False
        return True

    def add(self, case, claims):
        self.cases.append(case)
        for claim in claims:
            self.taken[claim["path"]] = claim["value"]
            self.below.update(prefixes(claim["path"]))


def pack(cases, claims, size):
    """Cases in configurations of at most SIZE whose claims do not collide."""
    batches = []
    for case in cases:
        for batch in batches:
            if len(batch.cases) < size and batch.fits(claims[case]):
                break
        else:
            batch = Batch()
            batches.append(batch)
        batch.add(case, claims[case])
    return [batch.cases for batch in batches]


def boots(details):
    """Whether a configuration's checks start Asterisk: not with the service
    or checkConfig off, which in a shared configuration would turn the check
    off for every case in it."""
    return any("-asterisk-config-check.drv" in d for d in details["checks"])


def t1(campaign, manifest, outcomes, claims):
    """Boot every case that evaluates: the valid ones in shared
    configurations, split in halves when one fails, and the invalid ones and
    the strings, of which many fail, each alone."""
    passing = [i for i, (result, details) in outcomes.items() if result == "pass"]
    results = {i: {"t1": "none", "log": []} for i in passing if not boots(outcomes[i][1])}
    passing = [i for i in passing if i not in results]
    alone = [i for i in passing if manifest[i]["expect"] in ("reject", "verbatim")]
    shared = [i for i in passing if manifest[i]["expect"] in ("accept", "warn")]

    # kept after every step, so an interrupted run leaves what it booted
    def save():
        path = campaign.out / "t1.json"
        path.write_text(json.dumps({manifest[i]["id"]: boot for i, boot in results.items()}, indent=1))

    def build_alone(indices):
        drvs = {i: outcomes[i][1]["checks"] for i in indices}
        built = campaign.build([d for ds in drvs.values() for d in ds])
        for i, ds in drvs.items():
            failed = [d for d in ds if d not in built]
            results[i] = {"t1": "pass", "log": []}
            if failed:
                # the check's name, without the store path's hash and .drv
                check = re.sub(r"^[0-9a-z]{32}-|\.drv$", "", pathlib.Path(failed[0]).name)
                results[i] = {"t1": "fail", "check": check, "log": campaign.log(failed[0])}
        save()

    build_alone(alone)
    queue = []
    for base in ("core", "pbx"):
        mine = [i for i in shared if manifest[i]["base"] == base]
        queue += pack(mine, claims, campaign.args.batch_size)
    round_ = 0
    while queue:
        round_ += 1
        print(f"T1 round {round_}: {len(queue)} configurations, {sum(map(len, queue))} cases", flush=True)
        jobs = campaign.jobs(f"t1-round{round_}", {"indices": [], "batches": queue})
        evaluated = {}
        for k, batch in enumerate(queue):
            job = jobs.get(f"b{k}")
            result, details = t0_of(job) if job else ("error", {"error": "no output"})
            evaluated[k] = (result, details)
        built = campaign.build([d for result, details in evaluated.values() if result == "pass" for d in details["checks"]])
        next_queue, small = [], []
        for k, batch in enumerate(queue):
            result, details = evaluated[k]
            if result == "pass" and boots(details) and all(d in built for d in details["checks"]):
                for i in batch:
                    results[i] = {"t1": "pass", "log": [], "batch": len(batch)}
            elif len(batch) <= SMALL:
                small += batch
            else:
                half = len(batch) // 2
                next_queue += [batch[:half], batch[half:]]
        build_alone(small)
        queue = next_queue
    return results


VERDICTS = {
    # expect -> t0 -> (verdict or None when T1 decides)
    "accept": {"error": "P2: rejected at T0", "assertion": "P2: rejected at T0", "pass": None},
    "warn": {"error": "P2: rejected at T0", "assertion": "P2: rejected at T0", "pass": None},
    "reject": {"error": "ok", "assertion": "ok", "pass": None},
    "verbatim": {"error": "ok", "assertion": "ok", "pass": None},
}


def verdict(case, result, details, boot):
    v = raw_verdict(case, result, details, boot)
    if case.get("limitation") and not v.startswith("ok"):
        return f"limitation ({case['limitation']})"
    return v


def raw_verdict(case, result, details, boot):
    expect = case["expect"]
    first = VERDICTS[expect][result]
    if first is not None:
        return first
    problems = []
    if expect == "warn" and not details["warnings"]:
        problems.append("no warning")
    if expect == "verbatim" and details.get("verbatim") is False:
        problems.append("P7: not written as given")
    # no boot with --no-t1
    t1 = boot["t1"] if boot else None
    if expect == "reject" and t1 != "fail":
        problems.append({"pass": "P3: loads", "none": "P1: evaluates, nothing boots it", None: "evaluates (T1 not run)"}[t1])
    elif expect in ("accept", "warn") and t1 == "fail":
        problems.append("P2: does not load")
    # a string may fail at T1 too: then it cannot be deployed either
    return "; ".join(problems) or {"pass": "ok", "fail": "ok (rejected at T1)", "none": "ok (T0 only)", None: "ok (T0 only)"}[t1]


KNOWN = """\
# The cases sample.nix leaves out of the gate, with why: what the last whole
# run of options.py found wrong, and invalid values only a build check
# rejects, since the gate boots valid values only. options.py writes this
# file to OUT/known.nix.
"""


def known_nix(known):
    def string(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'

    return KNOWN + "{\n" + "".join(f"  {string(k)} = {string(known[k])};\n" for k in sorted(known)) + "}\n"


def faithfulness(campaign, manifest, t0_jobs, indices):
    """The whole NixOS evaluation of INDICES against the light one."""
    full = campaign.jobs("full", {"mode": "full", "indices": indices})

    # the order of assertions, warnings and checks follows the order of the
    # modules, which differs between the two
    def comparable(outcome):
        result, details = outcome
        if result == "error":
            return result, None
        return result, {
            key: sorted(value) if isinstance(value, list) else value
            for key, value in details.items()
            if key in ("failed", "warnings", "files", "units", "checks", "verbatim", "landing")
        }

    report = []
    for i in indices:
        a, b = t0_of(t0_jobs.get(f"c{i}")), t0_of(full.get(f"c{i}"))
        if comparable(a) != comparable(b):
            report.append({"case": manifest[i]["id"], "light": a, "full": b})
    return {"compared": len(indices), "disagree": report}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--only", help="regular expression the case id must match")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--max-memory", type=int, default=1800, help="MiB per evaluation worker")
    parser.add_argument("--jobs", type=int, default=6, help="builds at once")
    parser.add_argument("--batch-size", type=int, default=120)
    parser.add_argument("--full-sample", type=int, default=80)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--no-t1", action="store_true")
    args = parser.parse_args()

    campaign = Campaign(args)
    manifest = campaign.manifest()
    indices = [i for i, case in enumerate(manifest) if not args.only or re.search(args.only, case["id"])]
    print(f"{len(indices)} of {len(manifest)} cases", flush=True)

    t0_jobs = campaign.jobs("t0", {"indices": indices})
    outcomes = {i: t0_of(t0_jobs[f"c{i}"]) if f"c{i}" in t0_jobs else ("error", {"error": "no output"}) for i in indices}
    claims = {int(job["attr"][1:]): job["meta"]["claims"] for job in t0_jobs.values() if "meta" in job}

    faithful = {"compared": 0, "disagree": []}
    if args.full_sample:
        rng = random.Random(args.seed)
        sample = sorted(set(rng.sample(indices, min(args.full_sample, len(indices))) + [i for i in indices if manifest[i]["full"]]))
        faithful = faithfulness(campaign, manifest, t0_jobs, sample)
        (campaign.out / "faithful.json").write_text(json.dumps(faithful, indent=1))

    boots = {} if args.no_t1 else t1(campaign, manifest, outcomes, claims)

    report, counts, known = [], {}, {}
    for i in indices:
        case = manifest[i]
        result, details = outcomes[i]
        boot = boots.get(i)
        v = verdict(case, result, details, boot)
        counts[v] = counts.get(v, 0) + 1
        if not v.startswith("ok"):
            known[case["id"]] = v
            report.append({
                **case,
                "t0": result,
                "verdict": v,
                "failed": details.get("failed") or details.get("error"),
                "warnings": details.get("warnings"),
                "landing": details.get("landing"),
                "t1": boot["t1"] if boot else None,
                "log": boot["log"] if boot else None,
            })
        elif v == "ok (rejected at T1)" and case["expect"] == "reject":
            known[case["id"]] = f"rejected by {boot['check']}"
    (campaign.out / "report.json").write_text(json.dumps(report, indent=1))
    (campaign.out / "known.nix").write_text(known_nix(known))
    for v, n in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"{n:6} {v}")
    print(f"faithfulness: {len(faithful['disagree'])} of {faithful['compared']} disagree; report in {campaign.out}")


if __name__ == "__main__":
    main()
