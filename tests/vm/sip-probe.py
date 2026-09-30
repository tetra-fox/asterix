# sip-probe SERVER METHOD USER [PASSWORD] [--to NUMBER]
#
# Sends one OPTIONS, REGISTER or INVITE over UDP as USER, to USER at SERVER
# or to NUMBER (REGISTER goes to SERVER itself), and prints each response as
# a line of JSON. With PASSWORD it answers the first 401 once with digest
# credentials, as a phone or a password guesser would. An INVITE's final
# response is acknowledged, and a call it set up is ended with BYE.
import argparse
import hashlib
import json
import secrets
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("server")
parser.add_argument("method")
parser.add_argument("user")
parser.add_argument("password", nargs="?")
parser.add_argument("--to")
args = parser.parse_args()
server, method, user, password = args.server, args.method, args.user, args.password
target = args.to or user

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
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
    head = data.decode(errors="replace").split("\r\n\r\n", 1)[0].split("\r\n")
    _, status, reason = (head[0].split(" ", 2) + [""])[:3]
    headers = [line.split(":", 1) for line in head[1:] if ":" in line]
    return {"status": int(status), "reason": reason, "headers": [[name.strip(), value.strip()] for name, value in headers]}


def header(response, name):
    return next((value for key, value in response["headers"] if key.lower() == name.lower()), "")


def responses(sent):
    """Responses to the request sent at `sent`, up to the final one."""
    while True:
        response = parse(sock.recv(65535))
        response["elapsed"] = round((time.monotonic() - sent) * 1000, 1)
        print(json.dumps(response), flush=True)
        if response["status"] >= 200:
            return response


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
    extra = [*extra, "Expires: 60"] if method == "REGISTER" else list(extra)
    request(method, uri, cseq, branch, extra=extra, body=sdp if method == "INVITE" else "")
    final = responses(time.monotonic())
    if method == "INVITE":
        to_tag = header(final, "To").partition(";tag=")[2]
        if final["status"] < 300:
            contact = header(final, "Contact").strip("<>").split(">")[0]
            request("ACK", contact, cseq, "z9hG4bK" + secrets.token_hex(8), to_tag)
            request("BYE", contact, cseq + 1, "z9hG4bK" + secrets.token_hex(8), to_tag)
            responses(time.monotonic())
        else:
            request("ACK", uri, cseq, branch, to_tag)
    return final


final = send(1)
if password is not None and final["status"] == 401:
    send(2, [digest(header(final, "WWW-Authenticate"), method, uri)])
