# AMI users that listen for events, through the ami client (./ami.nix) on the
# machine Asterisk runs on. Tests append this file after phone.py, whose
# imports it uses.


def ami_listen(machine, secret, *users):
    """Start writing the events each of `users`, whose secret is `secret`,
    receives to /tmp/ami-<user>.json"""
    for user in users:
        machine.succeed(f"systemd-run --unit=ami-{user} --collect ami events {user} {shlex.quote(secret)} /tmp/ami-{user}.json")
    for user in users:
        machine.wait_until_succeeds(f"head -n 1 /tmp/ami-{user}.json | grep -q '\"Response\": \"Success\"'")


def ami_done(machine, sender, secret, *users):
    """Send the UserEvent that ends the listeners as `sender`, whose secret is
    `secret`, and wait until each of `users` received it"""
    machine.succeed(f"ami run {sender} {shlex.quote(secret)} UserEvent UserEvent=Done")
    for user in users:
        machine.wait_until_succeeds(f"tail -n 1 /tmp/ami-{user}.json | grep -q '\"End\"'")
        assert machine.succeed(f"tail -n 1 /tmp/ami-{user}.json").strip() == '{"End": "Done"}'
