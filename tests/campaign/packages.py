#!/usr/bin/env python3
"""Run the checks with each Asterisk package of nixpkgs, or on another nixpkgs.

    packages.py OUT [--package NAME]... [--nixpkgs REF] [--vm] [--flake DIR]

Builds .#packageChecks.NAME.CHECK (tests/packages.nix) for every check of the
gate and each NAME, by default every package there; the name `default` builds
.#checks.x86_64-linux.CHECK, with the package nixpkgs' asterisk points to.
--nixpkgs builds them on another nixpkgs through --override-input, resolved
to one revision first, so every build uses the same one. VM tests only run
with --vm. One check builds at a time, with its log in OUT/NAME/CHECK.log;
OUT/summary.tsv has the result and seconds of each, and the exit code is 1
if any failed.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time


def names(attribute, override):
    return json.loads(
        subprocess.run(
            ["nix", "eval", "--json", *override, attribute, "--apply", "builtins.attrNames"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--package", action="append", dest="packages")
    parser.add_argument("--nixpkgs")
    parser.add_argument("--vm", action="store_true")
    parser.add_argument("--flake", default=".")
    parser.add_argument("--max-jobs", default="2")
    args = parser.parse_args()

    override = []
    if args.nixpkgs:
        metadata = subprocess.run(
            ["nix", "flake", "metadata", "--json", args.nixpkgs], check=True, capture_output=True, text=True
        ).stdout
        locked = json.loads(metadata)["url"]
        print(f"nixpkgs: {locked}", flush=True)
        override = ["--override-input", "nixpkgs", locked]
    build = ["nix", "build", "--no-link", "--max-jobs", args.max_jobs, *override]

    available = names(f"{args.flake}#packageChecks", override)
    # the gate's sample of this sweep, checks named after their package
    sample = tuple(f"-{name}" for name in available)
    checks = names(f"{args.flake}#checks.x86_64-linux", override)
    if not args.vm:
        checks = [check for check in checks if not check.startswith("vm-")]

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    failed = []
    with open(out / "summary.tsv", "w") as summary:
        for package in args.packages or available:
            (out / package).mkdir(exist_ok=True)
            if package == "default":
                attributes = "checks.x86_64-linux"
                selected = checks
            else:
                attributes = f"packageChecks.{package}"
                selected = [check for check in checks if not check.endswith(sample)]
            for check in selected:
                start = time.monotonic()
                with open(out / package / f"{check}.log", "wb") as log:
                    code = subprocess.run(
                        [*build, f"{args.flake}#{attributes}.{check}"], stdout=log, stderr=subprocess.STDOUT
                    ).returncode
                result = "passed" if code == 0 else "failed"
                seconds = time.monotonic() - start
                summary.write(f"{package}\t{check}\t{result}\t{seconds:.1f}\n")
                summary.flush()
                print(f"{package} {check}: {result} ({seconds:.0f} s)", flush=True)
                if code != 0:
                    failed.append(f"{package} {check}")
    if failed:
        print("failed: " + ", ".join(failed))
    print(f"logs in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
