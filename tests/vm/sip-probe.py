# sip-probe SERVER METHOD USER [PASSWORD] [--to NUMBER] [--source ADDRESS]
#
# Sends one OPTIONS, REGISTER or INVITE over UDP as USER, to USER at SERVER
# or to NUMBER (REGISTER goes to SERVER itself), and prints each response as
# a line of JSON. With PASSWORD it answers the first 401 once with digest
# credentials, as a phone or a password guesser would. An INVITE's final
# response is acknowledged, and a call it set up is ended with BYE. With
# ADDRESS it sends from that address of the machine.
import argparse
import hashlib
import json
import secrets
import socket

parser = argparse.ArgumentParser()
parser.add_argument("server")
parser.add_argument("method")
parser.add_argument("user")
parser.add_argument("password", nargs="?")
parser.add_argument("--to")
parser.add_argument("--source")
args = parser.parse_args()
server, method, user, password = args.server, args.method, args.user, args.password
target = args.to or user

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if args.source:
    sock.bind((args.source, 0))
sock.connect((server, 5060))
sock.settimeout(5)
local, port = sock.getsockname()

call_id = secrets.token_hex(8)
from_tag = secrets.token_hex(4)
uri = f"sip:{server}" if method == "REGISTER" else f"sip:{target}@{server}"
sdp = f"v=0\r\no=probe 1 1 IN IP4 {local}\r\ns=-\r\nc=IN IP4 {local}\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"


def request(method, uri, cseq, branch, to_tag="", extra=(), body=""):
    headers = [
        f"{method} {uri} SIP/2.0",
        f"Via: SIP/2.0/UDP {local}:{port};rport;branch={branch}",
        "Max-Forwards: 70",
        f"From: <sip:{user}@{server}>;tag={from_tag}",
        f"To: <sip:{target}@{server}>" + (f";tag={to_tag}" if to_tag else ""),
        f"Call-ID: {call_id}",
        f"CSeq: {cseq} {method}",
        f"Contact: <sip:{user}@{local}:{port}>",
        *extra,
    ]
    if body:
        headers.append("Content-Type: application/sdp")
    headers.append(f"Content-Length: {len(body)}")
    sock.send(("\r\n".join(headers) + "\r\n\r\n" + body).encode())


def parse(data):
    """A response as its status, reason and headers."""
    head = data.decode(errors="replace").partition("\r\n\r\n")[0]
    first, *lines = head.split("\r\n")
    headers = [[name.strip(), value.strip()] for name, value in (line.split(":", 1) for line in lines if ":" in line)]
    _, status, reason = (first.split(" ", 2) + [""])[:3]
    return {"status": int(status), "reason": reason, "headers": headers}


def header(message, name):
    return next((value for key, value in message["headers"] if key.lower() == name.lower()), "")


def responses():
    """Responses to the request just sent, up to the final one."""
    while True:
        message = parse(sock.recv(65535))
        print(json.dumps(message), flush=True)
        if message["status"] >= 200:
            return message


def digest(challenge, method, uri):
    fields = dict(
        (key.strip(), value.strip().strip('"'))
        for key, value in (part.split("=", 1) for part in challenge.removeprefix("Digest ").split(",") if "=" in part)
    )
    realm, nonce = fields["realm"], fields["nonce"]
    cnonce = secrets.token_hex(8)
    ha1 = hashlib.md5(f"{user}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    answer = hashlib.md5(f"{ha1}:{nonce}:00000001:{cnonce}:auth:{ha2}".encode()).hexdigest()
    opaque = f', opaque="{fields["opaque"]}"' if "opaque" in fields else ""
    return (
        f'Authorization: Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{uri}", '
        f'response="{answer}", algorithm=MD5, cnonce="{cnonce}", qop=auth, nc=00000001{opaque}'
    )


def send(cseq, extra=()):
    branch = "z9hG4bK" + secrets.token_hex(8)
    extra = list(extra)
    if method == "REGISTER":
        extra.append("Expires: 60")
    request(method, uri, cseq, branch, extra=extra, body=sdp if method == "INVITE" else "")
    final = responses()
    if method == "INVITE":
        to_tag = header(final, "To").partition(";tag=")[2]
        if final["status"] < 300:
            contact = header(final, "Contact").strip("<>").split(">")[0]
            request("ACK", contact, cseq, "z9hG4bK" + secrets.token_hex(8), to_tag)
            request("BYE", contact, cseq + 1, "z9hG4bK" + secrets.token_hex(8), to_tag)
            responses()
        else:
            request("ACK", uri, cseq, branch, to_tag)
    return final


final = send(1)
if password is not None and final["status"] == 401:
    send(2, [digest(header(final, "WWW-Authenticate"), method, uri)])
