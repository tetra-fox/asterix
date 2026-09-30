#!/usr/bin/env python3
"""The environment matrix: covering arrays over the environments asterix runs
in, whose rows tests/vm/matrix.nix calls through.

    matrix.py generate [--seed 1] [--pairwise-pbxs-per-test 10]
                       [--three-wise-pbxs-per-test 4]
    matrix.py run OUT [--rows three-wise] [--test NAME]... [--flake DIR]
                      [--memory 16G]

`generate` writes matrix-pairwise.json next to this script, rows that hold
every pair of levels of LEVELS on the pinned nixpkgs (the gate's vm-matrix-N
checks), and matrix-three-wise.json, rows that hold every triple (the
campaign's), both from the seed. A row is one call script (tests/vm/matrix.nix)
between phones of the row's transport, codecs, DTMF mode, NAT and kind of
secret, registered with a pbx of the row's Asterisk package, nixpkgs, IP
family, host networking and firewall. Rows that share those share a pbx, and
a few pbxs share a VM test. The pbxs come from a covering array of their own,
so there are few of them. A row that meets a bug of KNOWN checks what the bug
does instead, and the other rows hold every tuple on their own too.

`run` builds the drivers of a row file's VM tests from
tests/campaign/matrix.nix, with nixos-unstable resolved to one revision
first, then runs them with vmtest.py one at a time, each with its evidence
in OUT/NAME. OUT/results.json gets the commit and diff they were built from,
that revision, and each test's result, seconds and failed rows.
"""

import argparse
import hashlib
import json
import pathlib
import random
import re
import subprocess
import sys
import time
from itertools import combinations, product

HERE = pathlib.Path(__file__).resolve().parent

LEVELS = {
    "package": ["asterisk_20", "asterisk_22", "asterisk_23"],
    "nixpkgs": ["nixos-26.05", "nixos-unstable"],
    "ip": ["ipv4", "ipv6", "dual"],
    "networking": ["scripted", "networkd"],
    "firewall": ["iptables", "nftables"],
    "nat": ["none", "pbx", "phones", "both"],
    "transport": ["udp", "tcp", "tls", "ws", "wss"],
    "codecs": ["same", "ulaw-alaw", "ulaw-g722", "g722-g722"],
    "dtmf": ["rfc4733", "inband", "info", "auto", "auto_info"],
    "secrets": ["sops-nix", "files", "credentials"],
}
# what a pbx node fixes: the rows on it vary the rest. behind-nat is whether
# the pbx sits behind a router (nat pbx or both)
PBX = ["package", "nixpkgs", "ip", "networking", "firewall", "behind-nat"]

# Combinations the matrix leaves out on purpose, each with why: a row is left
# out when each dimension named holds one of the levels given.
CONSTRAINTS = [
    {
        "why": "inband DTMF only between G.711 phones: Asterisk hears keys sent as tones only in ulaw and alaw calls, and the evaluation warns about an inband endpoint that allows g722 (F135)",
        "levels": {"dtmf": ["inband"], "codecs": ["ulaw-g722", "g722-g722"]},
    },
]
# Combinations that meet a bug outside asterix, matched like CONSTRAINTS.
# Their rows stay in the matrix and check what the bug does today instead of
# running the call script, so they fail once it is fixed.
KNOWN = [
    {
        "bug": "websocket",
        "why": "the SDP Asterisk sends over WebSocket names its host's IPv4 address, private behind NAT and of the other family for IPv6 phones (F50), and its Contact is one the client cannot reach (F51)",
        "levels": {"transport": ["ws", "wss"]},
    },
    {
        "bug": "tcp6-nat",
        "why": "a pbx behind NAT leaves its external address out of what it sends over TCP and TLS on IPv6 to endpoints that name no transport, as the matrix's: res_pjsip_nat finds such a transport only through one the endpoint names (res/res_pjsip_nat.c:328, res/res_pjsip.c:653-671)",
        "levels": {"transport": ["tcp", "tls"], "ip": ["ipv6", "dual"], "nat": ["pbx", "both"]},
    },
]
# a covering array takes the best row of this many candidates each time
CANDIDATES = 30


def behind_nat(nat):
    return nat in ("pbx", "both")


def matches(row, levels):
    return all(row.get(name) in values for name, values in levels.items())


def known(row):
    return next((bug["bug"] for bug in KNOWN if matches(row, bug["levels"])), None)


def allowed(row, pbxs, avoid=()):
    """Whether a row, or the dimensions of one set so far, meets no
    constraint and nothing of `avoid`, and its pbx dimensions are one of
    `pbxs`."""
    if any(matches(row, entry["levels"]) for entry in CONSTRAINTS + list(avoid)):
        return False
    if pbxs is None:
        return True
    projection = {name: row[name] for name in PBX[:-1] if name in row}
    if "nat" in row:
        projection["behind-nat"] = behind_nat(row["nat"])
    return any(all(pbx[name] == value for name, value in projection.items()) for pbx in pbxs)


def covering(names, levels, strength, rng, allow, rows=()):
    """Rows over `names` that, with `rows`, hold every `strength`-tuple of
    levels a row `allow` takes can hold. Each row starts from a tuple none
    holds yet and takes, one dimension at a time in a random order, the level
    that completes the most tuples (AETG). allpairspy, in the pin, stops at
    the first row that adds no tuple, which leaves tuples out here."""

    def completable(row):
        if not allow(row):
            return False
        for name in names:
            if name not in row:
                return any(completable({**row, name: value}) for value in levels[name])
        return True

    wanted = set()
    for combo in combinations(names, strength):
        for values in product(*(levels[name] for name in combo)):
            if completable(dict(zip(combo, values))):
                wanted.add(tuple(zip(combo, values)))

    def held(row):
        return {tuple((name, row[name]) for name in combo) for combo in combinations(names, strength)}

    for row in rows:
        wanted -= held(row)
    out = []
    while wanted:
        start = sorted(wanted)
        best = None
        for _ in range(CANDIDATES):
            row = dict(rng.choice(start))
            for name in rng.sample(names, len(names)):
                if name in row:
                    continue
                options = [value for value in levels[name] if completable({**row, name: value})]
                others = [n for n in names if n in row]

                def gain(value):
                    trial = {**row, name: value}
                    return sum(
                        tuple((n, trial[n]) for n in names if n in combo) in wanted
                        for combo in combinations(others + [name], strength)
                        if name in combo
                    )

                gains = {value: gain(value) for value in options}
                top = max(gains.values())
                row[name] = rng.choice([value for value in options if gains[value] == top])
            score = len(held(row) & wanted)
            if best is None or score > best[0]:
                best = (score, row)
        out.append(best[1])
        wanted -= held(best[1])
    return out


def generate(strength, nixpkgs, seed, per_test, prefix, ids):
    rng = random.Random(f"{seed}:{strength}")
    levels = dict(LEVELS, nixpkgs=nixpkgs, **{"behind-nat": [False, True]})
    pbxs = covering(PBX, levels, min(strength, len(PBX)), rng, lambda row: True)
    names = list(LEVELS)
    rows = covering(names, levels, strength, rng, lambda row: allowed(row, pbxs))
    # the rows no bug stops hold every tuple of the call script
    rows += covering(names, levels, strength, rng, lambda row: allowed(row, pbxs, KNOWN), [row for row in rows if not known(row)])

    # a pbx for each set of pbx levels the rows have, the pbxs of one nixpkgs
    # in as few tests of at most `per_test` as there can be, of even sizes
    keys = []
    for row in rows:
        key = tuple(row[name] for name in PBX[:-1]) + (behind_nat(row["nat"]),)
        if key not in keys:
            keys.append(key)
    tests = []
    for version in nixpkgs:
        mine = [key for key in keys if key[1] == version]
        count = -(-len(mine) // per_test)
        for i in range(count):
            chunk = mine[i * len(mine) // count : (i + 1) * len(mine) // count]
            tests.append({
                "name": f"{prefix}-{len(tests) + 1}",
                "nixpkgs": version,
                "pbxs": [
                    {"name": f"pbx{i + 1}", **{name: value for name, value in zip(PBX, key) if name != "nixpkgs"}}
                    for i, key in enumerate(chunk)
                ],
                "rows": [],
            })
            for i, key in enumerate(chunk):
                for row in rows:
                    if tuple(row[name] for name in PBX[:-1]) + (behind_nat(row["nat"]),) == key:
                        tests[-1]["rows"].append({
                            "pbx": f"pbx{i + 1}",
                            **{name: row[name] for name in names if name not in PBX},
                            "known": known(row),
                        })
    number = 0
    for test in tests:
        for row in test["rows"]:
            number += 1
            row["id"] = f"{ids}{number:03d}"
    return {
        "generator": "tests/campaign/matrix.py generate",
        "seed": seed,
        "strength": strength,
        "levels": {name: nixpkgs if name == "nixpkgs" else values for name, values in LEVELS.items()},
        "constraints": [constraint["why"] for constraint in CONSTRAINTS],
        "known": {bug["bug"]: bug["why"] for bug in KNOWN},
        "tests": tests,
    }


def write(path, data):
    path.write_text(json.dumps(data, indent=1) + "\n")
    rows = sum(len(test["rows"]) for test in data["tests"])
    pbxs = sum(len(test["pbxs"]) for test in data["tests"])
    print(f"{path.name}: {rows} rows, {pbxs} pbxs, {len(data['tests'])} tests")


def commit(flake):
    """The commit the tree is at, and a hash of what differs from it"""
    head = subprocess.run(["git", "-C", flake, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    diff = subprocess.run(["git", "-C", flake, "diff", "HEAD"], check=True, capture_output=True).stdout
    return {"commit": head, "diff": hashlib.sha256(diff).hexdigest() if diff else None}


def run(args):
    data = json.loads((HERE / f"matrix-{args.rows}.json").read_text())
    tests = [test for test in data["tests"] if not args.test or test["name"] in args.test]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    flake = str(pathlib.Path(args.flake).resolve())
    metadata = subprocess.run(
        ["nix", "flake", "metadata", "--json", "github:NixOS/nixpkgs/nixos-unstable"], check=True, capture_output=True, text=True
    ).stdout
    unstable = json.loads(metadata)["url"]
    results = {**commit(flake), "unstable": unstable, "rows": args.rows, "tests": {}}
    # every driver is built before the first runs, so they all come from the
    # tree the commit above names, whatever changes in it meanwhile
    drivers = {}
    for test in tests:
        (out / test["name"]).mkdir(exist_ok=True)
        expr = f'(import {HERE}/matrix.nix {{ flake = {flake}; rows = "{args.rows}"; unstable = "{unstable}"; }}).{test["name"]}.driver'
        build = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", "--impure", "--expr", expr], capture_output=True, text=True)
        (out / test["name"] / "build.log").write_text(build.stderr)
        if build.returncode == 0:
            drivers[test["name"]] = build.stdout.strip()
        print(f"{test['name']}: {drivers.get(test['name'], 'the driver did not build')}", flush=True)
    vmtest = HERE / "vmtest.py"
    for test in tests:
        entry = results["tests"][test["name"]] = {
            "nixpkgs": test["nixpkgs"],
            "rows": [row["id"] for row in test["rows"]],
            "result": "not built",
        }
        if test["name"] in drivers:
            start = time.monotonic()
            code = subprocess.run([
                sys.executable, str(vmtest), test["name"], str(out / test["name"]),
                "--expr", f'{{ driver = builtins.storePath "{drivers[test["name"]]}"; }}', "--memory", args.memory,
            ]).returncode
            log = (out / test["name"] / "driver.log").read_text(errors="replace")
            entry.update({
                "result": "passed" if code == 0 else "failed",
                "seconds": round(time.monotonic() - start),
                "failed": sorted(set(re.findall(r"row (\S+) failed: ", log))),
            })
        (out / "results.json").write_text(json.dumps(results, indent=1) + "\n")
        print(f"{test['name']}: {entry['result']} ({entry.get('seconds', 0)} s) {' '.join(entry.get('failed', []))}", flush=True)
    return 0 if all(test["result"] == "passed" for test in results["tests"].values()) else 1


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    gen = commands.add_parser("generate")
    gen.add_argument("--seed", type=int, default=1)
    # the gate's pbxs share one test, since starting a test costs more than
    # a row; the campaign's run a few to a test, which keeps a failed test small
    gen.add_argument("--pairwise-pbxs-per-test", type=int, default=10)
    gen.add_argument("--three-wise-pbxs-per-test", type=int, default=4)
    runner = commands.add_parser("run")
    runner.add_argument("out", type=pathlib.Path)
    runner.add_argument("--rows", default="three-wise", choices=["pairwise", "three-wise"])
    runner.add_argument("--test", action="append")
    runner.add_argument("--flake", default=".")
    runner.add_argument("--memory", default="16G")
    args = parser.parse_args()
    if args.command == "generate":
        write(HERE / "matrix-pairwise.json", generate(2, ["nixos-26.05"], args.seed, args.pairwise_pbxs_per_test, "matrix", "p"))
        write(HERE / "matrix-three-wise.json", generate(3, LEVELS["nixpkgs"], args.seed, args.three_wise_pbxs_per_test, "three-wise", "t"))
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
