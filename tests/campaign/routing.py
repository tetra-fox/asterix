"""Where a call to a pbx configuration goes, written from the option
descriptions of `pbx.*` and the README's PBX layer section, never from the
Nix code, so a disagreement with the probe tests the code and the docs
together. configs.py places the calls this plans through the T1 probe
(probe.nix) and compares each with its prediction.

The facts it uses, each from a description or the README:

- phones dial from `pbx-internal`; each object is a context of its own,
  `pbx-<kind>-<name>` (README)
- a number reaches its object; a number outside is the outbound prefix, then
  the number, of two digits or more, and a pbx number that starts with the
  prefix still reaches the pbx (`outbound.prefix`); emergency numbers work
  with and without the prefix (`emergency.numbers`) and go out through
  `emergency.trunk`, by default `outbound.trunk`
- calls from a trunk start in `pbx-inbound-<trunk>`, which holds the numbers
  of `pbx.inbound` on that trunk; other numbers are rejected (`inbound`)
- an extension's phone rings for `ringTime`, then its no-answer destination
  takes the call, also when the phone is not registered, as no phone is in
  the probe (`noAnswer`); without one, the mailbox with the unavailable
  greeting, or hangup without a mailbox (its default)
- a ring group rings its members for `ringTime`, all at once or with `hunt`
  one after the other, and its numbers outside through `trunk`, by default
  `outbound.trunk`; then `noAnswer` (hangup by default)
- a queue answers and holds the caller in that queue until `timeout`, then
  `noAnswer`; without a timeout the caller waits until someone answers
- a conference joins the caller to the room of that name
- a voice menu plays its prompt `attempts` times, waiting `timeout` seconds
  after each; a key goes to its option; nothing pressed after the last
  attempt goes to `noInput`, a key without a destination on the last attempt
  to `invalid`; with `directDial` the extensions' numbers work too
- an emergency call also calls each extension of `notify` but the caller's
  own
- a voicemail destination leaves a message in `box@context`, `default`
  without a context, with the unavailable greeting unless `greeting` says
  `busy`
- a `context` destination goes to that extension and priority or label of
  hand-written dialplan
- a `hangup` destination ends a call not answered yet with the reason the
  last phone or trunk it rang gave, or with no answer (19) where none gave
  one; no phone is in the probe, and how a trunk ends is the far end's
- `closeEarly` closes the hours when dialled and opens them when dialled
  again; closed hours send calls to `closed`, like the time outside `open`
  and holidays
- `voicemailMenu` lets a phone listen to its own mailbox, `<number>@default`
"""

import datetime
import random
import zoneinfo

import generate

KIND_CONTEXT = {"extension": "extension", "ringGroup": "ringgroup", "queue": "queue", "conference": "conference", "ivr": "ivr", "paging": "paging"}
DAYS = generate.DAYS
# the seconds a prompt plays, at most, and the invalid-key sound
PROMPT = 1
INVALID = 2


def context_of(kind, name):
    return f"pbx-{KIND_CONTEXT[kind]}-{name}"


def mailbox(box):
    return box if "@" in box else f"{box}@default"


class Loop(Exception):
    """The call goes around without a key press (open finding F1)."""


class Path:
    """What a call does as the oracle follows it: the object contexts it
    enters, the steps (application, data) it must run in that order, the one
    it ends on, whether it is answered, and how long it takes at most."""

    def __init__(self, keys=""):
        self.contexts = []
        self.apps = []
        self.last = None
        self.answered = False
        self.seconds = 0
        # the seconds phones ring, where they are registered
        self.ringing = 0
        self.keys = keys
        self.long = False
        # whether a number outside rang, whose reason the oracle cannot know
        self.outside = False
        self.kinds = []
        # steps other channels of the call run, as application, start of the
        # data and extension
        self.legs = []

    def enter(self, context):
        if not self.contexts or self.contexts[-1] != context:
            self.contexts.append(context)

    def answer(self):
        """Answers the call; keys sent to anything but a menu are lost."""
        keys = self.keys if not self.answered else ""
        self.answered = True
        self.keys = ""
        return keys

    def prediction(self):
        return {
            "contexts": self.contexts,
            "apps": self.apps,
            "last": self.last,
            "answered": self.answered,
            "kinds": self.kinds,
            "legs": self.legs,
            "long": self.long,
            "ringing": self.ringing,
        }


class Oracle:
    def __init__(self, m):
        self.m = m
        self.closed = {name: False for name in m["hours"]}

    def follow(self, path, dest, seen):
        """Follows destination DEST, a dict with one tag."""
        (kind, value), = dest.items()
        path.kinds.append(kind)
        if kind in ("extension", "ringGroup", "queue", "conference", "ivr"):
            if (kind, value) in seen:
                raise Loop(f"{kind} {value}")
            seen = seen | {(kind, value)}
            path.enter(context_of(kind, value))
            getattr(self, kind)(path, value, seen)
        elif kind == "voicemail":
            box = value if isinstance(value, str) else value["mailbox"]
            greeting = "u" if isinstance(value, str) or value.get("greeting", "unavailable") == "unavailable" else "b"
            path.answer()
            path.apps.append(["VoiceMail", f"{mailbox(box)},{greeting}"])
            path.last = "VoiceMail"
            path.long = True
        elif kind == "context":
            priority = value.get("priority", 1)
            path.enter(value["context"])
            mark = 1 if priority == 1 else 2
            path.apps.append(["NoOp", f"mark {value['context']} {value.get('extension', 's')} {mark}"])
            path.last = "Hangup"
        elif kind == "hangup":
            cause = "" if path.answered else None if path.outside else "19"
            path.apps.append(["Hangup", cause])
            path.last = "Hangup"
        else:
            raise ValueError(f"unknown destination {dest}")

    def extension(self, path, number, seen):
        e = self.m["extensions"][number]
        # the phone rings for `ringTime`; no phone is registered, so nobody
        # answers
        path.apps.append(["Dial", {"second": str(e.get("ringTime", 20))}])
        path.ringing += e.get("ringTime", 20)
        if "noAnswer" in e:
            self.follow(path, e["noAnswer"], seen)
        elif "voicemail" in e:
            self.follow(path, {"voicemail": {"mailbox": number, "greeting": "unavailable"}}, seen)
        else:
            self.follow(path, {"hangup": True}, seen)

    def ringGroup(self, path, name, seen):
        g = self.m["ringGroups"][name]
        ring = ["Dial", {"second": str(g.get("ringTime", 20))}]
        # hunt rings each member, then each number outside, one after the other
        external = g.get("external", [])
        rings = len(g["members"]) + len(external) if g.get("strategy") == "hunt" else 1
        path.apps += [ring] * rings
        path.ringing += rings * g.get("ringTime", 20)
        trunk = g.get("trunk") or (self.m["outbound"] or {}).get("trunk")
        path.legs += [["Dial", f"PJSIP/{number}@{trunk},", number] for number in external]
        path.outside = path.outside or bool(external)
        self.follow(path, g.get("noAnswer", {"hangup": True}), seen)

    def queue(self, path, name, seen):
        q = self.m["queues"][name]
        path.answer()
        path.apps.append(["Queue", {"first": name}])
        if "timeout" in q:
            path.seconds += q["timeout"]
            self.follow(path, q.get("noAnswer", {"hangup": True}), seen)
        else:
            path.last = "Queue"
            path.long = True

    def conference(self, path, name, seen):
        path.answer()
        path.apps.append(["ConfBridge", {"first": name}])
        path.last = "ConfBridge"
        path.long = True

    def ivr(self, path, name, seen):
        i = self.m["ivrs"][name]
        keys = path.answer()
        attempts = i.get("attempts", 3)
        timeout = i.get("timeout", 5)
        wait = PROMPT + timeout
        options = i.get("options", {})
        prompt = ["BackGround", {"first": i["prompt"]["sound"]} if "sound" in i["prompt"] else None]
        path.apps.append(prompt)
        if keys:
            # what the call did before the key press cannot repeat as it was
            path.seconds += PROMPT
            if keys in options:
                return self.follow(path, options[keys], frozenset())
            if i.get("directDial") and keys in self.m["extensions"]:
                return self.follow(path, {"extension": keys}, frozenset())
            # a key without a destination: the menu tries again, and the
            # attempts after it get no key
            path.seconds += INVALID
            if attempts == 1:
                return self.follow(path, i.get("invalid", {"hangup": True}), frozenset())
            path.seconds += (attempts - 1) * wait
            path.apps += [prompt, ["WaitExten", {"first": str(timeout)}]] * (attempts - 1)
            return self.follow(path, i.get("noInput", {"hangup": True}), frozenset())
        # the prompt plays `attempts` times, each followed by `timeout`
        # seconds for a key
        path.seconds += attempts * wait
        path.apps += [["WaitExten", {"first": str(timeout)}]] + [prompt, ["WaitExten", {"first": str(timeout)}]] * (attempts - 1)
        self.follow(path, i.get("noInput", {"hangup": True}), seen)

    def numbers(self):
        """Every number of pbx-internal and what owns it."""
        m = self.m
        owned = {n: ("extension", n) for n in m["extensions"]}
        for option, kind in [("ringGroups", "ringGroup"), ("queues", "queue"), ("conferences", "conference"), ("ivrs", "ivr"), ("paging", "paging")]:
            for name, o in m[option].items():
                if "number" in o:
                    owned[o["number"]] = (kind, name)
        for name, h in m["hours"].items():
            if "closeEarly" in h:
                owned[h["closeEarly"]] = ("closeEarly", name)
        if m["voicemailMenu"] is not None:
            owned[m["voicemailMenu"]] = ("voicemailMenu", None)
        if m["emergency"]:
            prefix = m["outbound"]["prefix"] if m["outbound"] else ""
            for n in m["emergency"]["numbers"]:
                owned[n] = ("emergency", n)
                owned[prefix + n] = ("emergency", n)
        return owned

    def outside(self, number):
        """The number outside a dialled number reaches, or None when it is
        no number outside: the prefix, then two digits or more."""
        o = self.m["outbound"]
        if o is None or not number.startswith(o["prefix"]):
            return None
        rest = number[len(o["prefix"]) :]
        return rest if rest.isdigit() and len(rest) >= 2 else None

    def internal(self, number, keys="", callerid=None):
        """The prediction for NUMBER dialled from a phone."""
        owned = self.numbers()
        path = Path(keys)
        if number in owned:
            kind, name = owned[number]
            if kind == "paging":
                # the descriptions do not say when a page ends: Page() keeps
                # the caller until they hang up, as a caller would
                path.enter(context_of("paging", name))
                path.apps.append(["Page", None])
                path.last = "Page"
                path.answered = None
                path.long = True
            elif kind == "closeEarly":
                # the descriptions say what it changes, not how the call ends
                self.closed[name] = not self.closed[name]
                path.answered = None
            elif kind == "voicemailMenu":
                path.answer()
                path.apps.append(["VoiceMailMain", f"{callerid}@default"])
                path.last = "VoiceMailMain"
                path.long = True
            elif kind == "emergency":
                # the options after the dial string carry a caller ID
                trunk = self.m["emergency"].get("trunk") or self.m["outbound"]["trunk"]
                path.apps.append(["Dial", {"first": f"PJSIP/{name}@{trunk}"}])
                # the extensions of notify are called at the same moment
                path.legs += [["Dial", "", e] for e in self.m["emergency"].get("notify", []) if e != callerid]
                # how a call outside ends is the far end's
                path.answered = None
            else:
                self.follow(path, {kind: name}, frozenset())
            return path
        outside = self.outside(number)
        if outside is not None:
            path.apps.append(["Dial", {"first": f"PJSIP/{outside}@{self.m['outbound']['trunk']}"}])
            path.answered = None
            return path
        path.rejected = True
        return path

    def inbound(self, trunk, did, when=None):
        """The prediction for a call from TRUNK to DID at WHEN, an aware
        datetime."""
        path = Path()
        route = self.m["inbound"].get(did)
        if route is None or route["trunk"] != trunk:
            path.rejected = True
            return path
        if "destination" in route:
            self.follow(path, route["destination"], frozenset())
            return path
        h = self.m["hours"][route["hours"]]
        is_open = not self.closed[route["hours"]] and opened(h, when)
        self.follow(path, route["open" if is_open else "closed"], frozenset())
        return path


def in_days(days, weekday):
    """Whether WEEKDAY (0 is sunday) is one of DAYS, as `open.*.days`
    describes them."""
    if days == "*":
        return True
    for part in days.split("&"):
        first, _, last = part.partition("-")
        a = DAYS.index(first)
        b = DAYS.index(last) if last else a
        if a <= weekday <= b:
            return True
    return False


def minutes(time):
    start, end = time.split("-")
    return tuple(int(t[:2]) * 60 + int(t[3:]) for t in (start, end))


def holiday(h, date):
    for day in h.get("holidays", []):
        month, _, span = day.partition(" ")
        first, _, last = span.partition("-")
        if date.month == list(generate.MONTHS).index(month) + 1 and int(first) <= date.day <= int(last or first):
            return True
    return False


def opened(h, when):
    """Whether hours H are open at WHEN, as `open` and `holidays` describe
    them: open on the listed days, from the start of the first minute to the
    end of the last, in `timezone`, and closed on holidays."""
    local = when.astimezone(zoneinfo.ZoneInfo(h["timezone"]))
    if holiday(h, local.date()):
        return False
    weekday = (local.weekday() + 1) % 7
    minute = local.hour * 60 + local.minute
    return any(in_days(r["days"], weekday) and minutes(r["time"])[0] <= minute <= minutes(r["time"])[1] for r in h["open"])


def instants(h, rng):
    """Instants at which H is clearly open, closed, or closed for a holiday,
    each at least a minute from an edge and on a day without a clock change:
    the edges are the hours oracle's."""
    zone = zoneinfo.ZoneInfo(h["timezone"])
    found = {}
    days = list(range(10, 355))
    rng.shuffle(days)
    for offset in days:
        date = datetime.date(2027, 1, 1) + datetime.timedelta(days=offset)
        start = datetime.datetime.combine(date, datetime.time(0, 0), zone)
        end = datetime.datetime.combine(date, datetime.time(23, 59), zone)
        if start.utcoffset() != end.utcoffset():
            continue
        weekday = (date.weekday() + 1) % 7
        covered = set()
        for r in h["open"]:
            if in_days(r["days"], weekday):
                a, b = minutes(r["time"])
                covered.update(range(a - 1, b + 2))
        inside = [(a + b) // 2 for a, b in (minutes(r["time"]) for r in h["open"] if in_days(r["days"], weekday)) if b - a >= 2]
        outside = [x for x in range(0, 24 * 60, 7) if x not in covered]
        at = lambda minute: datetime.datetime.combine(date, datetime.time(minute // 60, minute % 60), zone)  # noqa: E731
        if holiday(h, date):
            if inside and "holiday" not in found:
                found["holiday"] = at(inside[0])
            continue
        if inside and "open" not in found:
            found["open"] = at(rng.choice(inside))
        if outside and "closed" not in found:
            found["closed"] = at(rng.choice(outside))
        if len(found) == 3 or (len(found) == 2 and not h.get("holidays")):
            break
    return found


def plan(m, seed):
    """The probe's calls for model M, each with its prediction, in the
    order they run: closing early changes the calls after it, which have
    `state`."""
    rng = random.Random(seed)
    oracle = Oracle(m)
    calls = []

    def add(call, path, why, state):
        prediction = {"rejected": True} if getattr(path, "rejected", False) else path.prediction()
        limit = path.seconds + (6 if path.long else 20)
        calls.append({"call": call | {"limit": limit}, "expect": prediction, "why": why} | ({"state": True} if state else {}))

    def internal(number, keys="", why=None, state=False):
        callerid = rng.choice(sorted(m["extensions"]))
        call = {"extension": number, "context": "pbx-internal", "callerId": f'"campaign" <{callerid}>'}
        if keys:
            call["keys"] = keys
        why = why or f"dial {number}" + (f" then {keys}" if keys else "")
        try:
            path = oracle.internal(number, keys, callerid)
        except Loop as loop:
            calls.append({"skipped": f"loop through {loop} (F1)", "why": why})
            return
        add(call, path, why, state)

    def inbound(trunk, did, when, why, state=False):
        call = {"extension": did, "context": f"pbx-inbound-{trunk}"}
        if when is not None:
            call["time"] = when.isoformat()
        try:
            path = oracle.inbound(trunk, did, when)
        except Loop as loop:
            calls.append({"skipped": f"loop through {loop} (F1)", "why": why})
            return
        add(call, path, why, state)

    owned = oracle.numbers()
    for number, (kind, name) in sorted(owned.items()):
        if kind == "closeEarly":
            continue
        internal(number)
        if kind == "ivr":
            i = m["ivrs"][name]
            for key in sorted(i.get("options", {})):
                internal(number, key)
            unused = [k for k in "0123456789*#" if k not in i.get("options", {}) and not (i.get("directDial") and any(e.startswith(k) for e in m["extensions"]))]
            if unused:
                internal(number, rng.choice(unused))
            if i.get("directDial"):
                internal(number, rng.choice(sorted(m["extensions"])))
    # prefixes of the numbers, numbers outside, and numbers nobody has
    for number in sorted(owned):
        for k in range(1, len(number)):
            if number[:k] not in owned:
                internal(number[:k], why=f"dial {number[:k]}, a prefix of {number}")
    if m["outbound"]:
        for _ in range(2):
            outside = "".join(rng.choice("0123456789") for _ in range(rng.randint(3, 10)))
            internal(m["outbound"]["prefix"] + outside, why=f"dial {outside} outside")
    for _ in range(2):
        number = rng.choice(["", "*", "#"]) + "".join(rng.choice("0123456789") for _ in range(rng.randint(2, 6)))
        if number not in owned:
            internal(number, why=f"dial {number}, which nobody has")

    for did, route in sorted(m["inbound"].items()):
        if "hours" in route:
            for which, when in sorted(instants(m["hours"][route["hours"]], rng).items()):
                inbound(route["trunk"], did, when, f"{did} from {route['trunk']} at {when.isoformat()} ({which})")
        else:
            inbound(route["trunk"], did, None, f"{did} from {route['trunk']}")
        others = [t for t in m["trunks"] if t != route["trunk"]]
        if others:
            inbound(rng.choice(others), did, None, f"{did} from another trunk")
    for trunk in m["trunks"]:
        did = "".join(rng.choice("0123456789") for _ in range(7))
        if did not in m["inbound"]:
            inbound(trunk, did, None, f"{did}, a number without a route, from {trunk}")

    # closing early: a call while open, the toggle, the same call again, and
    # the toggle back
    for name, h in sorted(m["hours"].items()):
        if "closeEarly" not in h:
            continue
        routes = [(did, r) for did, r in sorted(m["inbound"].items()) if r.get("hours") == name]
        when = instants(h, rng).get("open")
        for toggle in range(2):
            if routes and when:
                did, r = routes[0]
                inbound(r["trunk"], did, when, f"{did} at {when.isoformat()}, {'closed early' if oracle.closed[name] else 'open'}", True)
            internal(h["closeEarly"], why=f"close {name} early" if toggle == 0 else f"open {name} again", state=True)
        if routes and when:
            did, r = routes[0]
            inbound(r["trunk"], did, when, f"{did} at {when.isoformat()}, open again", True)
    return calls


def ways_out(m):
    """The numbers outside that calls from the trunks reach, as (the trunk a
    call comes from, the trunk it goes out through, the number): from each
    route of `inbound`, through every destination a call can take whatever
    the time, the keys and who answers, to the numbers outside of the ring
    groups it reaches, called through the group's `trunk`, by default
    `outbound.trunk`. A group rings its members' phones, not their
    extensions' destinations."""
    found = set()
    outbound = (m["outbound"] or {}).get("trunk")
    for route in m["inbound"].values():
        seen = set()
        pending = [route[slot] for slot in ["destination", "open", "closed"] if slot in route]
        while pending:
            (kind, value), = pending.pop().items()
            if kind not in ("extension", "ringGroup", "queue", "ivr") or (kind, value) in seen:
                continue
            seen.add((kind, value))
            o = m[generate.KIND_OPTION[kind]][value]
            if kind == "ringGroup":
                found.update((route["trunk"], o.get("trunk") or outbound, number) for number in o.get("external", []))
            pending += [o[slot] for slot in ["busy", "noAnswer", "noInput", "invalid"] if slot in o]
            pending += list(o.get("options", {}).values())
            if kind == "ivr" and o.get("directDial"):
                pending += [{"extension": number} for number in m["extensions"]]
    return found


# the contexts of pbx objects
OBJECT_PREFIXES = tuple(f"pbx-{k}-" for k in KIND_CONTEXT.values())


def fits(expected, data):
    """Whether a step's DATA is what EXPECTED says: anything (None), exactly
    a string, or its first or second argument ({"first": v}, {"second": v})."""
    if expected is None:
        return True
    if isinstance(expected, str):
        return data == expected
    fields = data.split(",")
    if "first" in expected:
        return fields[0] == expected["first"]
    return len(fields) > 1 and fields[1] == expected["second"]


def compare(m, expect, call):
    """The ways observed CALL differs from EXPECT, as (signature, text)."""
    own = [s for s in call["steps"] if s["channel"] == call["channel"]]
    if expect.get("rejected"):
        if own:
            return [("rejected: ran steps", f"expected no steps, ran {[(s['context'], s['application']) for s in own]}")]
        return []
    problems = []
    kinds = "+".join(expect["kinds"]) or "number"
    contexts = []
    for s in own:
        if s["context"].startswith(OBJECT_PREFIXES) or s["context"] in m["contexts"]:
            if not contexts or contexts[-1] != s["context"]:
                contexts.append(s["context"])
    if contexts != expect["contexts"]:
        problems.append((f"contexts ({kinds})", f"expected {expect['contexts']}, got {contexts}"))
    position = 0
    for app, data in expect["apps"]:
        while position < len(own) and not (own[position]["application"].lower() == app.lower() and fits(data, own[position]["data"])):
            position += 1
        if position == len(own):
            problems.append((f"missing {app} ({kinds})", f"expected {app}({data}) among {[(s['application'], s['data']) for s in own]}"))
            break
        position += 1
    last = own[-1]["application"] if own else None
    if expect["last"] is not None and (last or "").lower() != expect["last"].lower():
        problems.append((f"ended in {last} not {expect['last']} ({kinds})", f"last step {own[-1] if own else None}"))
    for app, start, extension in expect.get("legs", []):
        if not any(
            s["channel"] != call["channel"] and s["application"].lower() == app.lower() and s["data"].startswith(start) and s["extension"] == extension
            for s in call["steps"]
        ):
            problems.append((f"no leg {app} ({kinds})", f"expected a step {app}({start}...) of extension {extension} on another channel"))
    if expect["answered"] is not None and call["answered"] != expect["answered"]:
        problems.append((f"answered {call['answered']} ({kinds})", f"expected answered {expect['answered']}"))
    return problems
