"""A Stasis application for the VM tests, run on the machine Asterisk runs on.

    stasis APP USER:PASSWORD SOUND LOG

It answers the first channel that enters APP, plays SOUND to it, hangs it up
once the sound has finished and exits when the channel leaves APP. LOG gets
`connected` once ARI's event WebSocket is open, then the type of each event.
"""

import base64
import json
import sys
import urllib.request

import websocket

app, credentials, sound, log_path = sys.argv[1:]
authorization = "Basic " + base64.b64encode(credentials.encode()).decode()


def request(method, path):
    urllib.request.urlopen(
        urllib.request.Request(
            f"http://127.0.0.1:8088/ari{path}",
            method=method,
            headers={"Authorization": authorization},
        )
    )


events = websocket.create_connection(
    f"ws://127.0.0.1:8088/ari/events?app={app}",
    header=[f"Authorization: {authorization}"],
)
with open(log_path, "w") as log:
    print("connected", file=log, flush=True)
    while True:
        event = json.loads(events.recv())
        print(event["type"], file=log, flush=True)
        if event["type"] == "StasisStart":
            channel = event["channel"]["id"]
            request("POST", f"/channels/{channel}/answer")
            request("POST", f"/channels/{channel}/play?media=sound:{sound}")
        elif event["type"] == "PlaybackFinished":
            request("DELETE", f"/channels/{channel}")
        elif event["type"] == "StasisEnd":
            break
