# Helpers for driving `sip-phone` (tests/vm/phone.nix) from test scripts.
import re
import shlex
import time


class Phone:
    def __init__(self, machine, name, user, password, server, sip_port=5070, cli_port=2300):
        self.machine = machine
        self.name = name
        self.user = user
        self.password = password
        self.server = server
        self.sip_port = sip_port
        self.cli_port = cli_port
        self.log = f"/tmp/sip-phone-{name}.log"

    def start(self, extra=""):
        self.machine.succeed(
            f"sip-phone start {self.name} {self.user} {shlex.quote(self.password)} "
            f"{self.server} {self.sip_port} {self.cli_port} {extra}"
        )
        self.machine.wait_until_succeeds(f"test -f {self.log}")

    def stop(self):
        self.machine.succeed(f"sip-phone stop {self.name}")

    def wait_registered(self, timeout=120):
        self.machine.wait_until_succeeds(f"grep -q 'registration success' {self.log}", timeout=timeout)

    def wait_registration_failed(self, pattern="registration failed", timeout=120):
        self.machine.wait_until_succeeds(f"grep -qE {shlex.quote(pattern)} {self.log}", timeout=timeout)

    def cli(self, command):
        return self.machine.succeed(f"sip-phone cli {self.name} {shlex.quote(command)}")

    def call(self, extension):
        self.cli(f"call new sip:{extension}@{self.server}")

    def hangup(self):
        self.cli("call hangup_all")

    def log_text(self):
        return self.machine.succeed(f"cat {self.log}")

    def received_invites(self):
        """INVITE requests this phone received, as raw SIP messages."""
        text = self.log_text()
        return re.findall(r"RX \d+ bytes Request msg INVITE.*?\n--end msg--", text, re.S)


def asterisk(machine, command):
    return machine.succeed(f"asterisk -rx {shlex.quote(command)}")


def channel_stats(machine):
    """Receive/transmit packet counts per channel from `pjsip show channelstats`."""
    stats = {}
    for line in asterisk(machine, "pjsip show channelstats").splitlines():
        fields = line.split()
        # [BridgeId] ChannelId UpTime Codec RxCount RxLost RxPct RxJitter TxCount ...
        for i, field in enumerate(fields):
            if re.match(r"^\S+-[0-9a-f]{8}$", field) and len(fields) >= i + 8:
                stats[field] = {"rx": int(fields[i + 3]), "tx": int(fields[i + 7])}
                break
    return stats


def wait_for_media_both_ways(machine, minimum=50, timeout=90):
    """Every active channel has sent and received at least `minimum` RTP packets."""
    deadline = time.time() + timeout
    while True:
        stats = channel_stats(machine)
        if len(stats) >= 2 and all(s["rx"] >= minimum and s["tx"] >= minimum for s in stats.values()):
            return stats
        if time.time() > deadline:
            raise Exception(f"RTP did not flow both ways: {stats}")
        time.sleep(2)
