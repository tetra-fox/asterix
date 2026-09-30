#!/usr/bin/env python3
"""The generated-configuration campaign: random pbx configurations
(generate.py) and mutations of them that break one thing, evaluated (T0),
booted by Asterisk (T1), and called through the probe against the routing
oracle (routing.py).

    configs.py run OUT [--seed N] [--count 7000] [--mutants 3000]
                       [--probes 2000] [--splits 2000] [--resume]
                       [--flake DIR] [--workers 2] [--max-memory 1800]
                       [--jobs 6]
    configs.py shrink OUT SIGNATURE [--case ID]
    configs.py vm OUT [--seed N] [--count 500] [--per-test 25] [--calls 6]
                      [--parallel 1] [--max-load 16]
    configs.py sample FILE OUT [--seed 1] [--valid 6] [--mutants 42]
                               [--probes 2] [--calls 8]
    configs.py sample FILE --check
    configs.py tollfraud OUT [--seed N] [--count 2000]
    configs.py compare CASE PROBE

It needs a Python with Hypothesis, such as `nix shell --impure --expr
'with (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
python3.withPackages (p: [p.hypothesis])'`.

`run` prints its seed and checks, per configuration:

- P1: one that evaluates without a failed assertion passes the checks
  that boot it
- P2: a valid one evaluates without a failed assertion and loads
- P3: a mutation fails at T0 or T1
- P4: every call the oracle plans ends where it predicts (`--probes`
  configurations with short times)
- P5: the same configuration twice, and spread over several modules, gives
  the same store paths as the one module the parts add up to (`--splits`)
- P6: every scalar the pbx layer writes to settings is replaced by a plain
  definition there

OUT gets the configurations (cases.json), each tier's output, and
report.json: each failure with its signature, the property and the tier it
showed at. `shrink` makes the smallest configuration of a signature that
still fails, with the same tiers, into OUT/shrunk/. `vm` runs P4 in VM tests
(vm.nix) with the phones and provider there. `sample` writes the seeded
configurations of the gate's campaign-configs check (configs-sample.nix)
once they pass, with the arguments that draw them, and with --check draws
them again from those and compares, as that check does; `compare` is that
check's comparison of a probe with the oracle. `tollfraud` walks valid
configurations with inbound numbers and calls out from each trunk to every
trunk's Dial (tollfraud.nix, SEC-03), with the ways out in OUT/paths.json,
and compares the named ones with those the oracle finds in the model
(routing.ways_out).
"""

import argparse
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

# the modules of this directory import each other; no bytecode in the tree
sys.dont_write_bytecode = True

import hypothesis  # noqa: E402
from hypothesis import HealthCheck, Phase  # noqa: E402

import generate  # noqa: E402
import options  # noqa: E402
import probe  # noqa: E402
import routing  # noqa: E402


def draw(strategy, count, seed):
    """COUNT distinct values of STRATEGY, as Hypothesis draws them with SEED."""
    found, seen = [], set()
    if count == 0:
        return found

    @hypothesis.seed(seed)
    @hypothesis.settings(
        max_examples=count * 2,
        database=None,
        phases=[Phase.generate],
        deadline=None,
        suppress_health_check=list(HealthCheck),
    )
    @hypothesis.given(strategy)
    def collect(value):
        key = json.dumps(value, sort_keys=True)
        if key not in seen and len(found) < count:
            seen.add(key)
            found.append(value)

    collect()
    return found


def cases(args):
    """The configurations of a run: valid ones, mutations of them, and valid
    ones with short times for the probe."""
    valid = draw(generate.configurations(wide=True), args.count, args.seed)
    rng = random.Random(args.seed)
    result = [{"id": f"v{i}", "kind": "valid", "model": m} for i, m in enumerate(valid)]
    attempts = 0
    while sum(c["kind"] == "mutant" for c in result) < args.mutants and attempts < args.mutants * 20:
        attempts += 1
        case = mutant(f"m{len(result)}", valid[rng.randrange(len(valid))], rng.choice(generate.MUTATIONS).__name__, rng.randrange(2**32))
        if case:
            result.append(case)
    for i, m in enumerate(draw(generate.configurations(fast=True), args.probes, args.seed + 1)):
        result.append(probed(f"p{i}", m, args.seed + i))
    return result


def mutant(case_id, base, mutation, seed):
    """The case of MUTATION with SEED applied to model BASE, or None where it
    does not apply."""
    mutated = generate.mutate(base, getattr(generate, mutation), seed)
    if mutated is None:
        return None
    m, label = mutated
    return {"id": case_id, "kind": "mutant", "base": base, "mutation": mutation, "seed": seed, "label": label, "model": m}


def probed(case_id, m, seed):
    """The case of model M with the calls the oracle plans with SEED."""
    return {"id": case_id, "kind": "probe", "model": m, "seed": seed, "plan": routing.plan(m, seed)}


def entries(case, rng, split):
    """The jobs of a case for configs.nix: the configuration itself, with the
    P6 overrides for a valid one and the probe's calls for a probe one, and
    with SPLIT the same configuration spread over modules, the one module
    those add up to, and the configuration again with its keys reversed."""
    module = generate.modules(case["model"])
    main = {"modules": [module]}
    if case["kind"] == "valid":
        main["overrides"] = True
    if case["kind"] == "probe":
        main["probe"] = {"commands": [], "calls": [c["call"] for c in case["plan"] if "call" in c]}
    result = [("main", main)]
    if split:
        parts, merged = generate.split(module, rng.randint(2, 4), rng)
        result += [("parts", {"modules": parts}), ("merged", {"modules": [merged]}), ("again", {"modules": [reverse(module)]})]
    return result


def reverse(value):
    """VALUE with the keys of every attribute set in reverse order."""
    if isinstance(value, dict):
        return {k: reverse(value[k]) for k in reversed(list(value))}
    if isinstance(value, list):
        return [reverse(v) for v in value]
    return value


def t0(campaign, name, jobs):
    """Evaluates JOBS, a list of configs.nix entries, in chunks; the meta or
    error of each."""
    results = []
    chunk = campaign.args.chunk
    for start in range(0, len(jobs), chunk):
        part = jobs[start : start + chunk]
        began = time.monotonic()
        out = campaign.jobs(f"{name}-{start // chunk}", part)
        for i in range(len(part)):
            job = out.get(f"g{i}")
            if job is None:
                results.append({"error": "no output"})
            elif "error" in job:
                lines = [line.strip() for line in job["error"].splitlines() if line.strip().startswith("error:")]
                results.append({"error": lines[-1] if lines else job["error"][-500:]})
            else:
                results.append(job["meta"])
        print(f"T0 {name}: {start + len(part)} of {len(jobs)} ({time.monotonic() - began:.0f} s for {len(part)}, {load()})", flush=True)
    return results


def check_name(drv):
    return re.sub(r"^[0-9a-z]{32}-|\.drv$", "", pathlib.Path(drv).name)


def failure(prop, tier, signature, text, case):
    return {"property": prop, "tier": tier, "signature": f"{prop}: {signature}", "text": text, "case": case["id"]}


def verdicts(campaign, cases_, evaluated):
    """The failures of every case, from their T0 results and the builds of
    their checks and probes."""
    drvs = set()
    for case in cases_:
        meta = evaluated[case["id"]]["main"]
        if "outcome" in meta and not meta["outcome"]["failed"]:
            drvs.update(meta["outcome"]["checks"])
            if "probe" in meta:
                drvs.add(meta["probe"])
    began = time.monotonic()
    built = campaign.build(sorted(drvs)) if not campaign.args.no_t1 else drvs
    print(f"T1 and probes: {len(built)} of {len(drvs)} built ({time.monotonic() - began:.0f} s, {load()})", flush=True)
    failures = []
    for case in cases_:
        failures += verdict(campaign, case, evaluated[case["id"]], built)
    return failures


def verdict(campaign, case, results, built):
    meta = results["main"]
    found = []
    if "error" in meta:
        # an evaluation error rejects a mutation at T0 as an assertion does
        if case["kind"] != "mutant":
            found.append(failure("P2", "T0", f"evaluation error: {normalise(meta['error'])}", meta["error"], case))
        return found
    outcome = meta["outcome"]
    if outcome["failed"]:
        if case["kind"] != "mutant":
            for message in outcome["failed"]:
                found.append(failure("P2", "T0", f"assertion: {normalise(message)}", message, case))
        return found
    failed_checks = [d for d in outcome["checks"] if d not in built]
    if case["kind"] == "mutant":
        # without T1, a mutation that evaluates is not decided
        if not failed_checks and not (campaign and campaign.args.no_t1):
            found.append(failure("P3", "T1", f"{case['mutation']} loads", case["label"], case))
        return found
    for drv in failed_checks:
        log = campaign.log(drv)
        found.append(failure("P1", "T1", f"{check_name(drv)}: {normalise(problem_line(log))}", "\n".join(log), case))
    if outcome["warnings"]:
        for warning in outcome["warnings"]:
            found.append(failure("P2", "T0", f"warning: {normalise(warning)}", warning, case))
    if "overrides" in meta:
        o = meta["overrides"]
        for kept in o["kept"]:
            found.append(failure("P6", "T0", f"kept {normalise(kept)}", kept, case))
        if not o["rendered"]:
            found.append(failure("P6", "T0", "files fail with every scalar replaced", "", case))
    if "parts" in results:
        found += splits(case, results)
    # without T1 no probe ran
    if "probe" in meta and not failed_checks and not (campaign and campaign.args.no_t1):
        found += probe_verdicts(case, meta["probe"], built)
    return found


def splits(case, results):
    """P5 from the entries of a split."""
    def paths(meta):
        if "error" in meta:
            return ("error", normalise(meta["error"]))
        o = meta["outcome"]
        return (o.get("config"), sorted(o.get("checks", [])), sorted(o["failed"]), sorted(o["warnings"]))

    found = []
    main, again, parts, merged = (paths(results[k]) for k in ("main", "again", "parts", "merged"))
    if main != again:
        found.append(failure("P5", "T0", "the same configuration gave other store paths", f"{main} and {again}", case))
    if parts != merged:
        signature = "spread over modules" + (f": {parts[1]}" if parts[0] == "error" else "")
        found.append(failure("P5", "T0", signature, f"parts {parts}, merged {merged}", case))
    return found


def probe_verdicts(case, drv, built):
    if drv not in built:
        return [failure("P4", "T1", "probe failed", drv, case)]
    out = subprocess.run(["nix-store", "--query", "--outputs", drv], check=True, capture_output=True, text=True).stdout.strip()
    observed = json.loads((pathlib.Path(out) / "probe.json").read_text())["calls"]
    planned = [c for c in case["plan"] if "call" in c]
    found = []
    for plan, call in zip(planned, observed):
        for signature, text in routing.compare(case["model"], plan["expect"], call):
            found.append(failure("P4", "T1 probe", signature, f"{plan['why']}: {text}", case) | {"call": plan["why"]})
    return found


def problem_line(log):
    """The line of a check's log that says what failed: the config check
    ends with the line that turns it off."""
    lines = [line for line in log if line.strip()]
    for i, line in enumerate(lines):
        if "checkConfig = false" in line and i > 0:
            return lines[i - 1]
    return lines[-1] if lines else ""


def normalise(text):
    """TEXT without the names and numbers of one configuration, so failures
    with one cause share a signature."""
    text = re.sub(r"/nix/store/[0-9a-z]{32}-", "/nix/store/", text)
    text = re.sub(r"\[[0-9:. -]+\]", "", text)
    # what an assertion lists after its colon, and section names
    text = re.sub(r"(\):|names[^:]*:)\s.*", r"\1 …", text, flags=re.S)
    text = re.sub(r"section \[[^]\n]*\]", "section […]", text)
    text = re.sub(r'"[^"]*"', '"…"', text)
    text = re.sub(r"\d+", "N", text)
    text = re.sub(r"(pbx-[a-z]+-)\S+", r"\1…", text)
    return " ".join(text.split())[:160]


def evaluate(campaign, name, cases_, split, rng):
    """T0 of every case, with the split entries for the ids in SPLIT; the
    results by case id and entry name."""
    jobs, where = [], []
    for case in cases_:
        for entry_name, entry in entries(case, rng, case["id"] in split):
            jobs.append(entry)
            where.append((case["id"], entry_name))
    results = t0(campaign, name, jobs)
    evaluated = {}
    for (case_id, entry_name), meta in zip(where, results):
        evaluated.setdefault(case_id, {})[entry_name] = meta
    return evaluated


def load():
    """The host's load, printed with every time a run measures."""
    return "load " + " ".join(f"{x:.1f}" for x in os.getloadavg())


def calls_of(plan):
    return [p["call"] for p in plan if "call" in p]


def run(args):
    seed = args.seed if args.seed is not None else random.randrange(2**31)
    print(f"seed {seed}, {load()}", flush=True)
    args.seed = seed
    campaign = options.Campaign(args, "configs.nix")
    began = time.monotonic()
    if args.resume:
        # the configurations and T0 of a run that was cut off; the builds it
        # finished are not done again, and the probe's calls are compared
        # with the oracle as it is now, which has to plan the same calls
        cases_ = json.loads((args.out / "cases.json").read_text())
        evaluated = json.loads((args.out / "t0.json").read_text())
        for case in cases_:
            if case["kind"] == "probe":
                plan = routing.plan(case["model"], case["seed"])
                if calls_of(plan) != calls_of(case["plan"]):
                    sys.exit(f"{case['id']}: the oracle plans other calls now; run again")
                case["plan"] = plan
    else:
        cases_ = cases(args)
        (args.out / "cases.json").write_text(json.dumps(cases_))
        print(f"{len(cases_)} configurations drawn ({time.monotonic() - began:.0f} s)", flush=True)
        rng = random.Random(seed)
        valid = [c["id"] for c in cases_ if c["kind"] == "valid"]
        split = set(rng.sample(valid, min(args.splits, len(valid))))
        evaluated = evaluate(campaign, "t0", cases_, split, rng)
        (args.out / "t0.json").write_text(json.dumps(evaluated))
    failures = verdicts(campaign, cases_, evaluated)
    report(args, seed, cases_, evaluated, failures, time.monotonic() - began)


# the provider of vm.nix, and where its secrets are
VM_PROVIDER = "10.4.0.5"
VM_SECRETS = "/run/test-secrets/"


def vm_calls(m, plan, limit):
    """The calls of PLAN the VM places, at most LIMIT: calls from phones,
    each from the extension whose caller ID the oracle used, and calls from
    the trunks at no given time, since the VM's clock is the real one; none
    of closing early, whose state would outlast the configuration."""
    calls = []
    for p in plan:
        call = p.get("call")
        if call is None or "time" in call or p.get("state"):
            continue
        # the phones there ring, as the probe's do not
        spec = {"extension": call["extension"], "limit": call["limit"] + p["expect"].get("ringing", 0) + 5}
        if call["context"] == "pbx-internal":
            spec["from"] = re.search(r"<(.*)>", call["callerId"]).group(1)
            if call.get("keys"):
                spec["keys"] = call["keys"]
        else:
            spec["trunk"] = call["context"].removeprefix("pbx-inbound-")
        # the VM does not see whether the phone's call was answered
        calls.append({"vm": spec, "expect": p["expect"] if "rejected" in p["expect"] else p["expect"] | {"answered": None}, "why": p["why"]})
    routed = [c for c in calls if "rejected" not in c["expect"]]
    rejected = [c for c in calls if "rejected" in c["expect"]]
    return (routed + rejected[:2])[:limit]


def vm(args):
    """The VM tier: configurations for vm.nix's phones and provider, the
    valid ones in VM tests of --per-test specialisations each, and every call
    compared with the oracle. Up to --parallel tests run at once, a new one
    only while the host's load stays under --max-load; a test that has its
    verdicts.json already is not run again."""
    seed = args.seed if args.seed is not None else random.randrange(2**31)
    print(f"seed {seed}, {load()}", flush=True)
    campaign = options.Campaign(args, "configs.nix")
    began = time.monotonic()
    models = draw(generate.configurations(fast=True, vm=True), args.count, seed)
    cases_ = []
    for i, m in enumerate(models):
        module = json.loads(json.dumps(generate.modules(m, host=VM_PROVIDER)).replace('"/run/secrets/', f'"{VM_SECRETS}'))
        plan = routing.plan(m, seed + i)
        cases_.append({"id": f"q{i}", "model": m, "seed": seed + i, "module": module, "calls": vm_calls(m, plan, args.calls)})
    results = t0(campaign, "vm-t0", [{"modules": [c["module"]]} for c in cases_])
    valid = [c for c, r in zip(cases_, results) if "outcome" in r and not r["outcome"]["failed"]]
    (args.out / "vm-cases.json").write_text(json.dumps(cases_))
    print(f"{len(valid)} of {len(cases_)} configurations evaluate", flush=True)
    tests = [valid[k : k + args.per_test] for k in range(0, len(valid), args.per_test)]
    pending = [n for n in range(len(tests)) if not (args.out / f"vm-{n}" / "verdicts.json").exists()]
    running = {}
    last_start = 0
    while pending or running:
        for n, (process, started) in list(running.items()):
            if process.poll() is not None:
                del running[n]
                vm_finish(tests[n], args.out / f"vm-{n}", n, process.returncode, time.monotonic() - started)
        # a test raises the load a minute or so after it starts
        if pending and len(running) < args.parallel and os.getloadavg()[0] < args.max_load and time.monotonic() - last_start > 120:
            n = pending.pop(0)
            running[n] = (vm_start(campaign, tests[n], args.out / f"vm-{n}", n), time.monotonic())
            last_start = time.monotonic()
            print(f"VM test {n} started ({load()})", flush=True)
        time.sleep(10)
    failures = [f for n in range(len(tests)) for f in json.loads((args.out / f"vm-{n}" / "verdicts.json").read_text())]
    report(args, seed, [{"kind": "vm", **c} for c in cases_], {}, failures, time.monotonic() - began)


def vm_start(campaign, batch, out, n):
    """Starts VM test N of BATCH in OUT, afresh."""
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()
    plan_file = out / "plan.json"
    plan_file.write_text(json.dumps([{"modules": [c["module"]], "extensions": sorted(c["model"]["extensions"]), "trunks": c["model"]["trunks"], "calls": [x["vm"] for x in c["calls"]]} for c in batch]))
    expression = f'import "{campaign.flake}/tests/campaign/vm.nix" {{ pkgs = (builtins.getFlake "{campaign.flake}").inputs.nixpkgs.legacyPackages.x86_64-linux; self = builtins.getFlake "{campaign.flake}"; }} {{ name = "vm-{n}"; plan = {plan_file}; }}'
    # the specialisations build one at a time too
    with open(out / "vmtest.log", "w") as log:
        return subprocess.Popen(
            [sys.executable, str(pathlib.Path(__file__).parent / "vmtest.py"), f"campaign-vm-{n}", str(out), "--expr", expression],
            env=os.environ | {"NIX_CONFIG": "max-jobs = 1"},
            stdout=log,
            stderr=subprocess.STDOUT,
        )


def vm_finish(batch, out, n, code, seconds):
    """The verdicts of VM test N, kept in OUT/verdicts.json."""
    if (out / "driver.log").exists():
        found = vm_verdicts(batch, out, n)
    else:
        found = [failure("P1", "T3", "the VM test does not build", f"exit {code}, see {out}/vmtest.log", {"id": f"vm-{n}"})]
    (out / "verdicts.json").write_text(json.dumps(found))
    print(f"VM test {n}: exit {code}, {len(found)} failures ({seconds:.0f} s, {load()})", flush=True)


def vm_verdicts(batch, out, test):
    """P4 from the log of a VM test: the steps between one marker call and
    the next are one call's."""
    log = out / "campaign.json"
    if not log.exists():
        return [failure("P4", "T3", "the VM test left no log", str(out), {"id": f"vm-{test}"})]
    windows, label = {}, None
    for message in probe.messages(log):
        step = probe.STEP.fullmatch(message["message"]) if message["file"] == "pbx.c" else None
        if step and step["where"].endswith("@campaign-mark"):
            label = step["where"].partition("@")[0].removeprefix("m")
            windows[label] = []
        elif label is not None and not (step is None and "campaign-mark" in message["message"]):
            windows[label].append(message)
    found = []
    for i, case in enumerate(batch):
        for j, call in enumerate(case["calls"]):
            window = windows.get(f"{i}-{j}")
            if window is None:
                found.append(failure("P4", "T3", "call not placed", call["why"], case))
                continue
            observed = probe.summary(call["vm"] | {"answered": None}, window)
            for signature, text in routing.compare(case["model"], call["expect"], observed):
                found.append(failure("P4", "T3", signature, f"{call['why']}: {text}", case) | {"call": call["why"], "vmTest": test})
    return found


def tollfraud(args):
    """SEC-03: every way from a trunk to a trunk's Dial, walked through the
    dialplan Asterisk loads (tollfraud.nix) in valid configurations with
    inbound numbers and calls out; each must be one the configuration names,
    and those the oracle finds in the model."""
    seed = args.seed if args.seed is not None else random.randrange(2**31)
    print(f"seed {seed}, {load()}", flush=True)
    campaign = options.Campaign(args, "configs.nix")
    began = time.monotonic()
    models = draw(generate.configurations(wide=True).filter(lambda m: m["inbound"] and m["outbound"]), args.count, seed)
    cases_ = [{"id": f"t{i}", "kind": "valid", "model": m} for i, m in enumerate(models)]
    (args.out / "cases.json").write_text(json.dumps(cases_))
    print(f"{len(cases_)} configurations drawn ({time.monotonic() - began:.0f} s)", flush=True)
    results = t0(campaign, "t0", [{"modules": [generate.modules(c["model"])], "tollfraud": True} for c in cases_])
    walks = [r["tollfraud"] for r in results if "tollfraud" in r]
    started = time.monotonic()
    built = campaign.build(walks)
    print(f"T1 walks: {len(built)} of {len(walks)} built ({time.monotonic() - started:.0f} s, {load()})", flush=True)
    failures, paths = [], []
    for case, meta in zip(cases_, results):
        if "error" in meta or meta["outcome"]["failed"]:
            text = meta.get("error") or "\n".join(meta["outcome"]["failed"])
            failures.append(failure("P2", "T0", f"rejected: {normalise(text)}", text, case))
            continue
        if meta["tollfraud"] not in built:
            failures.append(failure("SEC-03", "T1", "the walk did not run", meta["tollfraud"], case))
            continue
        out = subprocess.run(["nix-store", "--query", "--outputs", meta["tollfraud"]], check=True, capture_output=True, text=True).stdout.strip()
        walk = json.loads((pathlib.Path(out) / "report.json").read_text())
        for p in walk["paths"]:
            paths.append({"case": case["id"], **p})
            if p["finding"]:
                failures.append(failure("SEC-03", "T1", p["finding"], json.dumps(p, ensure_ascii=False), case))
        for u in walk["unresolved"]:
            failures.append(failure("SEC-03", "T1", f"not followed: {normalise(u['what'])}", json.dumps(u, ensure_ascii=False), case))
        # the named ways out against those the oracle finds in the model, so a
        # way the walk cannot follow shows too
        walked = {(p["from"], p["via"], p["number"]) for p in walk["paths"] if not p["finding"]}
        expected = routing.ways_out(case["model"])
        for way in sorted(expected - walked):
            failures.append(failure("SEC-03", "T1", "the walk missed a way out the oracle finds", json.dumps(way, ensure_ascii=False), case))
        for way in sorted(walked - expected):
            failures.append(failure("SEC-03", "T1", "the walk found a way out the oracle does not", json.dumps(way, ensure_ascii=False), case))
    (args.out / "paths.json").write_text(json.dumps(paths, indent=1, ensure_ascii=False))
    named = [p for p in paths if not p["finding"]]
    print(f"{len(paths)} ways out walked, {len(named)} named, in {len({p['case'] for p in named})} configurations", flush=True)
    report(args, seed, cases_, {}, failures, time.monotonic() - began)


def compare(args):
    """The calls of a probed case of the gate's sample against their
    predictions."""
    case = json.loads(args.case.read_text())
    calls = json.loads(args.probe.read_text())["calls"]
    problems = [f"{p['why']}: {text}" for p, call in zip(case["plan"], calls) for _, text in routing.compare(case["model"], p["expect"], call)]
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1 if problems else 0)


def sample_cases(seed, valid_count, mutants, probes, calls):
    """The configurations of the gate's sample for SEED: valid ones,
    mutations rejected at T0, and probed ones with at most CALLS calls that
    end on their own."""
    rng = random.Random(seed)
    valid = draw(generate.configurations(wide=True), valid_count, seed)
    cases_ = [{"id": f"v{i}", "kind": "valid", "model": m} for i, m in enumerate(valid)]
    # the mutations the tiers reject at T0; a time zone only the build checks
    t0_mutations = [m for m in generate.MUTATIONS if m is not generate.m_timezone]
    while sum(c["kind"] == "mutant" for c in cases_) < mutants:
        case = mutant(f"m{len(cases_)}", rng.choice(valid), rng.choice(t0_mutations).__name__, rng.randrange(2**32))
        if case:
            cases_.append(case)
    for i, m in enumerate(draw(generate.configurations(fast=True), probes, seed + 1)):
        case = probed(f"p{i}", m, seed + i)
        # in their order, and none of closing early, whose state one call leaves to the next
        quick = [p for p in case["plan"] if "call" in p and not p["expect"].get("long") and not p.get("state")]
        case["plan"] = [quick[k] for k in sorted(rng.sample(range(len(quick)), min(calls, len(quick))))]
        cases_.append(case)
    return cases_


def sample_text(args, cases_):
    """The sample file: the arguments that draw it, then a line per
    configuration."""
    entries_ = [
        {"id": c["id"], "expect": "reject" if c["kind"] == "mutant" else "accept", "modules": [generate.modules(c["model"])]}
        | ({"model": c["model"], "plan": [{"call": p["call"], "expect": p["expect"], "why": p["why"]} for p in c["plan"]]} if c["kind"] == "probe" else {})
        for c in cases_
    ]
    head = json.dumps({key: getattr(args, key) for key in SAMPLE_ARGUMENTS})[:-1]
    return head + ', "configurations": [\n' + ",\n".join(json.dumps(e, ensure_ascii=False) for e in entries_) + "\n]}\n"


# what draws a sample, recorded in its file
SAMPLE_ARGUMENTS = ["seed", "valid", "mutants", "probes", "calls"]


def sample(args):
    """Writes the gate's sample after checking it through the tiers, since
    it holds what passes today; with --check, draws the sample FILE records
    the arguments of again and compares, without Nix."""
    if args.check:
        recorded = json.loads(args.file.read_text())
        for key in SAMPLE_ARGUMENTS:
            setattr(args, key, recorded[key])
        cases_ = sample_cases(args.seed, args.valid, args.mutants, args.probes, args.calls)
        if sample_text(args, cases_) != args.file.read_text():
            command = " ".join(f"--{key} {recorded[key]}" for key in SAMPLE_ARGUMENTS)
            sys.exit(f"{args.file} is not what its arguments draw now; write it again with configs.py sample {args.file} OUT {command}")
        print(f"{args.file} is what seed {args.seed} draws")
        return
    campaign = options.Campaign(args, "configs.nix")
    cases_ = sample_cases(args.seed, args.valid, args.mutants, args.probes, args.calls)
    evaluated = evaluate(campaign, "sample", cases_, set(), random.Random(args.seed))
    failures = verdicts(campaign, cases_, evaluated)
    for f in failures:
        print(f"{f['case']}: {f['signature']}", file=sys.stderr)
    if failures:
        sys.exit("the sample holds configurations that fail today; fix them or pick another seed")
    args.file.write_text(sample_text(args, cases_))
    print(f"{len(cases_)} configurations, seed {args.seed}: {args.file}")


def size(case):
    return len(json.dumps(case["model"]))


def shrink(args):
    """The smallest configuration that still fails with a signature: each
    round tries every model one step smaller at once and keeps the smallest
    that still fails, until none does."""
    campaign = options.Campaign(args, "configs.nix")
    report_ = json.loads((args.out / "report.json").read_text())
    all_cases = {c["id"]: c for c in json.loads((args.out / "cases.json").read_text())}
    signature = next(s for s in report_["signatures"] if s.startswith(args.signature))
    ids = report_["signatures"][signature]["cases"]
    current = all_cases[args.case] if args.case else min((all_cases[i] for i in ids), key=size)
    split = signature.startswith("P5")
    print(f"shrinking {current['id']} ({size(current)} bytes) for {signature}", flush=True)
    for round_ in range(1, 200):
        base = current["base"] if current["kind"] == "mutant" else current["model"]
        candidates = []
        for smaller in generate.reductions(base):
            case_id = f"s{round_}-{len(candidates)}"
            if current["kind"] == "mutant":
                candidate = mutant(case_id, smaller, current["mutation"], current["seed"])
            elif current["kind"] == "probe":
                candidate = probed(case_id, smaller, current["seed"])
            else:
                candidate = {"id": case_id, "kind": current["kind"], "model": smaller}
            if candidate:
                candidates.append(candidate)
        evaluated = evaluate(campaign, f"shrink{round_}", candidates, {c["id"] for c in candidates} if split else set(), random.Random(0))
        failing = {f["case"] for f in verdicts(campaign, candidates, evaluated) if f["signature"] == signature}
        hits = [c for c in candidates if c["id"] in failing]
        print(f"round {round_}: {len(hits)} of {len(candidates)} smaller ones still fail", flush=True)
        if not hits:
            break
        current = min(hits, key=size)
    shrunk = args.out / "shrunk"
    shrunk.mkdir(exist_ok=True)
    name = re.sub(r"[^A-Za-z0-9]+", "-", signature)[:80].strip("-")
    result = current | {"signature": signature, "modules": [generate.modules(current["model"])]}
    (shrunk / f"{name}.json").write_text(json.dumps(result, indent=1))
    print(f"{size(current)} bytes: {shrunk / name}.json")
    print(json.dumps(result["modules"], indent=1))


def report(args, seed, cases_, evaluated, failures, seconds):
    by = {}
    for f in failures:
        by.setdefault(f["signature"], []).append(f)
    kinds = sorted({c["kind"] for c in cases_})
    summary = {
        "seed": seed,
        "seconds": round(seconds),
        "configurations": {kind: sum(c["kind"] == kind for c in cases_) for kind in kinds},
        "calls": sum(sum("call" in p for p in c.get("plan", [])) + len(c.get("calls", [])) for c in cases_),
        "skipped calls": sum(sum("skipped" in p for p in c.get("plan", [])) for c in cases_),
        "mutations rejected at T0": sum(
            "error" in evaluated[c["id"]]["main"] or bool(evaluated[c["id"]]["main"]["outcome"]["failed"]) for c in cases_ if c["kind"] == "mutant"
        ),
        "T1 run": not args.no_t1,
        "signatures": {s: {"count": len(fs), "cases": [f["case"] for f in fs[:20]], "first": fs[0]} for s, fs in sorted(by.items(), key=lambda x: -len(x[1]))},
    }
    (args.out / "report.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps({k: v for k, v in summary.items() if k != "signatures"}))
    for s, v in summary["signatures"].items():
        print(f"{v['count']:6} {s}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("out", type=pathlib.Path)
    r.add_argument("--seed", type=int)
    r.add_argument("--count", type=int, default=7000)
    r.add_argument("--mutants", type=int, default=3000)
    r.add_argument("--probes", type=int, default=2000)
    r.add_argument("--splits", type=int, default=2000)
    r.add_argument("--resume", action="store_true", help="build and report what OUT's configurations and T0 left")
    s = sub.add_parser("shrink")
    s.add_argument("out", type=pathlib.Path)
    s.add_argument("signature", help="the start of a signature of OUT/report.json")
    s.add_argument("--case", help="the case to shrink; the smallest of the signature without it")
    v = sub.add_parser("vm")
    v.add_argument("out", type=pathlib.Path)
    v.add_argument("--seed", type=int)
    v.add_argument("--count", type=int, default=500)
    v.add_argument("--per-test", type=int, default=25, help="configurations per VM test")
    v.add_argument("--calls", type=int, default=6, help="calls per configuration")
    v.add_argument("--parallel", type=int, default=1, help="VM tests at once")
    v.add_argument("--max-load", type=float, default=16, help="the load under which another VM test starts")
    g = sub.add_parser("sample")
    g.add_argument("file", type=pathlib.Path)
    g.add_argument("out", type=pathlib.Path, nargs="?", help="where the evaluations and builds of the check go")
    g.add_argument("--check", action="store_true", help="draw FILE again from the arguments it records, and compare")
    g.add_argument("--seed", type=int, default=1)
    g.add_argument("--valid", type=int, default=6)
    g.add_argument("--mutants", type=int, default=42)
    g.add_argument("--probes", type=int, default=2)
    g.add_argument("--calls", type=int, default=8, help="calls per probed configuration")
    t = sub.add_parser("tollfraud")
    t.add_argument("out", type=pathlib.Path)
    t.add_argument("--seed", type=int)
    t.add_argument("--count", type=int, default=2000)
    c = sub.add_parser("compare")
    c.add_argument("case", type=pathlib.Path)
    c.add_argument("probe", type=pathlib.Path)
    for p in [r, s, v, g, t]:
        p.add_argument("--no-t1", action="store_true", help="evaluate only")
        p.add_argument("--flake", default=".")
        p.add_argument("--workers", type=int, default=2)
        p.add_argument("--max-memory", type=int, default=1800, help="MiB per evaluation worker")
        p.add_argument("--jobs", type=int, default=6, help="builds at once")
        p.add_argument("--chunk", type=int, default=1000, help="configurations per nix-eval-jobs run")
    args = parser.parse_args()
    if getattr(args, "out", None):
        args.out = args.out.resolve()
        args.out.mkdir(parents=True, exist_ok=True)
        # what Hypothesis keeps between runs goes with the run, not the tree
        hypothesis.configuration.set_hypothesis_home_dir(args.out / "hypothesis")
    elif args.command == "sample":
        if not args.check:
            parser.error("sample needs OUT, or --check")
        hypothesis.configuration.set_hypothesis_home_dir(tempfile.mkdtemp())
    {"run": run, "shrink": shrink, "vm": vm, "sample": sample, "tollfraud": tollfraud, "compare": compare}[args.command](args)


if __name__ == "__main__":
    main()
