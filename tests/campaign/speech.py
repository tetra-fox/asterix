#!/usr/bin/env python3
"""Check the words of the voice menu prompts flite speaks, as a phone hears
them over a call, with speech recognition on the CPU (speech.nix):

    speech.py OUT [--flake DIR] [--threads 8]

Builds the recordings (a VM test), whisper.cpp and its English base model,
transcribes each recording and compares its words with the menu's text, both
in lower case, without punctuation and with numbers as words. OUT gets the
recordings at 16 kHz and results.json with each prompt's text, transcript,
word error rate and seconds taken; the exit code is 1 when more than
MAX_ERROR_RATE of a prompt's words came out wrong and no finding explains
it.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

ONES = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen"
).split()
# from twenty
TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()
# where flite's voice runs words together, whisper hears a word or two of a
# sentence as others, such as "a message" as "the message"; a prompt that lost
# words, stops early or is another prompt gets far more wrong
MAX_ERROR_RATE = 0.1


def build(flake, attribute):
    expression = f"(import {flake}/tests/campaign/speech.nix {{ self = builtins.getFlake {json.dumps(flake)}; }}).{attribute}"
    return subprocess.run(
        ["nix", "build", "--no-link", "--print-out-paths", "--impure", "--expr", expression],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()[0]


def spoken(number):
    """A number below 100 as words, a longer one digit by digit."""
    value = int(number)
    if value < 20:
        return ONES[value]
    if value < 100:
        return TENS[value // 10 - 2] + ("" if value % 10 == 0 else f" {ONES[value % 10]}")
    return " ".join(ONES[int(digit)] for digit in number)


def words(text):
    """Lower case words without punctuation, with numbers as words."""
    text = re.sub(r"\d+", lambda number: f" {spoken(number.group())} ", text.lower().replace("&", " and "))
    return re.findall(r"[^\W_]+(?:'[^\W_]+)?", text)


def errors(expected, heard):
    """Words substituted, left out or added between two lists of words."""
    row = list(range(len(heard) + 1))
    for i, word in enumerate(expected, 1):
        previous, row[0] = row[0], i
        for j, other in enumerate(heard, 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, previous + (word != other))
    return row[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=pathlib.Path)
    parser.add_argument("--flake", default=".")
    parser.add_argument("--threads", default="8")
    args = parser.parse_args()
    flake = str(pathlib.Path(args.flake).resolve())
    args.out.mkdir(parents=True, exist_ok=True)

    started = time.monotonic()
    recordings = pathlib.Path(build(flake, "recordings"))
    print(f"recordings: {recordings} ({time.monotonic() - started:.0f} s)", flush=True)
    whisper = build(flake, "whisper")
    model = build(flake, "model")
    sox = build(flake, "sox")

    prompts = json.loads((recordings / "prompts.json").read_text())
    results = {}
    for name, prompt in sorted(prompts.items()):
        # whisper.cpp reads 16 bit mono WAV at 16 kHz
        audio = args.out / f"{name}.wav"
        subprocess.run([f"{sox}/bin/sox", recordings / f"{name}.wav", "-r", "16000", "-c", "1", "-b", "16", audio], check=True)
        start = time.monotonic()
        transcript = subprocess.run(
            [f"{whisper}/bin/whisper-cli", "-m", model, "-f", audio, "-l", "en", "-t", args.threads, "-nt", "-np"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        seconds = time.monotonic() - start
        expected, heard = words(prompt["text"]), words(transcript)
        wrong = errors(expected, heard)
        rate = wrong / len(expected)
        results[name] = {
            "text": prompt["text"],
            "transcript": transcript,
            "wordErrors": wrong,
            "wordErrorRate": round(rate, 3),
            "wrong": rate > MAX_ERROR_RATE,
            "seconds": round(seconds, 1),
            "known": prompt.get("known"),
        }
        verdict = f"{wrong} of {len(expected)} words wrong" + (f", known: {prompt['known']}" if prompt.get("known") else "")
        print(f"{name}: {verdict}, {seconds:.1f} s\n  text:  {prompt['text']}\n  heard: {transcript}", flush=True)

    (args.out / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    unexplained = [name for name, result in results.items() if result["wrong"] and not result["known"]]
    known = [name for name, result in results.items() if result["wrong"] and result["known"]]
    # a known finding that no longer shows is worth saying too
    fixed = [name for name, result in results.items() if not result["wrong"] and result["known"]]
    print(f"{len(results)} prompts: {len(unexplained)} wrong, {len(known)} known, {len(fixed)} known but now right")
    return 1 if unexplained else 0


if __name__ == "__main__":
    sys.exit(main())
