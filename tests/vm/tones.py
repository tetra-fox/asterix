# What test phones hear. Every phone sends a sine of its own frequency and
# records the audio of its calls (tests/vm/phone.nix); these helpers find the
# tones in each 100 ms of a recording. Tests append this file after phone.py,
# whose imports it uses, and add numpy to the driver with extraPythonPackages.
import base64

import numpy

WINDOW = 0.1
# pjsua and baresip write a 44 byte WAV header, then 16 bit mono samples
HEADER = 44
# a window this quiet (RMS of 16 bit samples) is silence; one phone's tone is
# about 1100
SILENCE = 300
# a peak below this share of the window's loudest is spectral leakage
PEAK = 0.1
# how far a measured tone may be from the one it is taken for, in Hz
TOLERANCE = 20


def recorded(phone):
    """Bytes of audio `phone` has recorded so far, a mark for heard()"""
    # baresip only creates its recording once a call's audio starts
    size = phone.machine.succeed(f"if test -e {phone.recording}; then stat -c %s {phone.recording}; else echo {HEADER}; fi")
    return int(size) - HEADER


def sample_rate(phone):
    header = base64.b64decode(phone.machine.succeed(f"head -c {HEADER} {phone.recording} | base64 -w0"))
    return int.from_bytes(header[24:28], "little")


def heard(phone, start, end=None):
    """The tones in each 100 ms `phone` heard between two marks, loudest first;
    an empty list is silence"""
    end = recorded(phone) if end is None else end
    # dd reads just this range; with tail | head, tail fails on the closed pipe
    # once the phone has recorded a pipe buffer past the range
    raw = base64.b64decode(
        phone.machine.succeed(
            f"dd if={phone.recording} iflag=skip_bytes,count_bytes skip={HEADER + start} count={end - start} status=none | base64 -w0"
        )
    )
    samples = numpy.frombuffer(raw[: len(raw) // 2 * 2], dtype="<i2").astype(float)
    return tones_in(samples, sample_rate(phone))


def tones_in(samples, rate):
    size = round(rate * WINDOW)
    hann = numpy.hanning(size)
    windows = []
    for offset in range(0, len(samples) - size + 1, size):
        chunk = samples[offset : offset + size]
        if numpy.sqrt(numpy.mean(chunk**2)) < SILENCE:
            windows.append([])
            continue
        spectrum = numpy.abs(numpy.fft.rfft(chunk * hann))
        floor = PEAK * spectrum.max()
        peaks = [
            k
            for k in range(1, len(spectrum) - 1)
            if spectrum[k] >= floor and spectrum[k - 1] < spectrum[k] >= spectrum[k + 1]
        ]
        peaks.sort(key=lambda k: -spectrum[k])
        windows.append([round(refine(spectrum, k) * rate / size) for k in peaks])
    return windows


def refine(spectrum, k):
    """The peak near bin k, from a parabola through the log magnitudes of k and its neighbours"""
    a, b, c = numpy.log(spectrum[k - 1 : k + 2])
    return k + 0.5 * (a - c) / (a - 2 * b + c)


def same(found, expected):
    return len(found) == len(expected) and all(any(abs(f - e) <= TOLERANCE for f in found) for e in expected)


def wait_hears(phone, expected, seconds=1.0, timeout=30):
    """Wait until every 100 ms of the last `seconds` of `phone`'s calls held
    exactly the tones `expected`, in Hz."""
    rate = sample_rate(phone)
    span = round(seconds / WINDOW) * round(rate * WINDOW) * 2
    deadline = time.time() + timeout
    while True:
        end = recorded(phone)
        windows = heard(phone, end - span, end) if end >= span else []
        if windows and all(same(window, expected) for window in windows):
            return windows
        if time.time() > deadline:
            raise Exception(f"{phone.name} did not hear {sorted(expected)} for {seconds} s, but {windows}")
        time.sleep(0.5)
