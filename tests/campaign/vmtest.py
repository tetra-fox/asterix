#!/usr/bin/env python3
"""Run one VM test outside the nix sandbox and keep what it leaves behind.

    vmtest.py CHECK OUT [--flake DIR] [--memory 6G] [--interactive]

Builds .#checks.x86_64-linux.CHECK.driver and runs it as this user, in a
network namespace with no uplink and a systemd scope capped at --memory, so
running out of memory kills the test and not the session. OUT keeps the
driver's log (every node's console and journal), junit.xml, and each node's
pcaps under rt/vm-state-<node>/. The exit code is the driver's.
"""

import argparse
import pathlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("check")
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--memory", default="6G")
    parser.add_argument("--interactive", action="store_true")
    args = parser.parse_args()

    attribute = "driverInteractive" if args.interactive else "driver"
    driver = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", f"{args.flake}#checks.x86_64-linux.{args.check}.{attribute}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    out = args.out.resolve()
    # the driver keeps VM disks and sockets here; a path of its own, on disk,
    # keeps two runs apart and the sockets under the 108 byte limit
    runtime = out / "rt"
    runtime.mkdir(parents=True, exist_ok=True)
    command = [
        "systemd-run", "--user", "--scope", "--quiet", "-p", f"MemoryMax={args.memory}",
        # systemd-run needs the real XDG_RUNTIME_DIR to reach the user bus
        "env", f"XDG_RUNTIME_DIR={runtime}",
        "unshare", "--map-root-user", "--net",
        f"{driver}/bin/nixos-test-driver", "--output_directory", str(out),
    ]
    if args.interactive:
        code = subprocess.run(command).returncode
    else:
        with open(out / "driver.log", "wb") as log:
            code = subprocess.run(command + ["--junit-xml", "junit.xml"], stdout=log, stderr=subprocess.STDOUT).returncode
    # the disk images are large and say nothing the log and pcaps don't
    for image in runtime.glob("vm-state-*/*.qcow2"):
        image.unlink()
    print(f"{args.check}: {'passed' if code == 0 else f'failed ({code})'}, evidence in {out}")
    return code


if __name__ == "__main__":
    sys.exit(main())
