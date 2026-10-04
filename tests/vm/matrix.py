# The call script of the environment matrix (matrix.nix), run for every row
# of the test at once: each step acts on the rows that have not failed, then
# checks each of them. A row that fails a check hangs up and is left out of
# the steps after it, and the test fails at the end with each failed row and
# why. Appended after phone.py and tones.py, with PLAN, CERTIFICATES, KEYS
# and HOLD_TONE set.
import collections
import ipaddress

by_name = {machine.name: machine for machine in machines}
slots = collections.Counter()


def ports(machine):
    """Ports of a phone of its own on a machine: pjsua takes the SIP port,
    the one above for TLS and the one 10 above for IPv6"""
    slots[machine.name] += 1
    return 5040 + 20 * slots[machine.name], 2300 + slots[machine.name]


class Row:
    def __init__(self, plan):
        self.plan = plan
        self.id = plan["id"]
        self.pbx = by_name[plan["pbx"]]
        self.websocket = plan["websocket"]
        self.failure = None
        self.planned = {phone["role"]: phone for phone in plan["phones"]}
        self.phones = {}
        for role, phone in self.planned.items():
            machine = by_name[phone["machine"]]
            sip_port, control_port = ports(machine)
            name = f"{self.id}{role}"
            if self.websocket:
                ca = f"{CERTIFICATES}/ca.pem" if plan["transport"] == "wss" else ""
                self.phones[role] = Baresip(
                    machine, name, phone["extension"], phone["password"], phone["server"],
                    sip_port=sip_port, ca_file=ca,
                )
            else:
                self.phones[role] = Phone(
                    machine, name, phone["extension"], phone["password"], phone["server"],
                    sip_port=sip_port, cli_port=control_port, options=self.tls(),
                )
        self.a, self.b, self.c = (self.phones.get(role) for role in "abc")

    def tls(self):
        return pjsua_tls(CERTIFICATES, "phone") if self.plan["transport"] == "tls" else ""

    def users(self, *roles):
        return [self.phones[role].user for role in roles]


rows =[Row(plan) for plan in PLAN["rows"]]


def calling():
    """The rows that have not failed and run the call script. WebSocket rows
    only register: over WebSocket, Asterisk offers an address and a Contact
    the phones may not reach (modules/pjsip.nix, transports.<name>.protocol)"""
    return [row for row in rows if row.failure is None and not row.websocket]


def hang_up(row):
    for phone in row.phones.values():
        if isinstance(phone, Phone):
            phone.machine.execute(f"sip-phone cli {phone.name} 'call hangup_all'")


def report(row):
    """What the pbx and the phones of a failed row say about its calls: the
    pbx's channels, and the last SIP messages each pjsua sent and received,
    with their media lines"""
    lines = [row.pbx.execute(f"asterisk -rx {shlex.quote(command)}")[1] for command in ["core show channels concise", "pjsip show channelstats"]]
    for phone in row.phones.values():
        if isinstance(phone, Phone):
            messages = re.findall(r"(TX|RX) \d+ bytes (?:Request|Response) msg (\S+) .*? (?:to|from) (\S+ \S+):\n(.*?)\n--end msg--", phone.log_text(), re.S)
            for direction, what, peer, text in messages[-12:]:
                media = " ".join(re.findall(r"^(?:[cm]=.*|a=(?:sendrecv|sendonly|recvonly|inactive))$", text, re.M))
                lines.append(f"{phone.name} {direction} {what} {peer} {text.splitlines()[0]} {media}")
        else:
            # baresip's SIP trace: the first lines of messages and their media lines
            trace = phone.machine.execute(f"grep -aE '^(SIP/2\\.0 [0-9]+|[A-Z]+ sips?:|[cm]=)' {phone.log} | tail -n 20")[1]
            lines += [f"{phone.name} {line}" for line in trace.splitlines()]
    return "\n".join(lines)


def fail(row, why):
    row.failure = why
    log.warning(f"row {row.id} failed: {why}\n{report(row)}")
    hang_up(row)


def each(title, check, selected):
    """Runs `check` on each of `selected` that has not failed; a row it fails
    for fails with `title`."""
    for row in selected:
        if row.failure is not None:
            continue
        try:
            check(row)
        except Exception as error:
            fail(row, f"{title}: {error}")


batches = itertools.count()


def cli_all(commands):
    """As cli_parallel, with the machines' shares under way at once rather
    than one after another: each command takes a second or two. Returns what
    each phone answered, by phone name."""
    batch = next(batches)
    by_machine = {}
    for phone, command in commands:
        by_machine.setdefault(phone.machine, []).append((phone, command))
    for i, (machine, group) in enumerate(by_machine.items()):
        script = "\n".join(f"sip-phone cli {phone.name} {shlex.quote(command)} > /tmp/cli-{batch}-{phone.name} &" for phone, command in group)
        script = f"({script}\nwait\ntouch /tmp/cli-{batch}.done) > /dev/null 2>&1"
        machine.succeed(script if i == len(by_machine) - 1 else f"{script} &")
    answers = {}
    for machine, group in by_machine.items():
        machine.wait_until_succeeds(f"test -e /tmp/cli-{batch}.done", timeout=60)
        output = machine.succeed(" ".join(f"echo '@@{phone.name}'; cat /tmp/cli-{batch}-{phone.name};" for phone, _ in group))
        for block in output.split("@@")[1:]:
            name, _, answer = block.partition("\n")
            answers[name] = answer
    return answers


def send(commands, selected):
    """Sends the (phone, CLI command) pairs `commands` gives for each of
    `selected` that has not failed, all at once."""
    cli_all([pair for row in selected if row.failure is None for pair in commands(row)])


def hear_each_other(a, b):
    wait_hears(a, [b.tone])
    wait_hears(b, [a.tone])


def gone(row, *roles):
    """Wait until the row's pbx has no channel of these phones."""
    users = "|".join(row.users(*roles))
    row.pbx.wait_until_succeeds(f"! asterisk -rx 'core show channels concise' | grep -qE '^PJSIP/({users})-'", timeout=60)


def codecs(row, *roles):
    """The phones' channels on the pbx carry their codecs."""
    stats = channel_stats(row.pbx)
    found = {role: [s["codec"] for name, s in stats.items() if name.startswith(f"{row.phones[role].user}-")] for role in roles}
    wanted = {role: [row.planned[role]["codec"]] for role in roles}
    assert found == wanted, (found, wanted)


def pbx_addresses(phone):
    """(IP4 or IP6, address) of the Contact and the SDP o= and c= lines of
    what `phone` received, except REGISTER responses, whose Contact is the
    phone's own."""
    found = set()
    for message in re.findall(r"RX \d+ bytes (?:Request|Response) msg .*?\n--end msg--", phone.log_text(), re.S):
        if re.search(r"^CSeq: \d+ REGISTER", message, re.M):
            continue
        for host in re.findall(r"^Contact: <sips?:(?:[^@>]*@)?(\[[^]]+\]|[^:;>]+)", message, re.M):
            found.add((f"IP{ipaddress.ip_address(host.strip('[]')).version}", host.strip("[]")))
        found.update(re.findall(r"^[oc]=.* IN (IP[46]) (\S+)", message, re.M))
    return found


def private_lines(phone, prefixes):
    """Lines of what `phone` received that name an address of the office
    network, but for From and To: requests from the pbx name its own address
    in From, and the phone's requests in their dialogs echo it in To"""
    lines = []
    for message in re.findall(r"RX \d+ bytes .*?\n--end msg--", phone.log_text(), re.S):
        for line in message.splitlines()[1:]:
            if any(prefix in line for prefix in prefixes) and not line.startswith(("From:", "To:")):
                lines.append(line)
    return lines


start_all()
# IPv6 addresses answer once duplicate address detection is done
for machine in machines:
    machine.wait_until_succeeds("test -z \"$(ip -6 address show tentative)\"")
for name in ["officerouter", "homerouter"]:
    if name in by_name:
        # the firewall service sets up NAT and the forwarded ports
        by_name[name].wait_for_unit("firewall.service")

with subtest("each pbx listens on every transport of its families"):
    for pbx in PLAN["pbxs"]:
        machine = by_name[pbx["name"]]
        machine.wait_for_unit("asterisk.service")
        udp = machine.succeed("ss -Hlun 'sport = :5060'")
        tcp = {port: machine.succeed(f"ss -Hltn 'sport = :{port}'") for port in [5060, 5061, 8088, 8089]}
        if "v4" in pbx["families"]:
            assert "0.0.0.0:5060" in udp, udp
            assert "0.0.0.0:5060" in tcp[5060] and "0.0.0.0:5061" in tcp[5061], tcp
        if "v6" in pbx["families"]:
            # bound to the pbx's own address once duplicate address detection is
            # done, which Asterisk waits for
            assert f"[{pbx['address']['v6']}]:5060" in udp, udp
            assert f"[{pbx['address']['v6']}]:5060" in tcp[5060] and "[::]:5061" in tcp[5061], tcp
        # the HTTP server, which carries ws and wss, on :: takes both families
        http = "*" if "v6" in pbx["families"] else "0.0.0.0"
        assert f"{http}:8088" in tcp[8088] and f"{http}:8089" in tcp[8089], tcp

with subtest("every phone registers with its pbx"):
    start_phones([phone for row in rows if not row.websocket for phone in row.phones.values()])
    for row in rows:
        if row.websocket:
            for phone in row.phones.values():
                phone.start()

    def registered(row):
        for phone in row.phones.values():
            phone.wait_registered(timeout=60)

    # the baresip phones of the websocket rows; pjsua's CLI shows the others below
    each("registration", registered, [row for row in rows if row.websocket])
    pjsua = {phone.name: (row, phone) for row in rows if row.failure is None and not row.websocket for phone in row.phones.values()}
    deadline = time.time() + 60
    status = {}
    while True:
        answers = cli_all([(phone, "acc show") for name, (_, phone) in pjsua.items() if status.get(name) != ["200"]])
        for name, answer in answers.items():
            # ` *[ 1] sip:201@pbx: 403/Forbidden (expires=-1)`, 100 while in progress
            status[name] = re.findall(r"^ \*\[ *\d+\] \S+: (\d+)/", answer, re.M)
        if all(status[name] == ["200"] for name in pjsua) or time.time() > deadline:
            break
        time.sleep(1)
    for name, (row, _) in pjsua.items():
        if status[name] != ["200"] and row.failure is None:
            fail(row, f"registration: {name} ended with {status[name]}")

with subtest("A calls B, and each hears the other in its codec"):
    send(lambda row: [(row.a, f"call new {row.a.uri(row.b.user)}")], calling())

    def answered(row):
        wait_bridged(row.pbx, *row.users("a", "b"))
        hear_each_other(row.a, row.b)
        codecs(row, "a", "b")

    each("A calls B", answered, calling())

with subtest("keys go from A to B and back as RFC 4733 events"):
    before = {row.id: {role: len(row.phones[role].dtmf_received("RFC2833")) for role in "ab"} for row in calling()}
    send(lambda row: [(row.a, f"call d_2833 {KEYS}")], calling())
    each("keys from A", lambda row: row.b.wait_dtmf(KEYS, after=before[row.id]["b"], method="RFC2833"), calling())
    send(lambda row: [(row.b, f"call d_2833 {KEYS}")], calling())
    each("keys from B", lambda row: row.a.wait_dtmf(KEYS, after=before[row.id]["a"], method="RFC2833"), calling())

with subtest("A holds B, who hears music until A takes the call back"):
    send(lambda row: [(row.a, "call hold")], calling())
    each("B hears the music", lambda row: wait_hears(row.b, [HOLD_TONE]), calling())
    send(lambda row: [(row.a, "call reinvite")], calling())
    each("A takes the call back", lambda row: hear_each_other(row.a, row.b), calling())

with subtest("B hangs up, and the call ends for A too"):
    ended = {row.id: row.a.disconnects() for row in calling()}
    send(lambda row: [(row.b, "call hangup_all")], calling())

    def hung_up(row):
        row.a.wait_disconnected(after=ended[row.id])
        gone(row, "a", "b")

    each("B hangs up", hung_up, calling())

with subtest("B calls A, who sends B on to C with a blind transfer"):
    send(lambda row: [(row.b, f"call new {row.b.uri(row.a.user)}")], calling())

    def called(row):
        wait_bridged(row.pbx, *row.users("b", "a"))
        hear_each_other(row.b, row.a)

    each("B calls A", called, calling())
    send(lambda row: [(row.a, f"call transfer {row.a.uri(row.c.user)}")], calling())

    def transferred(row):
        wait_bridged(row.pbx, *row.users("b", "c"))
        gone(row, "a")
        hear_each_other(row.b, row.c)

    each("A sends B on to C", transferred, calling())
    send(lambda row: [(row.c, "call hangup_all")], calling())
    each("C hangs up", lambda row: gone(row, "b", "c"), calling())

with subtest("each phone is only given pbx addresses it can reach"):

    def reachable(row):
        for role, phone in row.phones.items():
            planned = row.planned[role]
            wanted = {(f"IP{4 if planned['family'] == 'v4' else 6}", planned["pbxAddress"])}
            found = pbx_addresses(phone)
            assert found == wanted, (role, found, wanted)
            if row.plan["private"]:
                lines = private_lines(phone, row.plan["private"])
                assert lines == [], (role, lines)

    each("addresses", reachable, calling())

with subtest("every row passes"):
    failed = {row.id: row.failure for row in rows if row.failure is not None}
    assert not failed, failed
