#!/usr/bin/env python3
"""The opening hours oracle: whether pbx.hours is open at an instant, as the
descriptions of its options say, against what its pbx-hours-<name> routine
returns for that instant in the T1 probe (hours.nix).

    hours.py plan HOURS ZONEINFO OUT --chunk CHUNK [--sample N] [--seed S]
    hours.py check HOURS ZONEINFO PLAN PROBE OUT
    hours.py sweep OUT [--flake DIR] [--zones-per-boot 3] [--jobs 2]

HOURS is pbx.hours as JSON. `plan` picks instants for each of them in
WINDOW: around the changes of offset of its zone, and on every day, the edges
of each range and of the day, in local time. With --sample it keeps N of them
picked by the seed, half on the days of a change of offset, a holiday or a
leap day. OUT gets sweep.conf, the context hours-sweep, whose extensions s0,
s1 and on run the routine at CHUNK instants each with TESTTIME, and
early-<name> and reopened-<name> at EARLY instants of each hours with
closeEarly, for the probe to call while it is on and once it is off again;
and plan.json, the instants of each extension.

`check` compares what the probe logged with the oracle, which reads the zone
files of ZONEINFO, the tzdata whose files the routine's GotoIfTime names.
OUT gets report.json: the number of instants that agree, each one that does
not, with `known` set to F11 where GotoIfTime did what F11 records (an
overnight range on given days, whose time and weekday it checks
separately), and `problems`: a zone file of another tzdata, results the log
lacks, and messages the logger dropped.

`sweep` runs every instant, a few zones to a boot, and writes each report
and a summary to OUT.
"""

import argparse
import datetime
import json
import pathlib
import random
import re
import subprocess
import sys
import time
import zoneinfo

WINDOW = (
    datetime.datetime(2026, 10, 1, tzinfo=datetime.UTC),
    datetime.datetime(2028, 10, 1, tzinfo=datetime.UTC),
)
DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
LEAP_DAYS = [datetime.date(2027, 2, 28), datetime.date(2027, 3, 1), datetime.date(2028, 2, 28),
             datetime.date(2028, 2, 29), datetime.date(2028, 3, 1)]
# the instants the close-early sweeps run, per hours with closeEarly
EARLY = 12


def weekdays(days):
    """`days` as a set of weekday numbers, Monday 0: `*`, `mon-fri`, `sat`,
    `mon&wed`; a range from a later day to an earlier one goes round the week."""
    if days == "*":
        return set(range(7))
    result = set()
    for part in days.split("&"):
        first, _, last = part.partition("-")
        start = DAYS.index(first)
        end = DAYS.index(last or first)
        result.update((start + i) % 7 for i in range((end - start) % 7 + 1))
    return result


def minutes(clock):
    hour, minute = clock.split(":")
    return int(hour) * 60 + int(minute)


def holidays(dates):
    """`mon day` and `mon first-last` as a set of (month, day)."""
    result = set()
    for date in dates:
        month, _, span = date.partition(" ")
        first, _, last = span.partition("-")
        result.update((MONTHS.index(month) + 1, day) for day in range(int(first), int(last or first) + 1))
    return result


class Hours:
    def __init__(self, options, zone):
        self.options = options
        self.zone = zone
        self.ranges = []
        for opening in options["open"]:
            start, end = opening["time"].split("-")
            self.ranges.append((weekdays(opening["days"]), minutes(start), minutes(end)))
        self.holidays = holidays(options.get("holidays", []))

    def local(self, epoch):
        return datetime.datetime.fromtimestamp(epoch, self.zone)

    def open(self, epoch):
        """Open or closed at `epoch` as the options describe it: `time` is
        opening hours of `days` in `timezone` up to the end of its last minute,
        so an overnight range opens on those days and closes the morning
        after; a holiday is closed whatever `open` says."""
        local = self.local(epoch)
        if (local.month, local.day) in self.holidays:
            return False
        minute = local.hour * 60 + local.minute
        today = local.weekday()
        yesterday = (today - 1) % 7
        for days, start, end in self.ranges:
            if start <= end:
                if today in days and start <= minute <= end:
                    return True
            elif (today in days and minute >= start) or (yesterday in days and minute <= end):
                return True
        return False

    def f11(self, epoch):
        """Open or closed as F11 records GotoIfTime: the weekday and the time
        checked separately, so an overnight range opens on its days before
        its end and after its start."""
        local = self.local(epoch)
        if (local.month, local.day) in self.holidays:
            return False
        minute = local.hour * 60 + local.minute
        return any(
            local.weekday() in days and ((start <= minute <= end) if start <= end else (minute >= start or minute <= end))
            for days, start, end in self.ranges
        )

    def changes(self):
        """The instants in WINDOW at which the zone's offset changes."""
        result = []
        start, end = (int(w.timestamp()) for w in WINDOW)
        offset = self.local(start).utcoffset()
        for hour in range(start + 3600, end + 1, 3600):
            if self.local(hour).utcoffset() != offset:
                low, high = hour - 3600, hour
                while high - low > 1:
                    middle = (low + high) // 2
                    if self.local(middle).utcoffset() == offset:
                        low = middle
                    else:
                        high = middle
                result.append(high)
                offset = self.local(hour).utcoffset()
        return result

    def at(self, date, seconds):
        """The instants at which the local clock shows `seconds` past midnight
        of `date`: two while the clock goes back, and around a gap the two
        instants of the offsets on either side of it."""
        wall = datetime.datetime.combine(date, datetime.time()) + datetime.timedelta(seconds=seconds)
        return {int(wall.replace(tzinfo=self.zone, fold=fold).timestamp()) for fold in (0, 1)}

    def instants(self):
        """(instant, special) pairs; special ones are about a change of
        offset, a holiday or a leap day."""
        changes = self.changes()
        special_days = set(LEAP_DAYS)
        for change in changes:
            day = self.local(change).date()
            special_days.update(day + datetime.timedelta(days=d) for d in (-1, 0, 1))
        first_day = self.local(int(WINDOW[0].timestamp())).date()
        last_day = self.local(int(WINDOW[1].timestamp()) - 1).date()
        days = [first_day + datetime.timedelta(days=d) for d in range((last_day - first_day).days + 1)]
        for day in days:
            if (day.month, day.day) in self.holidays:
                special_days.update(day + datetime.timedelta(days=d) for d in (-1, 0, 1))
        # the first and last second of a range, the second before it and the
        # second after, and the ends of the day
        edges = {0, 86399}
        for _, start, end in self.ranges:
            edges.update({start * 60 - 1, start * 60, end * 60 + 59, end * 60 + 60})
        edges = {e % 86400 for e in edges}
        result = {}
        for day in days:
            for edge in edges:
                for epoch in self.at(day, edge):
                    result[epoch] = result.get(epoch, False) or day in special_days
        for change in changes:
            for delta in (-3600, -1800, -61, -60, -1, 0, 1, 59, 60, 1800, 3600):
                result[change + delta] = True
        start, end = (int(w.timestamp()) for w in WINDOW)
        return sorted((epoch, special) for epoch, special in result.items() if start <= epoch < end)


def load(hours_path, zoneinfo_dir):
    """The hours of HOURS, each with the zone file of ZONEINFO that its
    `timezone` names."""
    options = json.loads(pathlib.Path(hours_path).read_text())
    result = {}
    for name, o in sorted(options.items()):
        with open(pathlib.Path(zoneinfo_dir, o["timezone"]), "rb") as file:
            result[name] = Hours(o, zoneinfo.ZoneInfo.from_file(file))
    return result


def plan(args):
    all_hours = load(args.hours, args.zoneinfo)
    rng = random.Random(args.seed)
    instants = {name: hours.instants() for name, hours in all_hours.items()}
    pool = [(name, epoch, special) for name, pairs in instants.items() for epoch, special in pairs]
    if args.sample is None:
        picked = [(name, epoch) for name, epoch, _ in pool]
    else:
        # half of the sample on special days
        special = [(name, epoch) for name, epoch, s in pool if s]
        ordinary = [(name, epoch) for name, epoch, s in pool if not s]
        picked = rng.sample(special, args.sample // 2) + rng.sample(ordinary, args.sample - args.sample // 2)
    picked.sort()
    calls = []
    for i in range(0, len(picked), args.chunk):
        calls.append({"extension": f"s{len(calls)}", "state": None, "instants": picked[i:i + args.chunk]})
    for name, hours in all_hours.items():
        if hours.options.get("closeEarly") is not None:
            mine = sorted(rng.sample([(name, epoch) for epoch, _ in instants[name]], EARLY))
            calls.append({"extension": f"early-{name}", "state": "INUSE", "instants": mine})
            calls.append({"extension": f"reopened-{name}", "state": "NOT_INUSE", "instants": mine})
    out = pathlib.Path(args.out)
    out.mkdir()
    (out / "plan.json").write_text(json.dumps(calls) + "\n")
    lines = ["[hours-sweep]"]
    for call in calls:
        lines.append(f"exten => {call['extension']},1,NoOp()")
        for name, epoch in call["instants"]:
            fields = "${GOSUB_RETVAL}"
            if call["state"] is not None:
                # the busy lamp of the close-early number, and its state in astdb
                number = all_hours[name].options["closeEarly"]
                fields += f"|${{EXTENSION_STATE({number}@pbx-internal)}}|${{DB(CustomDevstate/pbx-hours-{name})}}"
            lines += [
                f" same => n,Set(TESTTIME={epoch})",
                f" same => n,Gosub(pbx-hours-{name},s,1)",
                f" same => n,NoOp(hours|{name}|{epoch}|{fields})",
            ]
        lines.append(" same => n,Hangup()")
    (out / "sweep.conf").write_text("\n".join(lines) + "\n")


# the zone file a GotoIfTime of the routine names
ZONE_FILE = re.compile(r",(/[^,?]*)\?")


def check(args):
    probe = json.loads(pathlib.Path(args.probe).read_text())
    planned = json.loads(pathlib.Path(args.plan).read_text())
    calls = {c["extension"]: c for c in probe["calls"] if c["context"] == "hours-sweep"}
    problems = []
    if sorted(calls) != sorted(c["extension"] for c in planned):
        problems.append(f"the probe called {sorted(calls)}, the plan has {[c['extension'] for c in planned]}")
    all_hours = load(args.hours, args.zoneinfo)
    # the oracle reads the zone file that GotoIfTime reads
    named = set()
    for call in calls.values():
        for step in call["steps"]:
            if step["application"] == "GotoIfTime" and step["context"].startswith("pbx-hours-"):
                timezone = all_hours[step["context"].removeprefix("pbx-hours-")].options["timezone"]
                named.update((file, timezone) for file in ZONE_FILE.findall(step["data"]))
        # the logger drops what comes past its queue (main/logger.c ast_log_full)
        problems += [f"{call['extension']}: {m['message']}" for m in call["log"] if m["message"].startswith("Log queue threshold")]
    for file, timezone in sorted(named):
        if pathlib.Path(file) != pathlib.Path(args.zoneinfo, timezone):
            problems.append(f"GotoIfTime reads {file} for {timezone}, the oracle {args.zoneinfo}/{timezone}")
    agree = 0
    disagree = []
    for plan in planned:
        call = calls.get(plan["extension"])
        if call is None:
            continue
        state = plan["state"]
        results = [s["data"].split("|")[1:] for s in call["steps"] if s["application"] == "NoOp" and s["data"].startswith("hours|")]
        if [[r[0], int(r[1])] for r in results] != plan["instants"]:
            problems.append(f"{plan['extension']}: {len(results)} results for {len(plan['instants'])} instants, or out of order")
            continue
        for name, epoch, *got in results:
            hours = all_hours[name]
            epoch = int(epoch)
            # closed while closed early, with the lamp lit, and as the hours
            # say once opened again
            expected = [
                "open" if state != "INUSE" and hours.open(epoch) else "closed",
                *([] if state is None else [state, state]),
            ]
            if got == expected:
                agree += 1
                continue
            known = None
            if state is None and got[0] == ("open" if hours.f11(epoch) else "closed"):
                known = "F11"
            disagree.append({
                "call": plan["extension"],
                "hours": name,
                "timezone": hours.options["timezone"],
                "instant": epoch,
                "utc": datetime.datetime.fromtimestamp(epoch, datetime.UTC).isoformat(),
                "local": hours.local(epoch).strftime("%a %Y-%m-%d %H:%M:%S %z"),
                "expected": expected,
                "got": got,
                "known": known,
            })
    report = {
        "zones": sorted({h.options["timezone"] for h in all_hours.values()}),
        "agree": agree,
        "disagree": len(disagree),
        "unknown": sum(1 for d in disagree if d["known"] is None),
        "problems": problems,
        "seconds": round(sum(c["seconds"] for c in probe["calls"]), 1),
        "disagreements": disagree,
    }
    out = pathlib.Path(args.out)
    out.mkdir()
    (out / "report.json").write_text(json.dumps(report, indent=1) + "\n")


def sweep(args):
    flake = str(pathlib.Path(args.flake).resolve())
    zones = json.loads(subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expression(flake, "hours.zones")],
        check=True, capture_output=True, text=True,
    ).stdout)
    # as Nix lists
    groups = [" ".join(json.dumps(z) for z in zones[i:i + args.zones_per_boot])
              for i in range(0, len(zones), args.zones_per_boot)]
    start = time.monotonic()
    # the plans first, for the number of calls each boot places
    plans = build(flake, args.jobs, [f"(hours.run {{ zones = [ {g} ]; chunks = 0; }}).plan" for g in groups])
    runs = []
    for group, plan_path in zip(groups, plans):
        chunks = sum(1 for c in json.loads((plan_path / "plan.json").read_text()) if c["state"] is None)
        runs.append(f"(hours.run {{ zones = [ {group} ]; chunks = {chunks}; }}).report")
    reports = build(flake, args.jobs, runs)
    seconds = round(time.monotonic() - start)
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    summary = {"seconds": seconds, "zones": zones, "agree": 0, "disagree": 0, "unknown": 0, "problems": [], "boots": []}
    known = {}
    for path in reports:
        report = json.loads((path / "report.json").read_text())
        (out / f"report-{'-'.join(z.replace('/', '_') for z in report['zones'])}.json").write_text(json.dumps(report, indent=1) + "\n")
        for key in ("agree", "disagree", "unknown"):
            summary[key] += report[key]
        summary["problems"] += report["problems"]
        summary["boots"].append({key: report[key] for key in ("zones", "seconds", "agree", "disagree")})
        for d in report["disagreements"]:
            # the zone and the kind: names repeat from one boot to the next
            known.setdefault(d["known"] or "unknown", []).append(f"{d['timezone']} {d['hours'].split('-', 1)[1]}")
    summary["disagreeing hours"] = {k: sorted(set(v)) for k, v in known.items()}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(json.dumps(summary, indent=1))
    return 1 if summary["unknown"] or summary["problems"] else 0


def build(flake, jobs, attributes):
    """Builds the derivations `attributes` name; their outputs, in order."""
    farm = " ".join(f'{{ name = "{i}"; path = {a}; }}' for i, a in enumerate(attributes))
    out = subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", "--max-jobs", str(jobs), "--impure",
         "--expr", expression(flake, f'pkgs.linkFarm "asterisk-hours-sweep" [ {farm} ]')],
        check=True, stdout=subprocess.PIPE, text=True,
    ).stdout.strip()
    return [pathlib.Path(out, str(i)).resolve() for i in range(len(attributes))]


def expression(flake, body):
    return (
        f"let self = builtins.getFlake {json.dumps(flake)}; "
        f"pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux; "
        f"hours = import {json.dumps(flake + '/tests/campaign/hours.nix')} {{ inherit pkgs self; }}; "
        f"in {body}"
    )


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("plan")
    p.add_argument("hours")
    p.add_argument("zoneinfo")
    p.add_argument("out")
    p.add_argument("--chunk", type=int, required=True)
    p.add_argument("--sample", type=int)
    p.add_argument("--seed", default="asterix")
    c = commands.add_parser("check")
    c.add_argument("hours")
    c.add_argument("zoneinfo")
    c.add_argument("plan")
    c.add_argument("probe")
    c.add_argument("out")
    s = commands.add_parser("sweep")
    s.add_argument("out")
    s.add_argument("--flake", default=".")
    s.add_argument("--zones-per-boot", type=int, default=3)
    s.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    sys.exit({"plan": plan, "check": check, "sweep": sweep}[args.command](args))


if __name__ == "__main__":
    main()
