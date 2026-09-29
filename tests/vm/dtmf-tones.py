# Writes the WAV files that test phones play to press keys inband
# (tests/vm/dtmf.nix). Each file is a list of parts, seconds of silence or a
# string of keys, each key 100 ms of its two tones and 100 ms of silence, and
# ends in 60 s of silence, so a call hears the keys once before pjsua loops.
#
#   dtmf-tones.py OUT '{"keys.wav": [1.5, "0123#"], ...}'
import json
import math
import struct
import sys
import wave

from tones import DTMF_COLUMNS, DTMF_KEYS, DTMF_ROWS

RATE = 8000


def tone(key):
    row = next(i for i, keys in enumerate(DTMF_KEYS) if key in keys)
    column = DTMF_KEYS[row].index(key)
    return [
        round(8000 * (math.sin(2 * math.pi * DTMF_ROWS[row] * n / RATE) + math.sin(2 * math.pi * DTMF_COLUMNS[column] * n / RATE)))
        for n in range(RATE // 10)
    ]


def silence(seconds):
    return [0] * round(RATE * seconds)


out, files = sys.argv[1], json.loads(sys.argv[2])
for name, parts in files.items():
    samples = []
    for part in parts:
        if isinstance(part, str):
            for key in part:
                samples += tone(key) + silence(0.1)
        else:
            samples += silence(part)
    samples += silence(60)
    with wave.open(f"{out}/{name}", "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(struct.pack(f"<{len(samples)}h", *samples))
