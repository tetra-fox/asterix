"""An AMI client for the VM tests, run on the machine Asterisk runs on.

    ami login USER SECRET [SOURCE]
        log in from the address SOURCE (127.0.0.1 unless given) and print
        Asterisk's answer
    ami run USER SECRET [--times N] ACTION [HEADER=VALUE ...]
        log in, send the action N times (once unless given) and print each
        response
    ami events USER SECRET FILE
        log in and write Asterisk's answer, then each event, to FILE as one
        JSON object per line, until a UserEvent named Done arrives or Asterisk
        closes the connection, which the last line says
"""

import json
import socket
import sys


def connect(source="127.0.0.1"):
    connection = socket.create_connection(
        ("127.0.0.1", 5038), timeout=60, source_address=(source, 0)
    )
    stream = connection.makefile("rw", encoding="utf-8", newline="")
    # Asterisk Call Manager/<version>
    stream.readline()
    return stream


def send(stream, action, headers):
    lines = [f"Action: {action}"]
    lines += [f"{key}: {value}" for key, value in headers]
    stream.write("\r\n".join(lines) + "\r\n\r\n")
    stream.flush()


def receive(stream):
    """The next message as a dict, or None once Asterisk closed the connection;
    of a key that repeats, like Output, the values are joined by line breaks"""
    message = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.rstrip("\r\n")
        if not line:
            if message:
                return message
            continue
        key, _, value = line.partition(": ")
        message[key] = f"{message[key]}\n{value}" if key in message else value


def login(stream, user, secret):
    send(stream, "Login", [("Username", user), ("Secret", secret)])
    while True:
        message = receive(stream)
        if message is None or "Response" in message:
            return message


def show(message):
    return "\n".join(f"{key}: {value}" for key, value in message.items())


def main(command, user, secret, *rest):
    if command == "login":
        stream = connect(*rest)
        print(show(login(stream, user, secret) or {"Response": "closed"}))
        return 0

    stream = connect()
    answer = login(stream, user, secret)
    if command == "events":
        (path,) = rest
        with open(path, "w") as out:

            def write(message):
                out.write(json.dumps(message) + "\n")
                out.flush()

            write(answer or {"Response": "closed"})
            while answer and answer["Response"] == "Success":
                message = receive(stream)
                if message is None:
                    write({"End": "closed"})
                    return 1
                write(message)
                if message.get("UserEvent") == "Done":
                    write({"End": "Done"})
                    return 0
        return 1

    if not answer or answer["Response"] != "Success":
        print(show(answer or {"Response": "closed"}))
        return 1
    times = 1
    if rest[0] == "--times":
        times = int(rest[1])
        rest = rest[2:]
    action, headers = rest[0], [header.split("=", 1) for header in rest[1:]]
    for i in range(times):
        send(stream, action, headers + [["ActionID", str(i)]])
    responses = 0
    while responses < times:
        message = receive(stream)
        if message is None:
            break
        if "Response" in message:
            responses += 1
            print(show(message) + "\n")
    send(stream, "Logoff", [])
    return 0 if responses == times else 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
