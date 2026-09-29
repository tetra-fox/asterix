#!/usr/bin/env python3
"""Every way a call from a trunk reaches a Dial through a trunk, found by
walking the dialplan Asterisk loaded, as the T1 probe (tests/campaign/probe.nix)
shows it:

    tollfraud.py walk PROBE POLICY

PROBE is the probe.json of a run with `dialplan show`, `dialplan show
globals`, `queue show` and `pjsip show endpoint TRUNK` for each trunk. POLICY
is JSON: `trunks`, the trunk endpoints, and `named`, the outside numbers the
configuration lets a caller from outside reach, each as {"trunk", "number"}.

A call from a trunk starts in the trunk's context with any number its caller
chooses. The walk follows the steps from there: includes and Loopback
switches, Goto, GotoIf and GotoIfTime (both ways), Gosub and GosubIf, Dial,
Queue, Page and Originate of Local channels, the routines of their b(), B()
and U() options, the digits WaitExten and Background take and those a caller
dials into a transfer (Dial's T) or DISA, the o and a extensions VoiceMail
leaves to, what Read and Set store, and the `h` extension. A Dial of
`PJSIP/NUMBER@TRUNK` is a path to an outside number, named when NUMBER is
fixed and POLICY names it for TRUNK. A number from the caller's digits or
caller ID, a fixed one POLICY does not name, a trunk dialled without a number
and a number the walk cannot work out are findings: toll fraud, or a path to
check by hand. Not followed: a queue's `context`, ConfBridge menus and
switches other than Loopback, which are reported.

Prints the paths as JSON, one per trunk, way through and number, and exits
with 1 if one is a finding or something could not be followed. The search
and the matching of extensions are those of dialplan.py.
"""

import dataclasses
import json
import re
import sys

import dialplan

# a part of a value the caller chooses, and one the walk cannot know
ANY = "\x01"
UNKNOWN = "\x02"
# applications after which the caller's digits pick the next extension
DIGITS = {"waitexten", "background"}
ENDS = {"hangup", "busy", "congestion"}


def split_top(text, separator):
    """`text` split at `separator` outside parentheses, brackets and ${}."""
    parts, depth, current = [], 0, ""
    for c in text:
        if c in "([{":
            depth += 1
        elif c in ")]}" and depth:
            depth -= 1
        if c == separator and not depth:
            parts.append(current)
            current = ""
        else:
            current += c
    return parts + [current]


def expression_end(text, start):
    """The index after the } that closes the ${ at `start`."""
    depth = 0
    i = start
    while i < len(text):
        if text.startswith("${", i):
            depth += 1
            i += 2
            continue
        if text[i] == "}":
            depth -= 1
            if not depth:
                return i + 1
        i += 1
    return len(text)


def shown(value):
    return value.replace(ANY, "<caller>").replace(UNKNOWN, "<unknown>")


@dataclasses.dataclass(frozen=True)
class Channel:
    """What a step reads on its channel: the dialled extension, with the
    pattern it matched when the caller chose it, its variables, and whether
    its caller ID comes from outside."""

    exten: str
    variables: tuple = ()
    outside: bool = True
    pattern: str | None = None

    def get(self, name):
        return dict(self.variables).get(name)

    def setting(self, changes):
        variables = dict(self.variables)
        variables.update(changes)
        return dataclasses.replace(self, variables=tuple(sorted(variables.items())))


@dataclasses.dataclass(frozen=True)
class Place:
    """Where a channel runs: its context, the extension found for it, the
    context a switch runs that extension in, and the priority."""

    context: str
    extension: object
    switched: str | None
    priority: int


class Walk:
    def __init__(self, probe, policy):
        self.unresolved = []
        outputs = {c["command"]: c["output"] for c in probe["commands"]}
        self.contexts = dialplan.parse(outputs["dialplan show"])
        self.globals = dict(
            m.groups() for m in re.finditer(r"^   ([^=\n]+)=(.*)$", outputs.get("dialplan show globals", ""), re.M)
        )
        self.queues = queue_members(outputs.get("queue show", ""))
        self.trunks = set(policy["trunks"])
        self.named = {(n["trunk"], n["number"]) for n in policy["named"]}
        self.starts = {}
        for trunk in sorted(self.trunks):
            m = re.search(r"^ context\s+: (.*)$", outputs.get(f"pjsip show endpoint {trunk}", ""), re.M)
            if m:
                self.starts[trunk] = m.group(1).strip()
            else:
                self.unresolved.append({"where": trunk, "what": "no context"})
        self.seen = set()
        self.dials = []

    def run(self):
        for trunk, context in self.starts.items():
            self.enter(trunk, context, ANY, [], Channel(ANY), ())
        return self

    # values

    def value(self, text, channel):
        """`text` with its variables replaced, as far as the walk knows them."""
        result, i = "", 0
        while i < len(text):
            if text.startswith("${", i):
                end = expression_end(text, i)
                result += self.variable(self.value(text[i + 2 : end - 1], channel), channel)
                i = end
            elif text.startswith("$[", i):
                end = text.find("]", i)
                result += UNKNOWN
                i = len(text) if end < 0 else end + 1
            else:
                result += text[i]
                i += 1
        return result

    def variable(self, expression, channel):
        m = re.fullmatch(r"([A-Za-z0-9_]+)\((.*)\)", expression, re.S)
        if m:
            function, args = m.group(1).upper(), m.group(2)
            if function == "PJSIP_DIAL_CONTACTS":
                return f"PJSIP/{args}"
            # a caller from outside sends any caller ID they like
            if function == "CALLERID" and channel.outside:
                return ANY
            return UNKNOWN
        name, _, rest = expression.partition(":")
        if name == "EXTEN":
            value = channel.exten
        elif channel.get(name) is not None:
            value = channel.get(name)
        else:
            value = self.globals.get(name, UNKNOWN)
        if not rest or ANY in value or UNKNOWN in value:
            return value
        numbers = [int(x) if x else None for x in rest.split(":")]
        part = value[numbers[0] or 0 :]
        if len(numbers) > 1 and numbers[1] is not None:
            part = part[: numbers[1]]
        return part

    # the walk

    def enter(self, trunk, context, exten, path, channel, stack):
        """A channel that starts in `context` for `exten`, which may be the
        caller's to choose."""
        if ANY in exten:
            for switched, extension in self.extensions(context, path):
                if 1 in extension.steps:
                    pattern = extension.name if extension.name.startswith("_") else None
                    chosen = dataclasses.replace(channel, exten=ANY if pattern else extension.name, pattern=pattern)
                    self.steps(trunk, Place(context, extension, switched, 1), path, chosen, stack)
            return
        self.jump(trunk, context, exten, "1", path, channel, stack)

    def jump(self, trunk, context, exten, priority, path, channel, stack):
        """Goes to a priority or label of `exten` in `context`, or to `i`."""
        if context is None or UNKNOWN in context + exten + priority:
            what = f"goto {context},{shown(exten)},{shown(priority)}"
            self.unresolved.append({"where": path[-1] if path else trunk, "what": what})
            return
        if ANY in exten:
            self.enter(trunk, context, exten, path, channel, stack)
            return
        number = int(priority) if re.fullmatch(r"\s*\d+\s*", priority) else None
        found = dialplan.lookup(self.contexts, context, exten, number or 1, None if number else priority)
        channel = dataclasses.replace(channel, exten=exten)
        if found:
            switched, extension, step = found
            self.steps(trunk, Place(context, extension, switched, step.priority), path, channel, stack)
        elif exten != "i" and dialplan.lookup(self.contexts, context, "i"):
            self.jump(trunk, context, "i", "1", path, channel, stack)

    def extensions(self, context, path, seen=None):
        """The extensions a caller who chooses the number reaches in
        `context`: its own, those of its Loopback switches and its includes',
        as (switched, extension)."""
        seen = set() if seen is None else seen
        c = self.contexts.get(context)
        if c is None or context.lower() in seen:
            return []
        seen.add(context.lower())
        result = [(None, e) for e in c.extensions]
        for switch in c.switches:
            name, _, data = switch.partition("/")
            if name.lower() == "loopback":
                target = data.partition("/")[0].rpartition("@")[2].partition(":")[0]
                result += [(target, e) for _, e in self.extensions(target, path, set())]
            else:
                self.unresolved.append({"where": context, "what": f"switch {switch}"})
        for include in c.includes:
            result += self.extensions(dialplan.include_target(include), path, seen)
        return result

    def steps(self, trunk, place, path, channel, stack):
        """Runs the extension of `place` from its priority on."""
        key = (trunk, place, channel, stack)
        if key in self.seen or len(path) > 500:
            return
        self.seen.add(key)
        step = place.extension.steps.get(place.priority)
        if step is None:
            self.back(trunk, place, path, channel, stack)
            return
        here = path + [f"{place.switched or place.context},{shown(channel.exten)},{place.priority},{step.text()}"]
        after = dataclasses.replace(place, priority=place.priority + 1)
        app = step.application.lower()
        if app in ENDS:
            self.hangup(trunk, place, here, channel, stack)
            return
        if app == "goto":
            self.goto(trunk, place, step.data, here, channel, stack)
            return
        # Return comes back to the next step, with the extension and arguments
        # the channel had
        arguments = tuple((k, v) for k, v in channel.variables if re.fullmatch(r"ARG\d+", k))
        called = stack + ((after, channel.exten, arguments),)
        if app in ("gotoif", "gotoiftime", "gosubif"):
            # cond?iftrue:iffalse, where a missing or empty one goes on
            branches = split_top(step.data.partition("?")[2], ":")
            for target in branches + [""] * (2 - len(branches)):
                if not target:
                    self.steps(trunk, after, here, channel, stack)
                elif app == "gosubif":
                    self.gosub(trunk, place, target, here, channel, called)
                else:
                    self.goto(trunk, place, target, here, channel, stack)
            return
        if app == "gosub":
            self.gosub(trunk, place, step.data, here, channel, called)
            return
        if app == "return":
            self.back(trunk, place, here, channel, stack)
            return
        if app == "set":
            name, _, value = step.data.partition("=")
            if "(" not in name:
                channel = channel.setting({name.strip(): self.value(value, channel)})
        elif app == "read":
            channel = channel.setting({split_top(step.data, ",")[0].strip(): ANY})
        elif app in ("dial", "page", "queue"):
            args = split_top(step.data, ",")
            # the options come second in Queue and Page, third in Dial
            options = args[2 if app == "dial" else 1] if len(args) > (2 if app == "dial" else 1) else ""
            if app == "queue":
                devices = self.queues.get(self.value(args[0], channel), [])
            else:
                devices = [self.value(args[0], channel)]
            for device in devices:
                self.dial(trunk, device, here, channel)
            self.routines(trunk, options, here, channel)
            # with T the caller may transfer the call to any extension of
            # their context by DTMF (features.conf blindxfer)
            if "T" in re.sub(r"\([^()]*\)", "", options):
                self.enter(trunk, place.context, ANY, here, channel, ())
        elif app == "originate":
            args = split_top(step.data, ",")
            self.dial(trunk, self.value(args[0], channel), here, channel)
            if len(args) > 3 and args[1] == "exten":
                self.enter(trunk, self.value(args[2], channel), self.value(args[3], channel), here, Channel(ANY), ())
        elif app == "disa":
            args = split_top(step.data, ",")
            self.enter(trunk, self.value(args[1], channel) if len(args) > 1 else "disa", ANY, here, channel, ())
        elif app == "voicemail":
            # 0 leaves a message for the o extension of the context, * for a
            for exten in ("o", "a"):
                if dialplan.lookup(self.contexts, place.context, exten):
                    self.jump(trunk, place.context, exten, "1", here, channel, stack)
        elif app in DIGITS:
            self.enter(trunk, place.context, ANY, here, channel, stack)
        self.steps(trunk, after, here, channel, stack)

    def hangup(self, trunk, place, path, channel, stack):
        """The end of a call, which runs the `h` extension of its context."""
        if channel.exten != "h" and dialplan.lookup(self.contexts, place.context, "h"):
            self.jump(trunk, place.context, "h", "1", path, channel, ())

    def back(self, trunk, place, path, channel, stack):
        """Past the last step, or at Return: back after the Gosub, or the call
        ends."""
        if not stack:
            self.hangup(trunk, place, path, channel, stack)
            return
        (after, exten, arguments), rest = stack[-1], stack[:-1]
        variables = {k: v for k, v in channel.variables if not re.fullmatch(r"ARG\d+", k)}
        variables.update(arguments)
        channel = dataclasses.replace(channel, exten=exten, variables=tuple(sorted(variables.items())))
        self.steps(trunk, after, path, channel, rest)

    def goto(self, trunk, place, data, path, channel, stack):
        parts = [self.value(p, channel) for p in data.split(",")]
        context, exten, priority = [place.context, channel.exten][: 3 - len(parts)] + parts
        self.jump(trunk, context, exten, priority, path, channel, stack)

    def gosub(self, trunk, place, data, path, channel, stack):
        label, _, args = data.partition("(")
        if args:
            values = split_top(args.rpartition(")")[0], ",")
            channel = channel.setting({f"ARG{i}": self.value(v, channel) for i, v in enumerate(values, 1)})
        self.goto(trunk, place, label, path, channel, stack)

    def routines(self, trunk, options, path, channel):
        """The routines of options b() and B() (context^exten^priority) and U()
        (a context), each run on a channel of its own that ends at Return."""
        for option, routine in re.findall(r"([bBU])\(((?:[^()]|\([^()]*\))*)\)", options):
            label, _, args = routine.partition("(")
            parts = label.split("^")
            if option == "U":
                parts = [parts[0], "s", "1"]
            if len(parts) != 3:
                self.unresolved.append({"where": path[-1], "what": f"{option}({routine})"})
                continue
            data = ",".join(parts) + (f"({args}" if args else "")
            place = Place(parts[0], None, None, 1)
            self.gosub(trunk, place, data, path, channel, ())

    def dial(self, trunk, devices, path, channel):
        """The channels a dial string calls: Local ones run on, PJSIP ones to
        a trunk are paths out."""
        for device in split_top(devices, "&"):
            device = device.strip()
            tech, _, rest = device.partition("/")
            if tech.lower() == "local":
                exten, _, context = rest.split("/")[0].rpartition("@")
                self.enter(trunk, context, exten, path, Channel(exten, outside=channel.outside), ())
            elif tech.upper() == "PJSIP":
                resource = rest.split("/")[0]
                number, at, endpoint = resource.rpartition("@")
                dialled = {"trunk": trunk, "number": number if at else None, "path": path}
                if endpoint in self.trunks:
                    self.dials.append(dialled | {"via": endpoint})
                elif UNKNOWN in endpoint:
                    self.unresolved.append({"where": path[-1], "what": f"dial {shown(device)}"})
                elif ANY in endpoint:
                    # the trunks whose name the caller can put there, which is
                    # a number of the extension's pattern when that is all
                    shape = re.escape(endpoint).replace(re.escape(ANY), ".+")
                    whole = endpoint == ANY and channel.pattern is not None
                    for via in sorted(self.trunks):
                        if re.fullmatch(shape, via) and (not whole or dialplan.matches(channel.pattern, via)):
                            self.dials.append(dialled | {"via": via, "chosen": True})
            elif ANY in device or UNKNOWN in device:
                self.unresolved.append({"where": path[-1], "what": f"dial {shown(device)}"})

    def report(self):
        """Each way from a trunk to a trunk's Dial once, with why it is a
        finding, or null when the configuration names it."""
        result = {}
        for d in self.dials:
            number = d["number"]
            if d.get("chosen"):
                why = "the caller chooses the trunk"
            elif number is None:
                why = "a trunk dialled without a number"
            elif ANY in number:
                why = "the caller chooses the number"
            elif UNKNOWN in number:
                why = "a number the walk cannot work out"
            elif (d["via"], number) in self.named:
                why = None
            else:
                why = "a number the configuration does not name"
            result.setdefault((d["trunk"], d["via"], shown(number or ""), why or ""), d["path"])
        return [
            {"from": trunk, "via": via, "number": number, "finding": why or None, "path": path}
            for (trunk, via, number, why), path in sorted(result.items())
        ]


def queue_members(output):
    """The members of each queue in `queue show`, as the devices they call."""
    queues, name = {}, None
    for line in output.splitlines():
        if m := re.match(r"(.*) has \d+ calls? \(max", line):
            name = m.group(1)
            queues[name] = []
        elif name is not None and re.match(r" {6}\S", line):
            member = line.strip()
            # a member with a name shows its device in parentheses after it
            m = re.match(r"(.*?) \(([A-Za-z0-9_]+/[^)]*)\)", member)
            queues[name].append(m.group(2) if m and "/" not in m.group(1) else member.split(" (")[0])
    return queues


def main():
    match sys.argv[1:]:
        case ["walk", probe, policy]:
            walk = Walk(json.load(open(probe)), json.load(open(policy))).run()
            paths = walk.report()
            unresolved = [json.loads(u) for u in sorted({json.dumps(u, sort_keys=True) for u in walk.unresolved})]
            print(json.dumps({"paths": paths, "unresolved": unresolved}, indent=1, ensure_ascii=False))
            sys.exit(1 if unresolved or any(p["finding"] for p in paths) else 0)
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
