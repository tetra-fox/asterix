#!/usr/bin/env python3
"""Run one VM test outside the nix sandbox and keep what it leaves behind.

    vmtest.py CHECK OUT [--flake DIR] [--expr EXPR] [--memory 6G] [--interactive]

Builds .#checks.x86_64-linux.CHECK.driver, or with --expr the driver of the
test EXPR evaluates to (impure; CHECK then only names the run), and runs it
as this user, in a network namespace with no uplink and a systemd scope
capped at --memory, so running out of memory kills the test and not the
session. OUT keeps the driver's log (every node's console and journal),
junit.xml, and each node's pcaps under rt/vm-state-<node>/. The exit code is
the driver's.
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("check")
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--expr")
    parser.add_argument("--memory", default="6G")
    parser.add_argument("--interactive", action="store_true")
    args = parser.parse_args()

    attribute = "driverInteractive" if args.interactive else "driver"
    if args.expr:
        installable = ["--impure", "--expr", f"({args.expr}).{attribute}"]
    else:
        installable = [f"{args.flake}#checks.x86_64-linux.{args.check}.{attribute}"]
    driver = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", *installable],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    out = args.out.resolve()
    kept = out / "rt"
    kept.mkdir(parents=True, exist_ok=True)
    # the driver keeps VM disks and sockets in a new directory of the
    # temporary directory, apart from other runs: vde_switch binds the real
    # path of its socket, which has to fit the 108 bytes of sun_path
    runtime = pathlib.Path(tempfile.mkdtemp(prefix="vmtest-"))
    command = [
        "systemd-run", "--user", "--scope", "--quiet", "-p", f"MemoryMax={args.memory}",
        # systemd-run needs the real XDG_RUNTIME_DIR to reach the user bus
        "env", f"XDG_RUNTIME_DIR={runtime}",
        "unshare", "--map-root-user", "--net",
        f"{driver}/bin/nixos-test-driver", "--output_directory", str(out),
    ]
    try:
        if args.interactive:
            code = subprocess.run(command).returncode
        else:
            with open(out / "driver.log", "wb") as log:
                code = subprocess.run(command + ["--junit-xml", "junit.xml"], stdout=log, stderr=subprocess.STDOUT).returncode
    finally:
        # each node's pcaps go to OUT/rt/vm-state-<node>/; the disk images are
        # large and say nothing the log and pcaps don't
        for state in runtime.glob("vm-state-*"):
            for path in state.iterdir():
                if path.is_file() and path.suffix != ".qcow2":
                    (kept / state.name).mkdir(exist_ok=True)
                    shutil.move(path, kept / state.name / path.name)
        shutil.rmtree(runtime)
    print(f"{args.check}: {'passed' if code == 0 else f'failed ({code})'}, evidence in {out}")
    return code


if __name__ == "__main__":
    sys.exit(main())
