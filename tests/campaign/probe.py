#!/usr/bin/env python3
"""The T1 probe: CLI commands and calls on the Asterisk that the build-time
check boots (pkgs/config-check), in two steps (tests/campaign/probe.nix):

    probe.py drive SPEC OUT ASTERISK -C FILE
    probe.py report OUT

`drive` runs while Asterisk is up. It runs the commands, then places the
calls one after the other, each once the one before has ended, while
Asterisk logs to OUT/asterisk.log. `report` runs once Asterisk has stopped,
which writes out every message it still holds, and turns the log into
OUT/probe.json.

A call is a Local channel into `extension` of `context`, placed as a call
file (pbx_spool). Its other end is the caller: it sends `keys` as soon as the
call is answered (SendDTMF, where `w` waits half a second), then stays silent
until the call ends, so a voicemail ends 4 s after the beep. Nobody
registers, so a phone the dialplan rings is unavailable, or rings unanswered
at a static contact. `callerId` ("Name" <number>) is the caller ID the
dialplan sees, `time` (ISO 8601 with an offset) is the time GotoIfTime sees
(TESTTIME), and after `limit` seconds (60) the probe hangs up whatever is
left of the call.

Background() gets a key sent as the call is answered, WaitExten() right after
Answer() does not: the channel carries no audio, and Asterisk leaves the end
of such a digit in its queue until something wakes the channel
(main/channel.c __ast_read). Start the keys with `w` for such a menu.

probe.json holds each command with its output, and for each call:

- `channel`: the call's own channel, whose steps come first
- `steps`: every dialplan step the call's channels ran, in order, as
  channel, context, extension, priority, application and data
- `ended`: the step each channel's dialplan ended in, and `how`: `hangup`
  (an application ended the call, or the call ended while it ran),
  `fallthrough` (no step came next; `status` is DIALSTATUS), `invalid` (an
  extension that does not exist), `timeout` (no key and no `t` extension) or
  `error`
- `answered`, `limitReached`, `seconds`, and `log`: every message Asterisk
  logged during the call

Asterisk's JSON log format drops a message that is not valid UTF-8, so such
a step is missing, and cuts one longer than 8 KiB, which fails the report.
"""

import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import time

# where the caller's end of every call runs its dialplan
CONTEXT = "asterix-probe"
CALLER = [
    "wait,1,Wait(86400)",
    "keys,1,SendDTMF(${ASTERIX_PROBE_KEYS})",
    "keys,2,Wait(86400)",
    # a call to this extension after the last one marks where that one's log ends
    "end,1,Hangup()",
]
CALL_KEYS = {"extension", "context", "callerId", "time", "keys", "limit"}
LIMIT = 60
# the CLI client prints this itself where the machine has no ethernet
# interface, as the build sandbox has none (main/utils.c ast_set_default_eid)
EID_WARNING = "No ethernet interface found for seeding global EID. You will have to set it manually.\n"


def cli(asterisk, command):
    output = subprocess.run(
        [*asterisk, "-rx", command],
        capture_output=True,
        check=True,
        text=True,
        errors="backslashreplace",
    ).stdout
    return output.removeprefix(EID_WARNING)


def active_channels(asterisk):
    return int(re.search(r"^(\d+) active channels?$", cli(asterisk, "core show channels count"), re.M).group(1))


def call_file(call):
    """The call file of a call, as pbx_spool reads it."""
    unknown = set(call) - CALL_KEYS
    if unknown:
        raise ValueError(f"unknown keys {sorted(unknown)} in call {call}")
    for key, value in call.items():
        if isinstance(value, str) and re.search(r"[\x00-\x1f]", value):
            raise ValueError(f"{key} of call {call} contains a control character")
    if re.search(r"[@/]", call["extension"]) or "/" in call["context"]:
        raise ValueError(f"a Local channel cannot reach extension {call['extension']!r} of context {call['context']!r}")
    lines = [
        f"Channel: Local/{call['extension']}@{call['context']}/n",
        "MaxRetries: 0",
        # the probe ends the call after `limit` itself
        "WaitTime: 86400",
        f"Context: {CONTEXT}",
        f"Extension: {'keys' if call.get('keys') else 'wait'}",
        "Archive: yes",
    ]
    if "callerId" in call:
        lines.append(f"CallerID: {call['callerId']}")
    if call.get("keys"):
        lines.append(f"Setvar: ASTERIX_PROBE_KEYS={call['keys']}")
    if "time" in call:
        when = datetime.datetime.fromisoformat(call["time"])
        if when.tzinfo is None:
            raise ValueError(f"time {call['time']!r} needs an offset, such as Z or -08:00")
        # whole seconds, inherited by every channel of the call, as Asterisk's
        # TESTTIME() sets it (main/pbx.c testtime_write)
        lines.append(f"Setvar: __TESTTIME={int(when.timestamp())}")
    return "".join(line + "\n" for line in lines)


def place(asterisk, spool, name, text, limit):
    """Places a call and waits until it has ended and every channel is gone."""
    done = spool / "outgoing_done" / name
    start = time.monotonic()
    # pbx_spool reads a file once it is moved into outgoing/, and holds it until
    # time(2) reaches its mtime, which for a file written just now can be the next second
    (spool / name).write_text(text)
    os.utime(spool / name, (0, 0))
    os.rename(spool / name, spool / "outgoing" / name)
    limit_reached = False
    while not done.exists() or active_channels(asterisk) > 0:
        elapsed = time.monotonic() - start
        if not limit_reached and elapsed > limit:
            cli(asterisk, "channel request hangup all")
            limit_reached = True
        elif elapsed > limit + 30:
            raise RuntimeError(f"call {name} did not end 30 s after it was hung up")
        time.sleep(0.05)
    status = re.search(r"^Status: (.*)$", done.read_text(), re.M).group(1)
    return {
        "answered": status == "Completed",
        "limitReached": limit_reached,
        "seconds": round(time.monotonic() - start, 1),
    }


def drive(spec_path, out, asterisk):
    spec = json.loads(pathlib.Path(spec_path).read_text())
    cli(asterisk, f"logger add channel {out / 'asterisk.log'} [json]verbose(3),notice,warning,error,dtmf")
    commands = [{"command": command, "output": cli(asterisk, command)} for command in spec.get("commands", [])]
    calls = []
    if spec.get("calls"):
        settings = cli(asterisk, "core show settings")
        spool = pathlib.Path(re.search(r"^\s*Spool directory:\s*(.*)$", settings, re.M).group(1))
        if "pbx_spool.so" not in cli(asterisk, "module show like pbx_spool.so"):
            loaded = cli(asterisk, "module load pbx_spool.so")
            if "pbx_spool.so" not in cli(asterisk, "module show like pbx_spool.so"):
                raise RuntimeError(f"the probe places calls with pbx_spool.so, which did not load: {loaded}")
        for line in CALLER:
            cli(asterisk, f"dialplan add extension {line} into {CONTEXT}")
        for index, call in enumerate(spec["calls"]):
            calls.append(call | place(asterisk, spool, f"call-{index}", call_file(call), call.get("limit", LIMIT)))
        place(asterisk, spool, "end", call_file({"extension": "end", "context": CONTEXT}), LIMIT)
    (out / "drive.json").write_text(json.dumps({"commands": commands, "calls": calls}))


def messages(log):
    """The messages of the log, without the line Asterisk starts a file with
    each time it opens it."""
    result = []
    for line in log.read_text().splitlines():
        if line.startswith("[") and "Asterisk" in line:
            continue
        entry = json.loads(line)
        result.append(
            {
                "level": entry["logmsg"]["level"],
                "file": entry["logmsg"]["location"]["filename"],
                "thread": entry["identifiers"]["lwp"],
                "message": entry["logmsg"]["message"].removesuffix("\n"),
            }
        )
    return result


# main/pbx.c pbx_extension_helper and __ast_pbx_run
STEP = re.compile(
    r'Executing \[(?P<where>.*?):(?P<priority>\d+)\] (?P<application>\w+)\("(?P<channel>.*?)", "(?P<data>.*)"\) in new stack',
    re.S,
)
ENDS = [
    (
        re.compile(
            r"Spawn extension \((?P<context>.*), (?P<extension>.*), (?P<priority>\d+)\) exited non-zero on '(?P<channel>.*)'"
        ),
        "hangup",
    ),
    (re.compile(r"Spawn extension \(.*\) exited ERROR while already on 'e' exten on '(?P<channel>.*)'"), "error"),
    (re.compile(r"Auto fallthrough, channel '(?P<channel>.*)' status is '(?P<status>.*)'"), "fallthrough"),
    (re.compile(r"Channel '(?P<channel>.*)' sent to invalid extension but no invalid handler: .*"), "invalid"),
    # these two name no channel: it is the one the thread last ran a step of
    (re.compile(r"Invalid extension '.*', but no rule 'i' or 'e' in context '.*'"), "invalid"),
    (re.compile(r"Timeout, but no rule 't' or 'e' in context '.*'"), "timeout"),
]


def summary(call, window):
    steps = []
    ended = []
    channel_of = {}
    for message in window:
        text = message["message"]
        if message["file"] != "pbx.c":
            continue
        if step := STEP.fullmatch(text):
            channel_of[message["thread"]] = step["channel"]
            extension, _, context = step["where"].partition("@")
            if context != CONTEXT:
                steps.append(
                    {
                        "channel": step["channel"],
                        "context": context,
                        "extension": extension,
                        "priority": int(step["priority"]),
                        "application": step["application"],
                        "data": step["data"],
                    }
                )
            continue
        for pattern, how in ENDS:
            if match := pattern.fullmatch(text):
                channel = match.groupdict().get("channel") or channel_of.get(message["thread"])
                ran = [s for s in steps if s["channel"] == channel]
                if "priority" in match.groupdict():
                    where = (match["context"], match["extension"], int(match["priority"]))
                    ran = [s for s in ran if (s["context"], s["extension"], s["priority"]) == where]
                # the caller's own end, in the probe's context, has no step
                # here, and an `h` extension can end a second time
                if ran and all(e["channel"] != channel for e in ended):
                    ended.append(ran[-1] | {"how": how} | ({"status": match["status"]} if how == "fallthrough" else {}))
                break
    # a channel hung up in an application that then returns normally, such as
    # ConfBridge, ends with a debug message only (main/pbx.c __ast_pbx_run)
    for channel in dict.fromkeys(s["channel"] for s in steps):
        if all(e["channel"] != channel for e in ended):
            ended.append([s for s in steps if s["channel"] == channel][-1] | {"how": "hangup"})
    return call | {
        "channel": steps[0]["channel"] if steps else None,
        "steps": steps,
        "ended": ended,
        "log": [{"level": m["level"], "message": m["message"]} for m in window],
    }


def report(out):
    driven = json.loads((out / "drive.json").read_text())
    log = messages(out / "asterisk.log")
    # pbx_spool logs this as it starts a call; the last one is the end marker
    starts = [i for i, m in enumerate(log) if m["file"] == "pbx_spool.c" and m["message"].startswith("Attempting call on ")]
    calls = driven["calls"]
    if calls and len(starts) != len(calls) + 1:
        raise RuntimeError(f"{len(calls)} calls placed, but pbx_spool logged {len(starts)} attempts")
    windows = [log[start + 1 : end] for start, end in zip(starts, starts[1:])]
    result = {"commands": driven["commands"], "calls": [summary(call, window) for call, window in zip(calls, windows)]}
    (out / "probe.json").write_text(json.dumps(result, indent=1, ensure_ascii=False) + "\n")
    (out / "drive.json").unlink()


def main():
    match sys.argv[1:]:
        case ["drive", spec, out, *asterisk]:
            drive(spec, pathlib.Path(out), asterisk)
        case ["report", out]:
            report(pathlib.Path(out))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
