#!/usr/bin/env python3
"""The dialplan as Asterisk searches it, written from its documented rules,
and a check of asterix's dialplan options against it through the T1 probe
(tests/campaign/probe.nix):

    dialplan.py check SCENARIO PROBE

SCENARIO is the JSON of the `modules` a check defines (tests/dialplan.nix):
each is a set of contexts as `services.asterisk.dialplan.contexts` takes
them (includes, switches, ignorePatterns, extensions, hints, extraConfig),
where a list may instead be `{"before": list}` or `{"after": list}`
(lib.mkBefore, lib.mkAfter), plus `settings`, lines for the context's `exten`
in services.asterisk.settings; and `queries`, each a number dialled in a
context, with an optional caller ID. PROBE is the probe.json of a run with
`dialplan show NUMBER@CONTEXT` for each query and a call for each.

The expected dialplan comes from the option descriptions: the definitions of
a list from several modules are concatenated in module order, lib.mkBefore
ones first and lib.mkAfter ones last (D22), and an include, switch or ignore
pattern listed twice counts once; an extension's first step gets priority 1
and the following ones the next priorities, a label names its step; a
context searches its own extensions, then its switches, then its includes in
order. How Asterisk sorts and matches extensions follows
configs/samples/extensions.conf.sample and the pattern matching rules of its
documentation; where they say nothing, the source is named in a comment. The
check prints each disagreement and fails if there is one.

The parser, the matcher and the search are also what tollfraud.py walks the
dialplan with.
"""

import dataclasses
import difflib
import json
import re
import sys

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


def show(contexts, context, number, included=False, stack=()):
    """The events `dialplan show NUMBER@CONTEXT` prints: the context's
    extensions that match, then its included contexts the same way, its
    ignore patterns that match and, for the context asked for, its switches
    (main/pbx.c show_dialplan_helper). The command looks for a context
    called like the whole include, so one with a time shows nothing."""
    c = contexts.get(context)
    if c is None:
        return []
    result = []
    matched = [e for e in c.extensions if matches(e.name, number)]
    if matched:
        result.append(("context", context, included))
    for e in matched:
        result.append(("extension", e.name, e.cid))
        if e.hint is not None:
            result.append(("hint", e.hint))
        for index, step in enumerate(sorted(e.steps.values(), key=lambda s: s.priority)):
            # the first line of an extension shows no label
            label = step.label if index > 0 or e.hint is not None else None
            result.append(("step", step.priority, label, step.application, step.data))
    for include in c.includes:
        if include.lower() not in stack:
            result += show(contexts, include, number, True, stack + (include.lower(),))
    result += [("ignorepat", p) for p in c.ignorepats if matches(f"_{p}.", number)]
    if not included:
        result += [("switch", s) for s in c.switches]
    return result


def include_target(value):
    """The context an include names: up to a | or else a comma, after which
    comes the time it applies at (main/pbx_include.c include_alloc)."""
    for separator in "|,":
        if separator in value:
            return value.split(separator, 1)[0]
    return value


def cid_matches(cid, callerid):
    if cid is None:
        return True
    if not callerid:
        return cid == ""
    return matches(cid, callerid)


def lookup(contexts, context, number, priority=1, label=None, callerid=None, visited=None):
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
        if not matches(e.name, number) or not cid_matches(e.cid, callerid):
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
        found = lookup(contexts, where, exten or number, priority, label, callerid)
        if found:
            return (found[0] or where,) + found[1:]
    visited.add(context.lower())
    for include in c.includes:
        found = lookup(contexts, include_target(include), number, priority, label, callerid, visited)
        if found:
            return found
    return None


def call(contexts, context, number, callerid=None, limit=100):
    """The steps a call to NUMBER in CONTEXT runs, as context, extension,
    priority and application, the context being the call's own unless a
    switch ran the step: the extension found from priority 1, a Goto to its
    target, a missing extension to `i`, and once the call ends, the `h`
    extension of its context (main/pbx.c __ast_pbx_run)."""
    result = []
    exten, priority, label = number, 1, None
    ended = False
    while len(result) < limit:
        found = lookup(contexts, context, exten, priority, label, callerid)
        if found is None:
            missing = label is None and lookup(contexts, context, exten, 1, None, callerid) is None
            if missing and not ended and exten != "i" and lookup(contexts, context, "i", 1, None, callerid):
                exten, priority = "i", 1
                continue
            if ended or lookup(contexts, context, "h", 1, None, callerid) is None:
                break
            ended = True
            exten, priority, label = "h", 1, None
            continue
        switched, _, step = found
        result.append(f"{switched or context},{exten},{step.priority},{step.text()}")
        label = None
        if step.application == "Goto":
            args = step.data.split(",")
            context, exten, target = [context, exten][: 3 - len(args)] + args
            # Goto reads a whole number as a priority, anything else as a
            # label (main/pbx.c pbx_parse_location)
            if re.fullmatch(r"\s*\d+\s*", target):
                priority = int(target)
            else:
                label = target
        elif step.application == "Hangup":
            priority = -1
        else:
            priority = step.priority + 1
    return result


def merged(modules, path):
    """The definitions of a list option in several modules, in the order
    the module system gives them: lib.mkBefore first, lib.mkAfter last,
    module order within each."""
    groups = {"before": [], "plain": [], "after": []}
    for module in modules:
        value = module
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
        if value is None:
            continue
        if isinstance(value, dict):
            kind = "before" if "before" in value else "after"
            groups[kind] += value[kind]
        else:
            groups["plain"] += value
    return groups["before"] + groups["plain"] + groups["after"]


def expected(modules):
    """The contexts `modules` describe, as the option descriptions say they
    render."""
    contexts = {}
    names = []
    for module in modules:
        names += [n for n in module if n not in names]
    for name in names:
        c = contexts[name] = Context(name)
        c.includes = list(dict.fromkeys(merged(modules, [name, "includes"])))
        c.switches = list(dict.fromkeys(merged(modules, [name, "switches"])))
        c.ignorepats = list(dict.fromkeys(merged(modules, [name, "ignorePatterns"])))
        extensions = []
        for module in modules:
            for e in module.get(name, {}).get("extensions", {}):
                if e not in extensions:
                    extensions.append(e)
        for e in extensions:
            written, _, cid = e.partition("/")
            extension = c.extension(written, cid if "/" in e else None)
            for index, step in enumerate(merged(modules, [name, "extensions", e]), 1):
                if isinstance(step, str):
                    app, data = application(step)
                    extension.steps[index] = Step(index, None, app, data)
                else:
                    args = ",".join(str(a) for a in step.get("args", []))
                    extension.steps[index] = Step(index, step.get("label"), step["app"], args)
        for module in modules:
            defined = module.get(name, {})
            for e, hint in defined.get("hints", {}).items():
                c.extension(e).hint = hint
            # lines written in the context's `extraConfig`, or its section's
            # `exten` in settings, with numbered priorities
            raw = [line.removeprefix("exten =>").strip() for line in defined.get("extraConfig", "").splitlines()]
            for line in raw + defined.get("settings", []):
                e, priority, step = line.split(",", 2)
                app, data = application(step)
                c.extension(e).steps[int(priority)] = Step(int(priority), None, app, data)
    return contexts


def difference(what, expected, actual):
    """The lines of `expected` and `actual` as a diff under a heading, or
    nothing when they agree."""
    if expected == actual:
        return []
    lines = difflib.unified_diff(list(map(str, expected)), list(map(str, actual)), "expected", "actual", lineterm="")
    return [what, *lines]


def check(scenario_path, probe_path):
    scenario = json.load(open(scenario_path))
    probe = json.load(open(probe_path))
    contexts = expected(scenario["modules"])
    outputs = {c["command"]: c["output"] for c in probe["commands"]}
    calls = {(c["context"], c["extension"], c.get("callerId")): c for c in probe["calls"]}
    problems = []
    for query in scenario["queries"]:
        context, number, callerid = query["context"], query["number"], query.get("callerId")
        where = f"{number}@{context}" + (f" from {callerid}" if callerid else "")
        shown = events(outputs[f"dialplan show {number}@{context}"])
        problems += difference(f"dialplan show {where}:", show(contexts, context, number), shown)
        made = calls[(context, number, callerid)]
        ran = [
            f"{s['context']},{s['extension']},{s['priority']},{s['application']}({s['data']})"
            for s in made["steps"]
            if s["channel"] == made["channel"]
        ]
        problems += difference(f"a call to {where}:", call(contexts, context, number, callerid), ran)
    print("\n".join(problems), file=sys.stderr)
    return 1 if problems else 0


def main():
    match sys.argv[1:]:
        case ["check", scenario, probe]:
            sys.exit(check(scenario, probe))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
