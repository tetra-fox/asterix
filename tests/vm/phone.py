# Helpers for driving `sip-phone` (tests/vm/phone.nix), `baresip-phone`
# (tests/vm/baresip.nix) and SIPp (tests/vm/sipp.nix) from test scripts.
import itertools
import json
import re
import shlex
import socket
import struct
import time

# Each phone sends its own tone. From 400 Hz in steps of 60 Hz, halving or
# doubling one, as a file played at the wrong sample rate would, never gives
# another phone's tone.
PHONE_TONES = [400 + 60 * i for i in range(31)]
phones_made = itertools.count()


class Phone:
    """A pjsua instance registered as `user`, or not registered at all with
    `register=False`, like a provider's server that is only called. It answers
    incoming calls with the SIP status `auto_answer`: 200 picks up, 180 rings
    until told otherwise, 486 is busy. With `call_waiting=False` it answers
    486 to any call that comes while it is in one. It sends a sine of `tone`
    Hz and records what it hears (tones.py). With `symmetric_rtp=False` it
    sends RTP only to the address the SDP names (tests/vm/phone.nix)."""

    def __init__(self, machine, name, user, password, server, sip_port=5070, cli_port=2300, auto_answer=200, tone=None, register=True, call_waiting=True, symmetric_rtp=True):
        self.machine = machine
        self.name = name
        self.user = user
        self.password = password
        self.server = server
        self.sip_port = sip_port
        self.cli_port = cli_port
        self.auto_answer = auto_answer
        self.register = register
        self.call_waiting = call_waiting
        self.symmetric_rtp = symmetric_rtp
        self.tone = PHONE_TONES[next(phones_made) % len(PHONE_TONES)] if tone is None else tone
        self.log = f"/tmp/sip-phone-{name}.log"
        self.recording = f"/tmp/sip-phone-{name}.wav"

    def start_command(self, extra=""):
        # sip-phone reads this one before the pjsua arguments
        flags = [] if self.symmetric_rtp else ["--no-symmetric-rtp"]
        flags.append(f"--auto-answer={self.auto_answer}")
        if self.register:
            flags.append(shlex.quote(f"--registrar=sip:{self.server}"))
        if not self.call_waiting:
            # pjsua answers 486 when it has no free call slot
            flags.append("--max-calls=1")
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

    def dtmf_received(self):
        """Digits the phone received as DTMF on its calls so far, in order."""
        return "".join(re.findall(r"Incoming DTMF on call \d+: (.)", self.log_text()))

    def wait_dtmf(self, digits, after, timeout=30):
        """Wait until the digits the phone received after its first `after`
        are `digits`; fails as soon as one differs."""
        deadline = time.time() + timeout
        while True:
            received = self.dtmf_received()[after:]
            if received == digits:
                return
            if not digits.startswith(received) or time.time() > deadline:
                raise Exception(f"{self.name} received DTMF {received!r}, expected {digits!r}")
            time.sleep(0.5)

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

    def rtp_address(self):
        """The address and RTP port the last SDP the phone sent gives; pjsua
        takes a new port for each call. RTCP is one above."""
        sent = re.findall(r"TX \d+ bytes .*?\n--end msg--", self.log_text(), re.S)
        offers = [message for message in sent if "\nm=audio " in message]
        assert offers, f"{self.name} sent no SDP"
        address = re.search(r"^c=IN IP[46] (\S+)", offers[-1], re.M)
        port = re.search(r"^m=audio (\d+) ", offers[-1], re.M)
        assert address and port, offers[-1]
        return address.group(1), int(port.group(1))

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

    def contact_status(self, machine):
        """Status (Avail, NonQual, ...) of this phone's contact in `pjsip show
        contacts` on `machine`, or None when Asterisk holds none for it."""
        match = re.search(
            rf"^ *Contact: +{self.user}/sip:{self.user}@[^:]+:{self.sip_port}\S* +\S+ +(\S+)",
            asterisk(machine, "pjsip show contacts"),
            re.M,
        )
        return match.group(1) if match else None

    def confirmed(self):
        """Calls that got their ACK, for a callee, or sent it, for a caller."""
        return self.count("Call [0-9]+ state changed to CONFIRMED")

    def wait_confirmed(self, after=0, timeout=90):
        """Wait until more than `after` of the phone's calls are confirmed."""
        self.wait_count("Call [0-9]+ state changed to CONFIRMED", after + 1, timeout=timeout)

    def disconnects(self):
        return self.count("Call [0-9]+ is DISCONNECTED")

    def wait_disconnected(self, after=0, timeout=90):
        """Wait until more than `after` of the phone's calls have ended."""
        self.wait_count("Call [0-9]+ is DISCONNECTED", after + 1, timeout=timeout)


class Baresip:
    """A baresip instance registered as `user`, which answers every call. Like
    Phone, it sends a sine of `tone` Hz and records what it hears. The server
    URI picks the transport (tests/vm/baresip.nix), and a wss phone verifies
    the server's certificate against `ca_file`."""

    def __init__(self, machine, name, user, password, server, sip_port=5090, ctrl_port=4444, tone=None, ca_file=""):
        self.machine = machine
        self.name = name
        self.user = user
        self.password = password
        self.server = server
        self.sip_port = sip_port
        self.ctrl_port = ctrl_port
        self.ca_file = ca_file
        self.tone = PHONE_TONES[next(phones_made) % len(PHONE_TONES)] if tone is None else tone
        self.log = f"/tmp/baresip-phone-{name}.log"
        self.recording = f"/tmp/baresip-phone-{name}.wav"

    def start(self):
        self.machine.succeed(
            f"baresip-phone start {self.name} {self.user} {shlex.quote(self.password)} "
            f"{shlex.quote(self.server)} {self.sip_port} {self.ctrl_port} {self.tone} {shlex.quote(self.ca_file)}"
        )
        self.machine.wait_until_succeeds(f"test -f {self.log}", timeout=60)
        # baresip does not read /etc/hosts, so it dials the server's address,
        # followed by the port and parameters of `server`
        self.address = self.machine.succeed(f"cat /run/baresip-phone/{self.name}/server").strip()

    def stop(self):
        self.machine.succeed(f"baresip-phone stop {self.name}")

    def command(self, command, params=""):
        """Runs a baresip command and returns what it answered."""
        output = self.machine.succeed(f"baresip-phone command {self.name} {command} {shlex.quote(params)}")
        # ctrl_tcp frames each message as <length>:<json>,
        while output:
            length, _, rest = output.partition(":")
            message = json.loads(rest[: int(length)])
            output = rest[int(length) + 1 :]
            if message.get("response"):
                assert message["ok"], f"baresip {command} {params}: {message}"
                return message["data"]
        raise Exception(f"baresip did not answer {command} {params}")

    def wait_registered(self, timeout=120):
        # baresip logs `<aor>: {0/UDP/v4} 200 OK (<server>) [1 binding]`
        self.machine.wait_until_succeeds(f"grep -q '}} 200 OK' {self.log}", timeout=timeout)

    def call(self, extension):
        self.command("dial", f"sip:{extension}@{self.address}")

    def hangup(self):
        self.command("hangup")


def sipp(machine, scenario, remote, *args):
    """Plays the SIPp scenario tests/vm/sipp/`scenario`.xml once against
    `remote`, and fails when it does."""
    machine.succeed(
        f"sipp -sf /etc/sipp/{scenario}.xml -m 1 -nostdin -timeout 60 -timeout_error "
        f"-trace_msg -message_file /tmp/sipp-{scenario}.log {shlex.join(args)} {remote}"
    )


def pjsua_tls(certificates, certificate=None):
    """pjsua arguments for TLS with tests/vm/certificates.nix in
    `certificates`: verify the server against the test CA, and present
    `certificate` as client and as server. A TLS callee needs one, as the ACK
    for its answer comes over a connection the PBX opens to its listening
    port."""
    arguments = f"--use-tls --tls-ca-file={certificates}/ca.pem --tls-verify-server"
    if certificate:
        arguments += f" --tls-cert-file={certificates}/{certificate}.pem --tls-privkey-file={certificates}/{certificate}.key"
    return arguments


def start_phones(phones):
    """Start phones with one shell command per machine, then wait for their logs."""
    by_machine = {}
    for phone in phones:
        by_machine.setdefault(phone.machine, []).append(phone)
    for machine, group in by_machine.items():
        machine.succeed("\n".join(phone.start_command() for phone in group))
        machine.wait_until_succeeds(" && ".join(f"test -f {phone.log}" for phone in group), timeout=60)


def wait_registrations(expected, timeout=60):
    """Wait until the first registration of each phone in `expected` ({phone:
    SIP status}) ended with that status, as pjsua holds it: its CLI reopens the
    log right after the first REGISTER went out, and loses what pjsua logs
    meanwhile. Anything pjsua logs after this returns reaches its log."""
    for phone in expected:
        # the CLI logs this into the reopened log
        phone.machine.wait_until_succeeds(f"grep -q 'Module \"mod-pjsua-log\" unregistered' {phone.log}", timeout=timeout)
    deadline = time.time() + timeout
    while True:
        answers = cli_parallel([(phone, "acc show") for phone in expected])
        found = {}
        for phone in expected:
            # ` *[ 1] sip:201@pbx: 403/Forbidden (expires=-1)`, 100 while in progress
            match = re.search(r"^ \*\[ *\d+\] \S+: (\d+)/", answers[phone.name], re.M)
            found[phone.name] = int(match.group(1)) if match else None
        if all(found[phone.name] == status for phone, status in expected.items()):
            return
        if time.time() > deadline:
            raise Exception(f"registrations ended with {found}, expected {({p.name: s for p, s in expected.items()})}")
        time.sleep(1)


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


def media_peers(phones):
    """Where the RTP each phone receives on its current call comes from, as
    address:port by phone name, or "-" before any has arrived."""
    answers = cli_parallel([(phone, "call dump_q") for phone in phones])
    peers = {}
    for phone in phones:
        # `#0 audio G722 @16kHz, sendrecv, peer=10.3.1.10:5058`
        match = re.search(r"#\d+ audio .*, peer=(\S+)", answers[phone.name])
        assert match, answers[phone.name]
        peers[phone.name] = match.group(1)
    return peers


def asterisk(machine, command):
    return machine.succeed(f"asterisk -rx {shlex.quote(command)}")


def sip_messages(machine, interface="eth1"):
    """SIP messages over UDP that `machine` sent or received on `interface`,
    from the capture QEMU writes of it (common.nix), in order: the capture
    time in seconds, source and destination as address:port, and the text.
    The times of one machine's capture come from one clock."""
    data = (machine.state_dir / f"{interface}.pcap").read_bytes()
    # QEMU writes a little-endian capture with microseconds
    assert data[:4] == b"\xd4\xc3\xb2\xa1", data[:4]
    messages = []
    offset = 24
    while offset + 16 <= len(data):
        seconds, micros, length, _ = struct.unpack_from("<IIII", data, offset)
        frame = data[offset + 16 : offset + 16 + length]
        offset += 16 + length
        # the last frame may still be on its way to the file
        if len(frame) < length:
            break
        # IPv4 over Ethernet, carrying UDP, and not a fragment
        if frame[12:14] != b"\x08\x00" or frame[23] != 17 or struct.unpack_from("!H", frame, 20)[0] & 0x3FFF:
            continue
        ip = 14 + (frame[14] & 0x0F) * 4
        source_port, destination_port, udp_length = struct.unpack_from("!HHH", frame, ip)
        text = frame[ip + 8 : ip + udp_length].decode(errors="replace")
        if re.match(r"SIP/2\.0 |[A-Z]+ sip:", text):
            messages.append(
                {
                    "time": seconds + micros / 1e6,
                    "source": f"{socket.inet_ntoa(frame[26:30])}:{source_port}",
                    "destination": f"{socket.inet_ntoa(frame[30:34])}:{destination_port}",
                    "text": text,
                }
            )
    return messages


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
    """The journal's position after everything logged so far. journald reads
    what services log in its own time; `journalctl --sync` returns once it
    has read what was logged before."""
    return machine.succeed("journalctl --sync && journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p'").strip()


def journal_since(machine, cursor):
    """Asterisk's journal after `cursor`, with everything logged so far."""
    return machine.succeed(f"journalctl --sync && journalctl -u asterisk.service --after-cursor={shlex.quote(cursor)}")


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
