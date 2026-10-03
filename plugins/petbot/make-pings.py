#!/usr/bin/env python3
"""Generate the sound-sensor pin pings: pin-on.wav and pin-off.wav.

Two-note sci-fi blips (ascending = pin on, descending = pin off) with a
multi-tap echo for a reverb-ish tail. Pure stdlib; run from this directory:

    python3 make-pings.py

B5 -> E6 ascending reads as "engaged", the reverse as "released".
"""

import math
import struct
import wave

SR = 44100
B5 = 987.77
E6 = 1318.51


def note(freq: float, start: float, dur: float) -> list[float]:
    """One decaying blip: fundamental + 2nd/3rd harmonic, 4 ms attack."""
    n = int(dur * SR)
    out = []
    for i in range(n):
        t = i / SR
        env = min(1.0, t / 0.004) * math.exp(-t / 0.09)
        s = math.sin(2 * math.pi * freq * t)
        s += 0.40 * math.sin(2 * math.pi * freq * 2 * t)
        s += 0.12 * math.sin(2 * math.pi * freq * 3 * t)
        out.append(s * env)
    # pad with zeros so notes can be placed by absolute start time
    pad_before = [0.0] * int(start * SR)
    return pad_before + out


def reverb(x: list[float], taps: list[tuple[float, float]]) -> list[float]:
    """Multi-tap echo: cheap Schroeder-flavoured reverb tail."""
    out = [0.0] * (len(x) + int(max(d for d, _ in taps) * SR) + 1)
    dry = 0.8
    for i, v in enumerate(x):
        out[i] += v * dry
        for delay, gain in taps:
            j = i + int(delay * SR)
            out[j] += v * gain
    return out


def write_wav(path: str, x: list[float], peak: float = 0.65) -> None:
    m = max(abs(v) for v in x) or 1.0
    x = [v * peak / m for v in x]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in x))
    print(f"wrote {path} ({len(x) / SR:.2f} s)")


TAPS = [(0.057, 0.32), (0.111, 0.20), (0.173, 0.12), (0.241, 0.07)]
NOTE = 0.30

on = note(B5, 0.0, NOTE)
off = note(E6, 0.0, NOTE)
length = int((NOTE + 0.09) * SR)  # second note starts 90 ms in
on = on[:length] + note(E6, 0.0, NOTE)[: length]
off = off[:length] + note(B5, 0.0, NOTE)[: length]

write_wav("pin-on.wav", reverb(on, TAPS))
write_wav("pin-off.wav", reverb(off, TAPS))


# ---- message-pop blooms (2026-10-03) ----------------------------------------
# A smooth, "spatial" bloom when the pet says something: a soft bell sweep with
# decorrelated stereo reverb taps (different delays per channel = spaciousness)
# and pan baked in - the widget picks the pan side from its position on screen.
import wave as _wave


def bloom(mono: list[float]) -> list[float]:
    n = int(1.05 * SR)
    out = [0.0] * n
    for i in range(min(n, len(mono))):
        out[i] = mono[i]
    return out


def bloom_tone() -> list[float]:
    n = int(1.05 * SR)
    out = []
    for i in range(n):
        t = i / SR
        env = min(1.0, t / 0.025) * math.exp(-t / 0.35)
        sweep = 520 + (660 - 520) * min(1.0, t / 0.12)
        s = math.sin(2 * math.pi * sweep * t)
        s += 0.45 * math.sin(2 * math.pi * 660 * t)
        s += 0.18 * math.sin(2 * math.pi * 1320 * t)
        out.append(s * env)
    return out


def stereo_reverb(mono: list[float], taps_l, taps_r, dry_l: float,
                  dry_r: float, tail: float = 0.5) -> tuple[list, list]:
    n = len(mono) + int(tail * SR) + 1
    L = [0.0] * n
    R = [0.0] * n
    for i, v in enumerate(mono):
        L[i] += v * dry_l
        R[i] += v * dry_r
        for d, g in taps_l:
            L[i + int(d * SR)] += v * g
        for d, g in taps_r:
            R[i + int(d * SR)] += v * g
    return L, R


def write_wav_stereo(path: str, L: list[float], R: list[float],
                     peak: float = 0.55) -> None:
    m = max(max(abs(v) for v in L), max(abs(v) for v in R)) or 1.0
    L = [v * peak / m for v in L]
    R = [v * peak / m for v in R]
    with _wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<hh",
                        int(max(-1.0, min(1.0, l)) * 32767),
                        int(max(-1.0, min(1.0, r)) * 32767))
            for l, r in zip(L, R))
        w.writeframes(frames)
    print(f"wrote {path} ({len(L) / SR:.2f} s stereo)")


TAPS_L = [(0.083, 0.30), (0.147, 0.18), (0.211, 0.10), (0.290, 0.05)]
TAPS_R = [(0.091, 0.30), (0.153, 0.18), (0.223, 0.10), (0.310, 0.05)]
tone = bloom(bloom_tone())
write_wav_stereo("msg-pop-right.wav", *stereo_reverb(tone, TAPS_L, TAPS_R, 0.85, 0.40))
write_wav_stereo("msg-pop-left.wav", *stereo_reverb(tone, TAPS_L, TAPS_R, 0.40, 0.85))
