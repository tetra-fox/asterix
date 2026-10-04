#!/usr/bin/env python3
"""Every way a call from a trunk reaches a Dial through a trunk, found by
walking the dialplan Asterisk loaded, as the probe (tests/campaign/probe.nix)
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
with 1 if one is a finding or something could not be followed. Extensions
sort and match as configs/samples/extensions.conf.sample and the pattern
matching rules of Asterisk's documentation say, and where they say nothing,
a comment names the source.
"""

import dataclasses
import json
import re
import sys

# a part of a value the caller chooses, and one the walk cannot know
ANY = "\x01"
UNKNOWN = "\x02"
# applications after which the caller's digits pick the next extension
DIGITS = {"waitexten", "background"}
ENDS = {"hangup", "busy", "congestion"}

# `.` and `!` sort after every set of characters, `.` first, and the end of a
# pattern after both (main/pbx.c ext_cmp_pattern_pos)
WILDCARD = {".": 0x18000, "!": 0x28000}
END = (0x30000, ())

# the characters N, X and Z stand for, in either case (main/pbx.c
# _extension_match_core)
CLASSES = {"N": "23456789", "X": "0123456789", "Z": "123456789"}


def positions(pattern):
    """The positions of a pattern without its underscore, each a set of
    characters or a wildcard. Dashes outside a set are ignored."""
    result = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "-":
            i += 1
        elif c == "[":
            end = pattern.find("]", i + 1)
            if end < 0:
                raise ValueError(f"no ] in pattern {pattern!r}")
            chars = set()
            body = pattern[i + 1 : end]
            j = 0
            while j < len(body):
                if j + 2 < len(body) and body[j + 1] == "-":
                    chars.update(chr(x) for x in range(ord(body[j]), ord(body[j + 2]) + 1))
                    j += 3
                else:
                    chars.add(body[j])
                    j += 1
            # an empty set is skipped
            if chars:
                result.append(frozenset(chars))
            i = end + 1
        elif c in WILDCARD:
            result.append(c)
            i += 1
        else:
            result.append(frozenset(CLASSES.get(c.upper(), c)))
            i += 1
    return result


def matches(extension, number):
    """Whether dialling `number` reaches `extension`, a name or a pattern."""
    if not extension.startswith("_"):
        return extension.replace("-", "") == number.replace("-", "")
    rest = number.replace("-", "")
    for position in positions(extension[1:]):
        if position == ".":
            return rest != ""
        if position == "!":
            return True
        if not rest or rest[0] not in position:
            return False
        rest = rest[1:]
    return rest == ""


def sort_key(extension):
    """Asterisk's order of extensions: names before patterns; patterns by
    their positions from the left, a smaller set before a larger one, sets of
    one size by their characters."""
    if not extension.startswith("_"):
        return (0, extension.replace("-", "").encode())
    keys = []
    for position in positions(extension[1:]):
        if position in WILDCARD:
            keys.append((WILDCARD[position], ()))
        else:
            chars = tuple(sorted(ord(c) for c in position))
            keys.append(((len(chars) << 8) | chars[0], chars))
    return (1, tuple(keys) + (END,))


@dataclasses.dataclass
class Step:
    priority: int
    label: str | None
    application: str
    data: str

    def text(self):
        return f"{self.application}({self.data})"


# compared and hashed as itself, so a walk can tell extensions apart
@dataclasses.dataclass(eq=False)
class Extension:
    name: str
    # the caller ID an extension written as name/callerid matches
    cid: str | None = None
    hint: str | None = None
    steps: dict = dataclasses.field(default_factory=dict)

    def key(self):
        # an extension with a caller ID comes before the same one without
        # (main/pbx.c ast_add_extension2_lockopt)
        cid = (0, sort_key(self.cid)) if self.cid is not None else (1,)
        return (sort_key(self.name), cid)


@dataclasses.dataclass
class Context:
    name: str
    extensions: list = dataclasses.field(default_factory=list)
    includes: list = dataclasses.field(default_factory=list)
    switches: list = dataclasses.field(default_factory=list)
    ignorepats: list = dataclasses.field(default_factory=list)

    def extension(self, name, cid=None):
        for e in self.extensions:
            if e.name == name and e.cid == cid:
                return e
        e = Extension(name, cid)
        self.extensions.append(e)
        self.extensions.sort(key=Extension.key)
        return e


def application(text):
    """`App(data)` as the application and its data."""
    name, _, rest = text.partition("(")
    return name.strip(), rest[: rest.rfind(")")] if ")" in rest else rest


# `dialplan show` (main/pbx.c show_dialplan_helper): a line is
# "  %-17s %-45s [registrar]", the first column holding the extension or a
# label
HEADER = re.compile(r"\[ (?P<included>Included context|Context) '(?P<name>.*)' created by '.*' \]")
EXTENSION = re.compile(r"  '(?P<name>.*?)'(?: \(CID match '(?P<cid>.*?)'\))? => +(?P<rest>.*)")
LABEL = re.compile(r" {5}\[(?P<label>.*?)\] +(?P<rest>\d+\. .*)")
NEXT = re.compile(r" {20,}(?P<rest>\d+\. .*)")
OTHER = re.compile(r"  (?P<what>Include =>|Ignore pattern =>|Alt\. Switch =>) +'(?P<value>.*)' +\[[^][]*\]")
REGISTRAR = re.compile(r"(?P<body>.*?) +\[[^][]*\]")
PRIORITY = re.compile(r"(?P<priority>\d+)\. (?P<app>.*)")


def events(output):
    """What `dialplan show` printed, as a list of events: ("context", name,
    included), ("extension", name, cid), ("hint", value), ("step", priority,
    label, application, data), ("include", value), ("ignorepat", value) and
    ("switch", value)."""
    result = []
    for line in output.splitlines():
        if m := HEADER.fullmatch(line):
            result.append(("context", m["name"], m["included"] != "Context"))
            continue
        if m := OTHER.fullmatch(line):
            kind = {"Include =>": "include", "Ignore pattern =>": "ignorepat", "Alt. Switch =>": "switch"}[m["what"]]
            result.append((kind, m["value"]))
            continue
        label = None
        if m := EXTENSION.fullmatch(line):
            result.append(("extension", m["name"], m["cid"]))
            rest = m["rest"]
        elif m := LABEL.fullmatch(line):
            label, rest = m["label"], m["rest"]
        elif m := NEXT.fullmatch(line):
            rest = m["rest"]
        else:
            continue
        body = REGISTRAR.fullmatch(rest)["body"]
        if body.startswith("hint: "):
            result.append(("hint", body.removeprefix("hint: ")))
        else:
            p = PRIORITY.fullmatch(body)
            result.append(("step", int(p["priority"]), label, *application(p["app"])))
    return result


def parse(output):
    """The contexts of a whole `dialplan show`, by name."""
    contexts = {}
    context = extension = None
    for event in events(output):
        match event:
            case ("context", name, _):
                context = contexts.setdefault(name, Context(name))
            case ("extension", name, cid):
                extension = context.extension(name, cid)
            case ("hint", value):
                extension.hint = value
            case ("step", priority, label, app, data):
                extension.steps[priority] = Step(priority, label, app, data)
            case ("include", value):
                context.includes.append(value)
            case ("ignorepat", value):
                context.ignorepats.append(value)
            case ("switch", value):
                context.switches.append(value)
    return contexts


def include_target(value):
    """The context an include names: up to a | or else a comma, after which
    comes the time it applies at (main/pbx_include.c include_alloc)."""
    for separator in "|,":
        if separator in value:
            return value.split(separator, 1)[0]
    return value


def lookup(contexts, context, number, priority=1, label=None, visited=None):
    """Where Asterisk finds NUMBER in CONTEXT: its extensions in their order,
    the first that matches and has the priority or label; then the
    context's switches, of which only Loopback is modelled; then its
    includes in order, depth first, each context once, compared ignoring
    case (main/pbx.c pbx_find_extension). Returns (switched, extension,
    step), where switched is the context a switch ran the lookup in, or
    None."""
    visited = set() if visited is None else visited
    c = contexts.get(context)
    if c is None or context.lower() in visited:
        return None
    for e in c.extensions:
        # the walk has no caller ID, which only an empty CID match takes
        if not matches(e.name, number) or e.cid not in (None, ""):
            continue
        for step in e.steps.values():
            if (step.label == label) if label is not None else (step.priority == priority):
                return (None, e, step)
    for switch in c.switches:
        name, _, data = switch.partition("/")
        if name.lower() != "loopback":
            continue
        # [exten]@context[:priority][/extramatch], empty parts meaning the
        # call's own (pbx/pbx_loopback.c)
        target, _, extramatch = data.partition("/")
        exten, _, rest = target.rpartition("@")
        where = rest.partition(":")[0]
        if where.lower() == context.lower() or (extramatch and not matches(extramatch, number)):
            continue
        found = lookup(contexts, where, exten or number, priority, label)
        if found:
            return (found[0] or where,) + found[1:]
    visited.add(context.lower())
    for include in c.includes:
        found = lookup(contexts, include_target(include), number, priority, label, visited)
        if found:
            return found
    return None


def split_top(text, separator):
    """`text` split at `separator` outside parentheses, brackets and ${},
    which Asterisk fills in before it splits (main/app.c
    __ast_app_separate_args); a brace alone is a character like any other."""
    parts, depth, current, i = [], 0, "", 0
    while i < len(text):
        if text.startswith("${", i):
            end = expression_end(text, i)
            current += text[i:end]
            i = end
            continue
        c = text[i]
        if c in "([":
            depth += 1
        elif c in ")]" and depth:
            depth -= 1
        if c == separator and not depth:
            parts.append(current)
            current = ""
        else:
            current += c
        i += 1
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
        self.contexts = parse(outputs["dialplan show"])
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
        found = lookup(self.contexts, context, exten, number or 1, None if number else priority)
        channel = dataclasses.replace(channel, exten=exten)
        if found:
            switched, extension, step = found
            self.steps(trunk, Place(context, extension, switched, step.priority), path, channel, stack)
        elif exten != "i" and lookup(self.contexts, context, "i"):
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
            result += self.extensions(include_target(include), path, seen)
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
                if lookup(self.contexts, place.context, exten):
                    self.jump(trunk, place.context, exten, "1", here, channel, stack)
        elif app in DIGITS:
            self.enter(trunk, place.context, ANY, here, channel, stack)
        self.steps(trunk, after, here, channel, stack)

    def hangup(self, trunk, place, path, channel, stack):
        """The end of a call, which runs the `h` extension of its context."""
        if channel.exten != "h" and lookup(self.contexts, place.context, "h"):
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
                # the options follow the last /, the context the first @
                # (main/core_local.c local_alloc)
                exten, _, context = (rest.rpartition("/")[0] if "/" in rest else rest).partition("@")
                self.enter(trunk, context or "default", exten, path, Channel(exten, outside=channel.outside), ())
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
                        if re.fullmatch(shape, via) and (not whole or matches(channel.pattern, via)):
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
            # a member with a name shows its device in parentheses after it,
            # and its state interface after `from` there
            m = re.match(r"(.*?) \(([A-Za-z0-9_]+/[^) ]*)(?: from [^)]*)?\)", member)
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
