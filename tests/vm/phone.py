# Helpers for driving `sip-phone` (tests/vm/phone.nix) from test scripts.
import itertools
import re
import shlex
import time

# Each phone sends its own tone. From 400 Hz in steps of 60 Hz, halving or
# doubling one, as a file played at the wrong sample rate would, never gives
# another phone's tone.
PHONE_TONES = [400 + 60 * i for i in range(31)]
phones_made = itertools.count()


class Phone:
    """A pjsua instance registered as `user`. It answers incoming calls with
    the SIP status `auto_answer`: 200 picks up, 180 rings until told
    otherwise, 486 is busy. It sends a sine of `tone` Hz and records what it
    hears (tones.py)."""

    def __init__(self, machine, name, user, password, server, sip_port=5070, cli_port=2300, auto_answer=200, tone=None):
        self.machine = machine
        self.name = name
        self.user = user
        self.password = password
        self.server = server
        self.sip_port = sip_port
        self.cli_port = cli_port
        self.auto_answer = auto_answer
        self.tone = PHONE_TONES[next(phones_made) % len(PHONE_TONES)] if tone is None else tone
        self.log = f"/tmp/sip-phone-{name}.log"
        self.recording = f"/tmp/sip-phone-{name}.wav"

    def start_command(self, extra=""):
        flags = [f"--auto-answer={self.auto_answer}"]
        # the server URI decides the transport, as on a real phone. A UDP
        # phone gets no TCP transport: pjsua sends requests larger than 1300
        # bytes over TCP when it has one, and the server may not listen there.
        flags.append("--no-udp" if "transport=tcp" in self.server else "--no-tcp")
        if self.server.startswith("["):
            flags.append("--ipv6")
        # pjsua counts up from its RTP port until one is free; distinct bases
        # keep that search short when many phones share a machine
        flags.append(f"--rtp-port={20000 + 8 * (self.sip_port - 5000)}")
        return (
            f"sip-phone start {self.name} {self.user} {shlex.quote(self.password)} "
            f"{shlex.quote(self.server)} {self.sip_port} {self.cli_port} {self.tone} {' '.join(flags)} {extra}"
        )

    def start(self, extra=""):
        self.machine.succeed(self.start_command(extra))
        # pjsua only opens its log once it accepted its arguments
        self.machine.wait_until_succeeds(f"test -f {self.log}", timeout=60)

    def stop(self):
        self.machine.succeed(f"sip-phone stop {self.name}")

    def wait_registered(self, timeout=120):
        self.machine.wait_until_succeeds(f"grep -q 'registration success' {self.log}", timeout=timeout)

    def wait_registration_failed(self, pattern="registration (failed|error)", timeout=120):
        self.machine.wait_until_succeeds(f"grep -qE {shlex.quote(pattern)} {self.log}", timeout=timeout)

    def cli(self, command):
        return self.machine.succeed(f"sip-phone cli {self.name} {shlex.quote(command)}")

    def uri(self, extension):
        return f"sip:{extension}@{self.server}"

    def call(self, extension):
        self.cli(f"call new {self.uri(extension)}")

    def hangup(self):
        self.cli("call hangup_all")

    def hold(self):
        self.cli("call hold")

    def dtmf(self, digits):
        """Send DTMF as RFC 4733 events on the current call."""
        self.cli(f"call d_2833 {digits}")

    def dtmf_info(self, digits):
        """Send DTMF as SIP INFO requests on the current call."""
        self.cli(f"call d_info {digits}")

    def transfer(self, extension):
        """Blind transfer of the current call (REFER)."""
        self.cli(f"call transfer {self.uri(extension)}")

    def transfer_replaces(self, call_id):
        """Attended transfer: connect the current call's peer with the peer of
        call `call_id` (REFER with Replaces)."""
        self.cli(f"call transfer_replaces {call_id}")

    def watch(self, extension):
        """Subscribe to the presence of `extension`, like a busy lamp key
        (pjsua's --add-buddy adds a buddy without subscribing)."""
        self.cli(f"im add_b {self.uri(extension)}")

    def current_call(self):
        """Id of the current call. pjsua hands out call ids round-robin, so
        they cannot be predicted."""
        output = self.cli("call list")
        match = re.search(r"Current call id=(\d+)", output)
        assert match, output
        return int(match.group(1))

    def log_text(self):
        return self.machine.succeed(f"cat {self.log}")

    def received(self, method):
        """Requests of `method` this phone received, as raw SIP messages."""
        return re.findall(rf"RX \d+ bytes Request msg {method}/.*?\n--end msg--", self.log_text(), re.S)

    def count(self, pattern):
        """Lines of the phone's log matching the extended regular expression."""
        _, output = self.machine.execute(f"grep -cE {shlex.quote(pattern)} {self.log}")
        return int(output.strip() or 0)

    def wait_count(self, pattern, minimum, timeout=90):
        self.machine.wait_until_succeeds(
            f"test $(grep -cE {shlex.quote(pattern)} {self.log}) -ge {minimum}", timeout=timeout
        )

    def requests(self, method):
        return self.count(f"RX [0-9]+ bytes Request msg {method}/")

    def wait_request(self, method, after=0, timeout=90):
        """Wait until the phone has received more than `after` requests of `method`."""
        self.wait_count(f"RX [0-9]+ bytes Request msg {method}/", after + 1, timeout=timeout)

    def disconnects(self):
        return self.count("Call [0-9]+ is DISCONNECTED")

    def wait_disconnected(self, after=0, timeout=90):
        """Wait until more than `after` of the phone's calls have ended."""
        self.wait_count("Call [0-9]+ is DISCONNECTED", after + 1, timeout=timeout)


def start_phones(phones):
    """Start phones with one shell command per machine, then wait for their logs."""
    by_machine = {}
    for phone in phones:
        by_machine.setdefault(phone.machine, []).append(phone)
    for machine, group in by_machine.items():
        machine.succeed("\n".join(phone.start_command() for phone in group))
        machine.wait_until_succeeds(" && ".join(f"test -f {phone.log}" for phone in group), timeout=60)


def cli_parallel(commands):
    """Run (phone, CLI command) pairs at the same time, one shell per machine.
    Returns what each phone's CLI answered, by phone name."""
    by_machine = {}
    for phone, command in commands:
        by_machine.setdefault(phone.machine, []).append((phone, command))
    answers = {}
    for machine, group in by_machine.items():
        machine.succeed(
            "\n".join(
                [f"sip-phone cli {phone.name} {shlex.quote(command)} > /run/sip-phone/{phone.name}.out &" for phone, command in group]
                + ["wait"]
            )
        )
        output = machine.succeed(" ".join(f"echo '@@{phone.name}'; cat /run/sip-phone/{phone.name}.out;" for phone, _ in group))
        for block in output.split("@@")[1:]:
            name, _, answer = block.partition("\n")
            answers[name] = answer
    return answers


def rtp_received(phones):
    """RTP packets each phone received on its current call, by phone name."""
    answers = cli_parallel([(phone, "call dump_q") for phone in phones])
    received = {}
    for phone in phones:
        # pjsua prints counts as 938, 6.5K or 1.05M
        match = re.search(r"RX pt=.*?total ([0-9.]+)([KM]?)pkt", answers[phone.name], re.S)
        if match:
            scale = {"": 1, "K": 1000, "M": 1000000}[match.group(2)]
            received[phone.name] = round(float(match.group(1)) * scale)
        else:
            received[phone.name] = 0
    return received


def asterisk(machine, command):
    return machine.succeed(f"asterisk -rx {shlex.quote(command)}")


def netem(machine, interface, *settings):
    """Delay, loss, reordering and the like, as tc-netem(8) takes them, on
    what `machine` sends out of `interface`; no settings removes them."""
    if settings:
        machine.succeed(f"tc qdisc replace dev {interface} root netem {shlex.join(settings)}")
    else:
        machine.succeed(f"tc qdisc del dev {interface} root")


CHANNEL_FIELDS = [
    "name", "context", "exten", "priority", "state", "app", "data", "caller",
    "accountcode", "peeraccount", "amaflags", "duration", "bridge", "uniqueid",
]


def channels(machine):
    """Active channels from `core show channels concise`."""
    rows = []
    for line in asterisk(machine, "core show channels concise").splitlines():
        fields = line.split("!")
        if len(fields) == len(CHANNEL_FIELDS):
            rows.append(dict(zip(CHANNEL_FIELDS, fields)))
    return rows


def endpoint_of(channel):
    """`PJSIP/201-0000000a` -> `201`"""
    return channel.split("/", 1)[-1].rsplit("-", 1)[0]


def bridges(machine):
    """Endpoints per bridge, for channels in a bridge."""
    members = {}
    for channel in channels(machine):
        if channel["bridge"]:
            members.setdefault(channel["bridge"], set()).add(endpoint_of(channel["name"]))
    return members


def wait_bridged(machine, *endpoints, timeout=90):
    """Wait until a channel of each endpoint is in the same bridge."""
    wanted = set(endpoints)
    deadline = time.time() + timeout
    while True:
        found = bridges(machine)
        if any(wanted <= members for members in found.values()):
            return found
        if time.time() > deadline:
            raise Exception(f"{sorted(wanted)} were not bridged: {found}")
        time.sleep(1)


def wait_channel(machine, endpoint, app=None, state=None, timeout=90):
    """Wait until a channel of `endpoint` runs dialplan application `app`
    and is in channel state `state` (Ring, Ringing, Up, ...), where given."""
    deadline = time.time() + timeout
    while True:
        found = channels(machine)
        for channel in found:
            if (
                endpoint_of(channel["name"]) == endpoint
                and app in (None, channel["app"])
                and state in (None, channel["state"])
            ):
                return channel
        if time.time() > deadline:
            raise Exception(f"no channel of {endpoint} with app {app}, state {state}: {found}")
        time.sleep(1)


def wait_idle(machine, timeout=120):
    machine.wait_until_succeeds(
        "asterisk -rx 'core show channels count' | grep -q '^0 active channels'", timeout=timeout
    )


def wait_contacts(machine, count, timeout=180):
    """Wait until exactly `count` contacts are registered."""
    machine.wait_until_succeeds(
        f"asterisk -rx 'pjsip show contacts' | grep -qx 'Objects found: {count}'", timeout=timeout
    )


def journal_cursor(machine):
    return machine.succeed("journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p'").strip()


def journal_since(machine, cursor):
    return machine.succeed(f"journalctl -u asterisk.service --after-cursor={shlex.quote(cursor)}")


def wait_journal(machine, cursor, pattern, count=1, timeout=90):
    """Wait for `count` lines of Asterisk's journal matching the extended
    regular expression after `cursor`."""
    machine.wait_until_succeeds(
        f"test $(journalctl -u asterisk.service --after-cursor={shlex.quote(cursor)} | grep -cE {shlex.quote(pattern)}) -ge {count}",
        timeout=timeout,
    )


def channel_stats(machine):
    """Codec and receive/transmit packet counts per channel from `pjsip show
    channelstats`, which cuts channel names (without `PJSIP/`) off at 18
    characters."""

    def count(field):
        # counts above 100000 are printed in thousands
        return int(field[:-1]) * 1000 if field.endswith("K") else int(field)

    stats = {}
    for line in asterisk(machine, "pjsip show channelstats").splitlines():
        fields = line.split()
        # [BridgeId] ChannelId UpTime Codec RxCount RxLost RxPct RxJitter TxCount ...
        for i, field in enumerate(fields):
            if re.fullmatch(r"\d+:\d\d:\d\d", field) and 0 < i and len(fields) > i + 6:
                stats[fields[i - 1]] = {"codec": fields[i + 1], "rx": count(fields[i + 2]), "tx": count(fields[i + 6])}
                break
    return stats


def wait_for_media_both_ways(machine, phones, minimum=50, timeout=90, count=None):
    """RTP flows both ways: `machine` has at least `count` channels (by
    default one per phone), each of which sent and received `minimum`
    packets, and each phone received `minimum` packets on its current call.
    Asterisk counts the packets it sends whether they arrive or not, so only
    the phones can tell that they do."""
    count = len(phones) if count is None else count
    deadline = time.time() + timeout
    while True:
        stats = channel_stats(machine)
        received = rtp_received(phones)
        if (
            len(stats) >= count
            and all(s["rx"] >= minimum and s["tx"] >= minimum for s in stats.values())
            and all(packets >= minimum for packets in received.values())
        ):
            return stats
        if time.time() > deadline:
            raise Exception(f"RTP did not flow both ways: {stats}, received by the phones: {received}")
        time.sleep(2)


def wait_calls_continue(machine, phones, stats, minimum=50, timeout=60):
    """The channels in `stats` (from wait_for_media_both_ways) are still the
    only ones, and each phone receives `minimum` more packets."""
    received = rtp_received(phones)
    deadline = time.time() + timeout
    while True:
        now = channel_stats(machine)
        now_received = rtp_received(phones)
        if set(now) == set(stats) and all(now_received[name] >= received[name] + minimum for name in received):
            return now
        if time.time() > deadline:
            raise Exception(f"the calls did not go on: {stats}, {received} -> {now}, {now_received}")
        time.sleep(2)
