#!/usr/bin/env python3
"""How evaluation and the config check grow with the size of a pbx
(scale.nix), with and without direct dial in its menus:

    scale.py OUT [--flake DIR] [--sizes 50,100,250,500] [--repeat 2]

For each size it evaluates the whole system (its toplevel's derivation) with
the evaluator's statistics (NIX_SHOW_STATS) and its peak memory, then builds
the inputs of the system's config check and times the check itself, which
boots Asterisk on the configuration. OUT gets results.json with every run.
For each measure it prints the smallest value of the repeats at each size and
what each step between two sizes adds per 100 extensions: about the same from
step to step when the measure grows linearly, more and more when it grows
faster. The evaluator's counts of function calls and thunks are the same on
every run, so they show the growth without the noise of the timings.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

MEASURES = [
    "evalSeconds",
    "evalCpuSeconds",
    "evalMaxRssMiB",
    "evalAllocatedMiB",
    "evalFunctionCalls",
    "evalThunks",
    "evalUpdateCopies",
    "checkBuildSeconds",
]


def expression(flake, size, direct_dial, attribute):
    """A Nix expression for `attribute` of the system of this size, where
    `config` is the system and `evalLib` tests/eval-lib.nix."""
    return (
        f"let self = builtins.getFlake {json.dumps(flake)}; "
        f"pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux; "
        f"config = import {json.dumps(flake + '/tests/campaign/scale.nix')} {{ inherit self; }} "
        f"{{ size = {size}; directDial = {'true' if direct_dial else 'false'}; }}; "
        f"evalLib = import {json.dumps(flake + '/tests/eval-lib.nix')} {{ inherit self pkgs; }}; "
        f"in {attribute}"
    )


def measure(flake, size, direct_dial, check):
    with tempfile.TemporaryDirectory() as scratch:
        stats = pathlib.Path(scratch) / "stats.json"
        env = os.environ | {"NIX_SHOW_STATS": "1", "NIX_SHOW_STATS_PATH": str(stats)}
        command = ["nix", "eval", "--impure", "--raw", "--expr"]
        command.append(expression(flake, size, direct_dial, "config.system.build.toplevel.drvPath"))
        start = time.monotonic()
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, text=True)
        stderr = process.stderr.read()
        # the rusage of this child alone, for its peak memory
        _, status, usage = os.wait4(process.pid, 0)
        seconds = time.monotonic() - start
        if status:
            raise RuntimeError(f"the evaluation of size {size} failed:\n{stderr}")
        evaluation = json.loads(stats.read_text()) if stats.exists() else {}
    # the derivations of the check and of its inputs, then the builds of both
    derivations = []
    for attribute in ("inputDerivation.drvPath", "drvPath") if check else ():
        command = ["nix", "eval", "--impure", "--raw", "--expr"]
        command.append(expression(flake, size, direct_dial, f"(evalLib.configCheckOf config).{attribute}"))
        derivations.append(subprocess.run(command, capture_output=True, text=True, check=True).stdout)
    build_seconds = None
    for derivation in derivations:
        built = subprocess.run(["nix-store", "--realise", derivation], capture_output=True, text=True)
        if built.returncode:
            raise RuntimeError(f"the config check of size {size} failed:\n{built.stderr}")
    if derivations:
        # built again, so a check an earlier run built takes as long
        start = time.monotonic()
        subprocess.run(["nix-store", "--realise", "--check", derivations[-1]], capture_output=True, check=True)
        build_seconds = time.monotonic() - start
    return {
        "size": size,
        "directDial": direct_dial,
        "evalSeconds": round(seconds, 2),
        "evalMaxRssMiB": round(usage.ru_maxrss / 1024),
        "evalCpuSeconds": evaluation.get("cpuTime"),
        "evalAllocatedMiB": round(evaluation.get("gc", {}).get("totalBytes", 0) / 2**20),
        "evalFunctionCalls": evaluation.get("nrFunctionCalls"),
        "evalThunks": evaluation.get("nrThunks"),
        "evalUpdateCopies": evaluation.get("nrOpUpdateValuesCopied"),
        # the check alone, its inputs built
        "checkBuildSeconds": None if build_seconds is None else round(build_seconds, 2),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--sizes", default="50,100,250,500")
    parser.add_argument("--repeat", type=int, default=2)
    args = parser.parse_args()
    flake = str(pathlib.Path(args.flake).resolve())
    sizes = sorted(int(s) for s in args.sizes.split(","))
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    for direct_dial in (False, True):
        for size in sizes:
            for attempt in range(args.repeat):
                # the config check is built once; a repeat would find it built
                result = measure(flake, size, direct_dial, check=attempt == 0)
                print(json.dumps(result), flush=True)
                results.append(result)
    (args.out / "results.json").write_text(json.dumps(results, indent=1) + "\n")
    for direct_dial in (False, True):
        print(f"directDial = {str(direct_dial).lower()}")
        runs = [r for r in results if r["directDial"] == direct_dial]
        for name in MEASURES:
            best = {}
            for r in runs:
                if r[name] is not None:
                    best[r["size"]] = min(best.get(r["size"], r[name]), r[name])
            steps = sorted(best.items())
            added = [
                f"{a}-{b}: {(vb - va) * 100 / (b - a):.3g}" for (a, va), (b, vb) in zip(steps, steps[1:])
            ]
            print(f"  {name}: {dict(steps)}; per 100 extensions {', '.join(added)}")


if __name__ == "__main__":
    sys.exit(main())
