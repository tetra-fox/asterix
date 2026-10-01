"""Random pbx configurations for the generated-configuration campaign
(configs.py), whose objects point at each other, and mutations that break
exactly one thing.

A configuration is a model: a dict with the options of `pbx` under their own
names, plus what they name in the core module: `trunks`, `mailboxes` (extra
mailboxes of voicemail.conf, `box` or `box@context`), `contexts` (hand-written
contexts, each a list of extensions), `queueMembers` (the members of each
queue in queues.conf), `bridges` and `users` (ConfBridge profiles). `modules`
turns a model into the JSON modules configs.nix evaluates. Values come from
the ranges the option descriptions give; `fast` keeps times short, so the
probe can follow every call.
"""

import copy
import random

from hypothesis import strategies as st

# the kinds a destination can name, as the option calls them
OBJECT_KINDS = ["extension", "ringGroup", "queue", "conference", "ivr"]
KIND_OPTION = {"extension": "extensions", "ringGroup": "ringGroups", "queue": "queues", "conference": "conferences", "ivr": "ivrs"}

# names that stay clear of what the dialplan reads specially, and a wider
# set with characters some descriptions rule out (`named`); m_bad_name uses
# the ones every description rules out
SAFE_NAME = st.text("abcdefghijklmnopqrstuvwxyz0123456789-_", min_size=1, max_size=10)
WIDE_NAME = st.text("abcdefghijklmnopqrstuvwxyzABC0123456789-_.+@/ &|!#*:%~=(){}^é", min_size=1, max_size=12)


def named(option, name, closeEarly=False, external=False):
    """Whether the descriptions of pbx.<option> allow NAME."""
    trailing = name != name.rstrip() or "\n" in name
    # a ( without a ) after it
    depth = 0
    for c in name:
        depth = depth + 1 if c == "(" else max(depth - 1, 0) if c == ")" else depth
    unclosed = depth > 0
    common = any(c in name for c in ',;[]') or "${" in name or "$[" in name or trailing
    if option == "ivrs":
        return name != "" and all(c.isascii() and (c.isalnum() or c in "_-") for c in name)
    if option == "ringGroups":
        return not (common or any(c in name for c in '"\\') or unclosed or (external and "&" in name))
    if option == "queues":
        return name != "" and not (common or any(c in name for c in '"\\') or unclosed or len(name.encode()) > 79 or name != name.lstrip())
    if option == "conferences":
        return name != "" and not (common or any(c in name for c in '"\\') or unclosed or len(name.encode()) > 79)
    if option == "paging":
        return not (common or any(c in name for c in '"\\()^'))
    if option == "hours":
        return not (common or "(" in name or (closeEarly and (any(c in name for c in "&=") or len(name.encode()) > 62)))
    return True


TIMEZONES = ["UTC", "America/Los_Angeles", "Europe/Berlin", "Asia/Kolkata", "Australia/Lord_Howe", "America/Sao_Paulo", "Pacific/Auckland"]
DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
MONTHS = {"jan": 31, "feb": 29, "mar": 31, "apr": 30, "may": 31, "jun": 30, "jul": 31, "aug": 31, "sep": 30, "oct": 31, "nov": 30, "dec": 31}
EMERGENCY = ["911", "112", "999", "000", "110"]
# core sounds, short, so a menu's prompt takes little time
SOUNDS = ["beep", "silence/1"]
TEXTS = ["For sales, press 1.", "Welcome.", "Press 2 for support, or stay on the line."]
# chan_pjsip takes this number as a call pickup (features.conf pickupexten)
PICKUP = "*8"


def secret(name):
    """A secret reference; a secret's path holds letters, digits and _.+/=-"""
    return {"_secret": "/run/secrets/" + name.replace("@", "-at-").replace("*", "star").replace("#", "hash")}


def number_strategy():
    """A number phones dial: digits, and now and then * or #."""
    return st.one_of(
        st.text("0123456789", min_size=2, max_size=5),
        st.builds(lambda a, b: a + b, st.sampled_from(["*", "#", "*9"]), st.text("0123456789", min_size=1, max_size=3)),
    )


def seconds(draw, fast):
    """A positive integer: short with `fast`, else now and then far from the
    usual."""
    if fast:
        return draw(st.integers(1, 2))
    return draw(st.one_of(st.integers(1, 60), st.integers(1, 10**6), st.sampled_from([2**31 - 1, 2**31, 2**32])))


# the extension numbers and trunks of the VM tier (vm.nix)
POOL = ["201", "202", "203", "204"]
VM_TRUNKS = ["provider", "second"]


@st.composite
def configurations(draw, fast=False, wide=False, vm=False):
    """A valid configuration; with `vm`, its extensions and trunks are the
    ones vm.nix has phones and a provider for."""
    names = WIDE_NAME if wide and draw(st.booleans()) else SAFE_NAME
    taken = set()

    def fresh_number():
        n = draw(number_strategy().filter(lambda n: n not in taken and n != PICKUP))
        taken.add(n)
        return n

    def fresh_names(k, alphabet):
        """K distinct names"""
        result = []
        while len(result) < k:
            name = draw(alphabet)
            if name not in result:
                result.append(name)
        return result

    def name_for(option, **rule):
        """A name of pbx.OPTION the descriptions allow, new in the model;
        conferences apart without regard to case"""
        fold = option == "conferences"
        taken_names = {n.lower() if fold else n for n in m[option]}
        return draw(names.filter(lambda n: named(option, n, **rule) and (n.lower() if fold else n) not in taken_names))

    m = {
        "extensions": {},
        "ringGroups": {},
        "queues": {},
        "conferences": {},
        "ivrs": {},
        "paging": {},
        "hours": {},
        "inbound": {},
        "outbound": None,
        "emergency": None,
        "voicemailMenu": None,
        # a trunk is an endpoint, as an extension is, so a trunk's name has a
        # letter, which no extension number has
        "trunks": VM_TRUNKS[: draw(st.integers(1, 2))] if vm else fresh_names(draw(st.integers(1, 3)), SAFE_NAME.filter(lambda n: any(c.isalpha() for c in n))),
        "mailboxes": [],
        "contexts": {},
        "queueMembers": {},
        "bridges": [],
        "users": [],
    }

    # the outbound prefix first: an emergency number with it is a number too
    if draw(st.booleans()):
        m["outbound"] = {
            "prefix": draw(st.sampled_from(["9", "0", "#", "*9", "99", ""])),
            "trunk": draw(st.sampled_from(m["trunks"])),
        }
        if draw(st.booleans()):
            m["outbound"]["callerId"] = draw(st.text("0123456789", min_size=3, max_size=10))
    if draw(st.floats(0, 1)) < 0.4:
        numbers = draw(st.lists(st.sampled_from(EMERGENCY), min_size=1, max_size=2, unique=True))
        prefix = m["outbound"]["prefix"] if m["outbound"] else ""
        dialled = set(numbers) | {prefix + n for n in numbers}
        if not dialled & taken and PICKUP not in dialled:
            taken.update(dialled)
            m["emergency"] = {"numbers": numbers, "trunk": draw(st.sampled_from(m["trunks"]))}
            # pbx warns about emergency calls without a caller ID of their own
            # or pbx.outbound's
            if "callerId" not in (m["outbound"] or {}) or draw(st.booleans()):
                m["emergency"]["callerId"] = draw(st.text("0123456789", min_size=3, max_size=10))

    numbers = draw(st.lists(st.sampled_from(POOL), min_size=1, max_size=4, unique=True)) if vm else [fresh_number() for _ in range(draw(st.integers(1, 5)))]
    taken.update(numbers)
    for number in numbers:
        e = {"password": secret(f"sip-{number}")}
        # the mailbox is named like the number, and a mailbox number cannot
        # start with * or #
        if number[0] not in "*#" and draw(st.booleans()):
            e["voicemail"] = {"pin": secret(f"vm-{number}")}
            if draw(st.floats(0, 1)) < 0.2:
                e["voicemail"]["email"] = "office@example.com"
        if draw(st.floats(0, 1)) < 0.3:
            # Nix strings hold no NUL, so no control characters at all; the
            # mailbox owner's name has no comma, nor a space at the end of the
            # mailbox line, which Asterisk would drop
            e["name"] = draw(
                st.text(st.characters(exclude_categories=["Cc", "Cs"]), min_size=1, max_size=20).filter(
                    lambda s: len(s.encode()) <= 79
                    and ("voicemail" not in e or ("," not in s and ("email" in e["voicemail"] or not s.endswith(" "))))
                )
            )
        # with `fast` a phone that rings, in the VMs, rings briefly
        if fast or draw(st.booleans()):
            e["ringTime"] = seconds(draw, fast)
        m["extensions"][number] = e
    extensions = list(m["extensions"])

    boxes = [b for b in ["200", "300", "200@sales", "400@support"] if b not in m["extensions"]]
    m["mailboxes"] = draw(st.lists(st.sampled_from(boxes), max_size=2, unique=True))
    for name in fresh_names(draw(st.integers(0, 2)), st.sampled_from(["hand-a", "hand-b", "hand-c"])):
        m["contexts"][name] = draw(st.lists(st.sampled_from(["s", "100", "x1"]), min_size=1, max_size=2, unique=True))
    m["bridges"] = draw(st.lists(st.sampled_from(["quiet", "large"]), max_size=2, unique=True))
    m["users"] = draw(st.lists(st.sampled_from(["chair", "guest"]), max_size=2, unique=True))

    for _ in range(draw(st.integers(0, 3))):
        g = {"members": draw(st.lists(st.sampled_from(extensions), max_size=3, unique=True))}
        if not g["members"] or draw(st.floats(0, 1)) < 0.2:
            g["external"] = draw(st.lists(st.text("0123456789", min_size=3, max_size=10), min_size=1, max_size=2, unique=True))
            if m["outbound"] is None or draw(st.booleans()):
                g["trunk"] = draw(st.sampled_from(m["trunks"]))
        if draw(st.booleans()):
            g["strategy"] = draw(st.sampled_from(["ringall", "hunt"]))
        if fast or draw(st.booleans()):
            g["ringTime"] = seconds(draw, fast)
        m["ringGroups"][name_for("ringGroups", external="external" in g)] = g

    for _ in range(draw(st.integers(0, 2))):
        name = name_for("queues")
        q = {}
        if draw(st.booleans()) or fast:
            q["timeout"] = seconds(draw, fast)
        m["queues"][name] = q
        m["queueMembers"][name] = [f"PJSIP/{e}" for e in draw(st.lists(st.sampled_from(extensions), max_size=2, unique=True))]

    for _ in range(draw(st.integers(0, 2))):
        name = name_for("conferences")
        c = {}
        if m["bridges"] and draw(st.booleans()):
            c["bridgeProfile"] = draw(st.sampled_from(m["bridges"]))
        if m["users"] and draw(st.booleans()):
            c["userProfile"] = draw(st.sampled_from(m["users"]))
        m["conferences"][name] = c

    # voice menu names are letters, digits, _ and -
    for name in fresh_names(draw(st.integers(0, 2)), st.text("abcdefghijklmnopqrstuvwxyzABC0123456789-_", min_size=1, max_size=10)):
        i = {"prompt": {"sound": draw(st.sampled_from(SOUNDS))} if fast or draw(st.booleans()) else {"text": draw(st.sampled_from(TEXTS))}}
        if fast:
            i["timeout"] = draw(st.integers(1, 2))
            i["attempts"] = draw(st.integers(1, 2))
        else:
            if draw(st.booleans()):
                i["timeout"] = seconds(draw, fast)
            if draw(st.booleans()):
                i["attempts"] = draw(st.integers(1, 5))
        if draw(st.floats(0, 1)) < 0.3:
            i["directDial"] = True
        m["ivrs"][name] = i

    for _ in range(draw(st.integers(0, 1))):
        name = name_for("paging")
        p = {"number": fresh_number(), "members": draw(st.lists(st.sampled_from(extensions), min_size=1, max_size=3, unique=True))}
        if draw(st.booleans()):
            p["duplex"] = draw(st.booleans())
        if draw(st.booleans()):
            p["skipBusy"] = draw(st.booleans())
        m["paging"][name] = p

    for _ in range(draw(st.integers(0, 2))):
        h = {"timezone": draw(st.sampled_from(TIMEZONES)), "open": draw(st.lists(ranges(), min_size=1, max_size=3))}
        if draw(st.booleans()):
            h["holidays"] = draw(st.lists(holidays(), max_size=2, unique=True))
        if draw(st.booleans()):
            h["closeEarly"] = fresh_number()
        m["hours"][name_for("hours", closeEarly="closeEarly" in h)] = h

    # numbers of the objects; a menu option key that is an extension number
    # would clash with directDial
    for kind in ["ringGroups", "queues", "conferences", "ivrs"]:
        for o in m[kind].values():
            if draw(st.floats(0, 1)) < 0.8:
                o["number"] = fresh_number()
    if draw(st.floats(0, 1)) < 0.3:
        m["voicemailMenu"] = fresh_number()

    # the destinations, now that every object exists
    def destination():
        choices = ["hangup", "voicemail", "context"] + [k for k in OBJECT_KINDS if m[KIND_OPTION[k]]]
        kind = draw(st.sampled_from(choices))
        if kind == "hangup":
            return {"hangup": True}
        if kind == "voicemail":
            boxes = [e for e in extensions if "voicemail" in m["extensions"][e]] + m["mailboxes"]
            if not boxes:
                return {"hangup": True}
            box = draw(st.sampled_from(boxes))
            if draw(st.booleans()):
                return {"voicemail": {"mailbox": box, "greeting": draw(st.sampled_from(["unavailable", "busy"]))}}
            return {"voicemail": box}
        if kind == "context":
            if not m["contexts"]:
                return {"hangup": True}
            context = draw(st.sampled_from(sorted(m["contexts"])))
            d = {"context": context}
            extension = draw(st.sampled_from(m["contexts"][context]))
            if extension != "s" or draw(st.booleans()):
                d["extension"] = extension
            priority = draw(st.sampled_from([1, 2, "two"]))
            if priority != 1 or draw(st.booleans()):
                d["priority"] = priority
            return {"context": d}
        return {kind: draw(st.sampled_from(sorted(m[KIND_OPTION[kind]])))}

    for e in m["extensions"].values():
        for slot in ["noAnswer", "busy"]:
            if draw(st.floats(0, 1)) < 0.4:
                e[slot] = destination()
    for g in m["ringGroups"].values():
        if draw(st.booleans()):
            g["noAnswer"] = destination()
    for q in m["queues"].values():
        if draw(st.booleans()):
            q["noAnswer"] = destination()
    for i in m["ivrs"].values():
        keys = draw(st.lists(st.sampled_from(list("0123456789*#")), max_size=3, unique=True))
        if i.get("directDial"):
            keys = [k for k in keys if k not in m["extensions"]]
        i["options"] = {k: destination() for k in keys}
        for slot in ["noInput", "invalid"]:
            if draw(st.booleans()):
                i[slot] = destination()

    for _ in range(draw(st.integers(0, 3))):
        did = draw(st.one_of(st.text("0123456789", min_size=3, max_size=11), st.builds(lambda d: "+" + d, st.text("0123456789", min_size=4, max_size=11))))
        if did in m["inbound"] or did == PICKUP:
            continue
        route = {"trunk": draw(st.sampled_from(m["trunks"]))}
        if m["hours"] and draw(st.booleans()):
            route["hours"] = draw(st.sampled_from(sorted(m["hours"])))
            route["open"] = destination()
            route["closed"] = destination()
        else:
            route["destination"] = destination()
        m["inbound"][did] = route

    if m["emergency"] and draw(st.booleans()):
        m["emergency"]["notify"] = draw(st.lists(st.sampled_from(extensions), max_size=2, unique=True))
    return m


@st.composite
def ranges(draw):
    """An opening range that does not pass midnight and whose days do not
    wrap around the week; the hours oracle covers those."""
    first = draw(st.integers(0, 6))
    kind = draw(st.sampled_from(["one", "range", "and", "all"]))
    if kind == "one":
        days = DAYS[first]
    elif kind == "range":
        last = draw(st.integers(first, 6))
        days = DAYS[first] if last == first else f"{DAYS[first]}-{DAYS[last]}"
    elif kind == "and":
        second = draw(st.integers(0, 6).filter(lambda d: d != first))
        days = f"{DAYS[first]}&{DAYS[second]}"
    else:
        days = "*"
    start = draw(st.integers(0, 23 * 60 + 58))
    end = draw(st.integers(start + 1, 23 * 60 + 59))
    return {"days": days, "time": f"{start // 60:02}:{start % 60:02}-{end // 60:02}:{end % 60:02}"}


@st.composite
def holidays(draw):
    month = draw(st.sampled_from(sorted(MONTHS)))
    first = draw(st.integers(1, MONTHS[month]))
    if draw(st.booleans()):
        return f"{month} {first}"
    return f"{month} {first}-{draw(st.integers(first, MONTHS[month]))}"


def destinations(m):
    """Every destination slot of a model, as (where, destination, setter);
    the setter replaces the destination, or with None removes it where the
    slot is optional."""
    slots = []

    def slot(where, parent, key, optional):
        def put(value):
            if value is None and optional:
                del parent[key]
            else:
                parent[key] = value if value is not None else {"hangup": True}

        slots.append((where, parent[key], put))

    for n, e in m["extensions"].items():
        for s in ["noAnswer", "busy"]:
            if s in e:
                slot(f'pbx.extensions."{n}".{s}', e, s, True)
    for kind in ["ringGroups", "queues"]:
        for n, o in m[kind].items():
            if "noAnswer" in o:
                slot(f"pbx.{kind}.{n}.noAnswer", o, "noAnswer", True)
    for n, i in m["ivrs"].items():
        for k in list(i.get("options", {})):
            slot(f'pbx.ivrs.{n}.options."{k}"', i["options"], k, True)
        for s in ["noInput", "invalid"]:
            if s in i:
                slot(f"pbx.ivrs.{n}.{s}", i, s, True)
    for did, r in m["inbound"].items():
        for s in ["destination", "open", "closed"]:
            if s in r:
                slot(f'pbx.inbound."{did}".{s}', r, s, False)
    return slots


def mailbox_key(box):
    return box if "@" in box else f"{box}@default"


def exists(m, dest):
    """Whether what DEST names exists in M."""
    (kind, value), = dest.items()
    if kind in KIND_OPTION:
        return value in m[KIND_OPTION[kind]]
    if kind == "voicemail":
        box = mailbox_key(value if isinstance(value, str) else value["mailbox"])
        return box in {mailbox_key(b) for b in m["mailboxes"]} | {f"{e}@default" for e, x in m["extensions"].items() if "voicemail" in x}
    if kind == "context":
        return value["context"] in m["contexts"] and value.get("extension", "s") in m["contexts"][value["context"]]
    return True


def repair(m):
    """M without references to what it lacks, after something was removed:
    such destinations hang up, members go, and what is left empty goes."""
    while True:
        before = copy.deepcopy(m)
        for _, dest, put in destinations(m):
            if not exists(m, dest):
                put(None)
        for name, g in list(m["ringGroups"].items()):
            g["members"] = [e for e in g["members"] if e in m["extensions"]]
            if g.get("trunk") not in (None, *m["trunks"]):
                del g["trunk"]
            if g.get("external") and "trunk" not in g and not m["outbound"]:
                del g["external"]
            if not g["members"] and not g.get("external"):
                del m["ringGroups"][name]
        for name, p in list(m["paging"].items()):
            p["members"] = [e for e in p["members"] if e in m["extensions"]]
            if not p["members"]:
                del m["paging"][name]
        for name in list(m["queueMembers"]):
            if name not in m["queues"]:
                del m["queueMembers"][name]
            else:
                m["queueMembers"][name] = [x for x in m["queueMembers"][name] if x.removeprefix("PJSIP/") in m["extensions"]]
        for c in m["conferences"].values():
            for field, known in [("bridgeProfile", m["bridges"]), ("userProfile", m["users"])]:
                if field in c and c[field] not in known:
                    del c[field]
        for key in ["outbound", "emergency"]:
            if m[key] and m[key]["trunk"] not in m["trunks"]:
                m[key] = None
        if m["emergency"] and "notify" in m["emergency"]:
            m["emergency"]["notify"] = [e for e in m["emergency"]["notify"] if e in m["extensions"]]
        for did, r in list(m["inbound"].items()):
            if r["trunk"] not in m["trunks"]:
                del m["inbound"][did]
            elif "hours" in r and r["hours"] not in m["hours"]:
                m["inbound"][did] = {"trunk": r["trunk"], "destination": r["open"]}
        if m == before:
            return m


def reductions(m):
    """Models one step smaller than M, each repaired."""
    def variant(change):
        n = copy.deepcopy(m)
        change(n)
        return repair(n)

    for option in ["extensions", "ringGroups", "queues", "conferences", "ivrs", "paging", "hours", "inbound", "contexts"]:
        for key in list(m[option]):
            yield variant(lambda n, option=option, key=key: n[option].pop(key))
    for key in ["outbound", "emergency", "voicemailMenu"]:
        if m[key] is not None:
            yield variant(lambda n, key=key: n.__setitem__(key, None))
    for key in ["trunks", "mailboxes", "bridges", "users"]:
        if len(m[key]) > (1 if key == "trunks" else 0):
            for i in range(len(m[key])):
                yield variant(lambda n, key=key, i=i: n[key].pop(i))
    for i, (_, dest, _) in enumerate(destinations(m)):
        if dest != {"hangup": True}:
            yield variant(lambda n, i=i: destinations(n)[i][2](None))
    # optional fields, and the items of lists
    required = {"password", "trunk", "prompt", "timezone", "open", "number", "members"}
    for option in ["extensions", "ringGroups", "queues", "conferences", "ivrs", "paging", "hours"]:
        for key, o in m[option].items():
            for field, value in o.items():
                if field not in required or (option != "paging" and field == "number"):
                    yield variant(lambda n, option=option, key=key, field=field: n[option][key].pop(field))
                if isinstance(value, list) and len(value) > 1:
                    for i in range(len(value)):
                        yield variant(lambda n, option=option, key=key, field=field, i=i: n[option][key][field].pop(i))
    for key in ["outbound", "emergency"]:
        if m[key]:
            for field in ["callerId", "notify"]:
                if field in m[key]:
                    yield variant(lambda n, key=key, field=field: n[key].pop(field))


def modules(m, host=None):
    """The JSON module of a model, as configs.nix decodes it; every trunk's
    provider is HOST if given."""
    pbx = {"enable": True}
    for option in ["extensions", "ringGroups", "queues", "conferences", "ivrs", "paging", "hours", "inbound"]:
        if m[option]:
            pbx[option] = copy.deepcopy(m[option])
    for option in ["outbound", "emergency", "voicemailMenu"]:
        if m[option] is not None:
            pbx[option] = copy.deepcopy(m[option])
    asterisk = {
        "pjsip": {
            "transports": {"udp": {}},
            "trunks": {
                t: {"host": host or f"sip-{i}.provider.example", "username": f"555{i}000", "password": secret(f"trunk-{i}")}
                for i, t in enumerate(m["trunks"])
            },
        },
    }
    if m["mailboxes"]:
        asterisk["voicemail"] = {"mailboxes": {box: {"pin": secret(f"vm-{box}")} for box in m["mailboxes"]}}
    # an e-mail address needs a command that sends it (voicemail.email)
    if any("email" in e.get("voicemail", {}) for e in m["extensions"].values()):
        asterisk.setdefault("voicemail", {})["email"] = {"command": "/run/current-system/sw/bin/msmtp -t"}
    if m["queueMembers"]:
        asterisk["queues"] = {"queues": {q: {"members": members} for q, members in m["queueMembers"].items()}}
    if m["contexts"]:
        asterisk["dialplan"] = {"contexts": {c: {"extensions": {x: hand_steps(c, x) for x in xs}} for c, xs in m["contexts"].items()}}
    if m["bridges"] or m["users"]:
        asterisk["confbridge"] = {"bridges": {b: {} for b in m["bridges"]}, "users": {u: {} for u in m["users"]}}
    return {"pbx": pbx, "services": {"asterisk": asterisk}}


def hand_steps(context, extension):
    """The steps of an extension of a hand-written context: each names where
    it is, so a call shows the priority it arrived at."""
    return [
        f"NoOp(mark {context} {extension} 1)",
        {"app": "NoOp", "args": [f"mark {context} {extension} 2"], "label": "two"},
        "Hangup()",
    ]


# keys whose value one module defines whole: a destination, a prompt and a
# secret
ATOMIC = {"noAnswer", "busy", "destination", "closed", "noInput", "invalid", "prompt", "password", "pin"}


def split(module, parts, rng):
    """MODULE spread over PARTS modules at random, and the one module that
    the parts should evaluate like: the items of a list, spread over the
    parts, follow the order of the parts, as the module system concatenates
    the definitions of a list in module order. Attribute sets spread their
    keys, lists their items."""
    out = [dict() for _ in range(parts)]

    def spread(value, path, targets):
        """Puts VALUE at PATH into the modules TARGETS; returns what the
        combined module holds there."""
        if isinstance(value, dict) and value and path[-1:] and path[-1] not in ATOMIC and not is_destination(path) and "_secret" not in value:
            merged = {}
            for key, v in value.items():
                merged[key] = spread(v, path + [key], [rng.choice(targets)] if rng.random() < 0.7 else targets)
            return merged
        if isinstance(value, list) and len(targets) > 1 and value:
            chunks = {t: [] for t in targets}
            for item in value:
                chunks[rng.choice(targets)].append(item)
            for t in targets:
                if chunks[t]:
                    put(t, path, chunks[t])
            return [item for t in sorted(targets) for item in chunks[t]]
        target = rng.choice(targets)
        put(target, path, value)
        return value

    def put(t, path, value):
        node = out[t]
        for key in path[:-1]:
            node = node.setdefault(key, {})
        node[path[-1]] = value

    merged = {key: spread(value, [key], list(range(parts))) for key, value in module.items()}
    return [o for o in out if o], merged


def is_destination(path):
    """Whether PATH is a destination slot of a pbx object."""
    return (len(path) >= 2 and path[-2] == "options" and path[0] == "pbx") or (len(path) >= 3 and path[1] == "inbound" and path[-1] == "open")


# Mutations: each breaks one thing the descriptions or README call broken
# and returns a label, or None where the model has nothing to break that way


def m_dangling(m, rng):
    """A destination names an object that does not exist."""
    slots = destinations(m)
    if not slots:
        return None
    where, _, put = rng.choice(slots)
    kind = rng.choice(OBJECT_KINDS)
    put({kind: "missing"})
    return f"dangling {kind} at {where}"


def m_mailbox(m, rng):
    """A voicemail destination names a mailbox voicemail.conf lacks."""
    slots = destinations(m)
    if not slots:
        return None
    where, _, put = rng.choice(slots)
    put({"voicemail": rng.choice(["999", "999@default", "200@nowhere"])})
    return f"missing mailbox at {where}"


def m_context(m, rng):
    """A context destination names a context that does not exist."""
    slots = destinations(m)
    if not slots:
        return None
    where, _, put = rng.choice(slots)
    put({"context": {"context": "no-such-context"}})
    return f"missing context at {where}"


def m_member(m, rng):
    """A ring group, page or emergency notify names a missing extension."""
    lists = [(f"pbx.ringGroups.{n}.members", g["members"]) for n, g in m["ringGroups"].items()]
    lists += [(f"pbx.paging.{n}.members", p["members"]) for n, p in m["paging"].items()]
    if m["emergency"]:
        lists.append(("pbx.emergency.notify", m["emergency"].setdefault("notify", [])))
    if not lists:
        return None
    where, members = rng.choice(lists)
    members.append(missing_number(m))
    return f"missing extension in {where}"


def missing_number(m):
    n = 7000
    while str(n) in m["extensions"]:
        n += 1
    return str(n)


def numbered(m):
    """Every number the configuration has, with a setter."""
    result = []
    for kind in ["ringGroups", "queues", "conferences", "ivrs", "paging"]:
        for n, o in m[kind].items():
            if "number" in o:
                result.append((f"pbx.{kind}.{n}.number", o["number"], lambda v, o=o: o.__setitem__("number", v)))
    for n, h in m["hours"].items():
        if "closeEarly" in h:
            result.append((f"pbx.hours.{n}.closeEarly", h["closeEarly"], lambda v, h=h: h.__setitem__("closeEarly", v)))
    if m["voicemailMenu"] is not None:
        result.append(("pbx.voicemailMenu", m["voicemailMenu"], lambda v: m.__setitem__("voicemailMenu", v)))
    return result


def m_clash(m, rng):
    """Two owners of one number."""
    owned = numbered(m)
    if not owned:
        return None
    where, _, put = rng.choice(owned)
    others = list(m["extensions"]) + [n for w, n, _ in owned if w != where]
    if m["emergency"]:
        others += m["emergency"]["numbers"]
    target = rng.choice(others)
    put(target)
    return f"{where} takes {target}"


def m_pickup(m, rng):
    """A number on the call pickup code, which chan_pjsip takes first."""
    owned = numbered(m)
    if not owned:
        return None
    where, _, put = rng.choice(owned)
    put(PICKUP)
    return f"{where} on {PICKUP}"


def m_malformed(m, rng):
    """A number phones cannot dial."""
    owned = numbered(m)
    if not owned:
        return None
    where, number, put = rng.choice(owned)
    put(number + rng.choice(["a", " ", "-", "+"]))
    return f"{where} not dialable"


def m_inbound_half(m, rng):
    """An inbound number with hours but no closed destination, or with both
    a destination and hours."""
    if not m["inbound"] or not m["hours"]:
        return None
    did = rng.choice(sorted(m["inbound"]))
    r = m["inbound"][did]
    if "destination" in r:
        r["hours"] = rng.choice(sorted(m["hours"]))
        return f'pbx.inbound."{did}" has destination and hours'
    del r[rng.choice(["open", "closed"])]
    return f'pbx.inbound."{did}" lacks open or closed'


def m_hours(m, rng):
    """An inbound number names hours that do not exist."""
    routes = [did for did, r in m["inbound"].items() if "hours" in r]
    if not routes:
        return None
    did = rng.choice(routes)
    m["inbound"][did]["hours"] = "missing"
    return f'pbx.inbound."{did}".hours missing'


def m_trunk(m, rng):
    """A trunk that services.asterisk.pjsip.trunks lacks."""
    users = [("pbx.inbound", r) for r in m["inbound"].values()]
    users += [("pbx.outbound", m["outbound"])] if m["outbound"] else []
    users += [("pbx.emergency", m["emergency"])] if m["emergency"] else []
    users += [(f"pbx.ringGroups.{n}", g) for n, g in m["ringGroups"].items() if "trunk" in g]
    if not users:
        return None
    where, o = rng.choice(users)
    o["trunk"] = "missing"
    return f"{where}.trunk missing"


def m_key(m, rng):
    """A menu key that is not one digit, * or #."""
    if not m["ivrs"]:
        return None
    name = rng.choice(sorted(m["ivrs"]))
    key = rng.choice(["12", "a", "", "**"])
    m["ivrs"][name].setdefault("options", {})[key] = {"hangup": True}
    return f"pbx.ivrs.{name}.options key {key!r}"


def m_queue(m, rng):
    """A queue that queues.conf lacks."""
    if not m["queues"]:
        return None
    name = rng.choice(sorted(m["queues"]))
    del m["queueMembers"][name]
    return f"pbx.queues.{name} not in queues.conf"


def m_profile(m, rng):
    """A conference profile that confbridge.conf lacks."""
    if not m["conferences"]:
        return None
    name = rng.choice(sorted(m["conferences"]))
    field = rng.choice(["bridgeProfile", "userProfile"])
    m["conferences"][name][field] = "missing"
    return f"pbx.conferences.{name}.{field} missing"


def m_empty_group(m, rng):
    """A ring group with neither members nor external numbers."""
    if not m["ringGroups"]:
        return None
    name = rng.choice(sorted(m["ringGroups"]))
    g = m["ringGroups"][name]
    g["members"] = []
    g.pop("external", None)
    return f"pbx.ringGroups.{name} rings nobody"


def m_no_trunk(m, rng):
    """A ring group with external numbers, no trunk and no pbx.outbound."""
    if not m["ringGroups"]:
        return None
    name = rng.choice(sorted(m["ringGroups"]))
    g = m["ringGroups"][name]
    g.setdefault("external", ["5559000"])
    g.pop("trunk", None)
    if m["outbound"]:
        return None
    return f"pbx.ringGroups.{name} external without a trunk"


def m_timezone(m, rng):
    """A time zone tzdata does not have."""
    if not m["hours"]:
        return None
    name = rng.choice(sorted(m["hours"]))
    m["hours"][name]["timezone"] = rng.choice(["Mars/Olympus_Mons", "America/Nowhere", "UTC/Plus"])
    return f"pbx.hours.{name}.timezone missing"


def m_name(m, rng):
    """An extension name longer than the 79 bytes the description allows."""
    if not m["extensions"]:
        return None
    number = rng.choice(sorted(m["extensions"]))
    m["extensions"][number]["name"] = "n" * rng.choice([80, 120])
    return f'pbx.extensions."{number}".name too long'


def m_mailbox_number(m, rng):
    """An extension with a mailbox on a number a mailbox cannot have."""
    number = rng.choice(["*", "#"]) + missing_number(m)
    m["extensions"][number] = {"password": secret("sip-mailbox"), "voicemail": {"pin": secret("vm-mailbox")}}
    return f'pbx.extensions."{number}".voicemail'


def m_bad_name(m, rng):
    """An object whose name its description rules out."""
    option = rng.choice(["ringGroups", "queues", "conferences", "paging", "hours", "ivrs"])
    name = rng.choice([n for n in ["a,b", "a;b", "a[b", 'a"b', "a${b}", "a(b", "a ", ""] if not named(option, n)])
    extension = rng.choice(sorted(m["extensions"]))
    m[option][name] = {
        "ringGroups": {"members": [extension]},
        "queues": {},
        "conferences": {},
        "paging": {"number": "7" + missing_number(m), "members": [extension]},
        "hours": {"timezone": "UTC", "open": [{"days": "*", "time": "09:00-17:00"}]},
        "ivrs": {"prompt": {"sound": "beep"}},
    }[option]
    if option == "queues":
        m["queueMembers"][name] = []
    return f"pbx.{option}.{name!r}"


def m_conference_case(m, rng):
    """Two conferences whose names differ only in case."""
    if not m["conferences"]:
        return None
    name = rng.choice(sorted(m["conferences"]))
    # ConfBridge compares names with strcasecmp, which folds ASCII letters only
    other = "".join(c.swapcase() if c.isascii() else c for c in name)
    if other == name:
        return None
    m["conferences"][other] = {}
    return f"pbx.conferences {name} and {other}"


MUTATIONS = [
    m_dangling, m_mailbox, m_context, m_member, m_clash, m_pickup, m_malformed, m_inbound_half, m_hours,
    m_trunk, m_key, m_queue, m_profile, m_empty_group, m_no_trunk, m_timezone, m_name, m_mailbox_number, m_bad_name, m_conference_case,
]


def mutate(m, mutation, seed):
    """The model with MUTATION applied, and its label; None when it does not
    apply."""
    m = copy.deepcopy(m)
    label = mutation(m, random.Random(seed))
    return (m, label) if label else None
