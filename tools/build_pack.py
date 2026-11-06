#!/usr/bin/env python3
"""Cuts real typing recordings into App/Resources/sounds.kcpack.

Sources are CC0 recordings (see docs/CREDITS.md). They are large, so they stay out of
git: put them in sources/raw/, named as Freesound names them. Needs ffmpeg and numpy.

For each recording this finds every transient, pairs key presses with their releases,
keeps only clean isolated ones, sorts them into key types by how they sound, trims the
room tail and levels the result. Key types are a best guess: nobody logged which key
made which sound. The largest, darkest presses become space, for example.

Usage: python3 tools/build_pack.py
"""
from __future__ import annotations

import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "sources" / "raw"
OUT = ROOT / "App" / "Resources" / "sounds.kcpack"
RATE = 48_000
VARIATIONS = 8
CLASSES = ("alpha", "space", "return", "backspace", "modifier")
TARGET_RMS = 0.16  # over the first 30 ms of an alpha press


@dataclass(frozen=True)
class Source:
    prefix: str
    label: str
    max_ms: float = 130.0  # longest sound to keep: anything beyond is mostly room
    onset_db: float = 12.0
    highpass: float = 70.0  # removes hum and the desk thump that a close mic picks up


# Order matches `allSwitches` in App/Preferences.swift.
SOURCES = (
    Source("123344", "Portable", max_ms=190),
    Source("224012", "Office", max_ms=170),
    Source("500430", "Terminal", highpass=90),
    Source("489423", "Spring"),
    Source("382057", "Clicky"),
    Source("628325", "Linear", highpass=110),
    Source("546033", "Dome", highpass=140),
    Source("665075", "Hobby"),
    Source("815614", "Gasket", highpass=160),
)


def decode(path: Path) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, "<f4").astype(np.float64)


def band(x: np.ndarray, low: float, high: float | None = None) -> np.ndarray:
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1 / RATE)
    gain = np.clip((freqs - low * 0.7) / (low * 0.3), 0, 1)
    if high:
        gain *= np.clip((high * 1.3 - freqs) / (high * 0.3), 0, 1)
    return np.fft.irfft(spectrum * gain, len(x))


def envelope_db(x: np.ndarray, hop: int, win: int) -> np.ndarray:
    power = np.concatenate(([0.0], np.cumsum(x * x)))
    starts = np.arange(0, max(len(x) - win, 1), hop)
    rms = np.sqrt((power[starts + win] - power[starts]) / win)
    return 20 * np.log10(rms + 1e-7)


@dataclass
class Sound:
    start: int
    end: int  # next transient, or end of file
    level: float
    is_up: bool = False


def find_transients(x: np.ndarray, source: Source) -> tuple[list[Sound], float]:
    hop = int(0.0005 * RATE)
    env = envelope_db(band(x, 900.0), hop, int(0.001 * RATE))
    floor = float(np.percentile(env, 15))
    look = int(0.006 * RATE / hop)
    baseline = np.array([env[max(0, i - look) : i + 1].min() for i in range(len(env))])
    rising = env - baseline
    gap = int(0.018 * RATE / hop)
    sounds: list[Sound] = []
    i = look
    while i < len(env):
        if rising[i] > source.onset_db and env[i] > floor + 14:
            peak = i + int(np.argmax(env[i : i + int(0.005 * RATE / hop)]))
            sounds.append(Sound(i * hop, len(x), float(env[peak])))
            i += gap
        else:
            i += 1
    for a, b in zip(sounds, sounds[1:]):
        a.end = b.start
    return sounds, floor


def keep_real_strikes(sounds: list[Sound]) -> list[Sound]:
    """Separates presses and releases from bounces, rattle and other small noises.

    Presses are the loud cluster. A release is the loudest quieter transient in the
    25-220 ms after a press. Anything else is dropped, and sounds no longer end at it:
    a typebar's bounce belongs to the strike that caused it.
    """
    if not sounds:
        return []
    top = float(np.percentile([s.level for s in sounds], 90))
    strong = top - 10.0
    kept: list[Sound] = []
    i = 0
    while i < len(sounds):
        press = sounds[i]
        if press.level < strong:
            i += 1
            continue
        kept.append(press)
        j = i + 1
        window: list[Sound] = []
        while j < len(sounds) and sounds[j].level < strong and sounds[j].start - press.start <= 0.22 * RATE:
            window.append(sounds[j])
            j += 1
        candidates = [w for w in window if w.start - press.start >= 0.025 * RATE and w.level > press.level - 26]
        if candidates:
            release = max(candidates, key=lambda w: w.level)
            release.is_up = True
            kept.append(release)
        i = j
    for a, b in zip(kept, kept[1:]):
        a.end = b.start
    return kept


def cut(x: np.ndarray, s: Sound, floor: float, source: Source) -> np.ndarray | None:
    pre = int(0.0015 * RATE)
    start = max(0, s.start - pre)
    end = min(s.end - int(0.0005 * RATE), start + int(source.max_ms / 1000 * RATE), len(x))
    if end - start < int(0.028 * RATE):
        return None  # another key lands too soon: it would be in this sound
    out = x[start:end].copy()

    # Must rise out of quiet, not out of the last key's tail.
    head = np.sqrt(np.mean(out[: pre // 2 + 1] ** 2)) + 1e-7
    peak = np.max(np.abs(out))
    if peak >= 0.985 or 20 * np.log10(peak / head) < 20:
        return None

    # One strike only. The peak must come early. If something later comes close to it,
    # that's a second key landing or rattle: end the sound just before it.
    per_ms = 2
    fine = envelope_db(out, int(0.0005 * RATE), int(0.002 * RATE))
    strike = int(np.argmax(fine))
    if strike > 16 * per_ms:
        return None
    settle = strike + 18 * per_ms
    if settle < len(fine):
        floor_so_far = np.minimum.accumulate(fine[settle:])
        rise = (fine[settle:] > floor_so_far + 9.0) & (fine[settle:] > fine[strike] - 22.0)
        if rise.any():
            limit_at = settle + int(np.argmax(rise))
            out = out[: max(int(0.024 * RATE), limit_at * int(0.0005 * RATE) - int(0.002 * RATE))]

    # Stop at the point the sound reaches the room: no reverb carried along.
    hop = int(0.001 * RATE)
    env = envelope_db(out, hop, int(0.004 * RATE))
    top = int(np.argmax(env))
    limit = max(env[top] - 38.0, floor + 5.0)
    below = np.nonzero(env[top:] < limit)[0]
    stop = len(out) if len(below) == 0 else min(len(out), (top + int(below[0])) * hop + int(0.012 * RATE))
    out = out[:stop]
    if len(out) < int(0.02 * RATE):
        return None

    # The tail fades slowly, so what remains of the room slips below hearing.
    fade = min(len(out) // 2, int(0.018 * RATE))
    out[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    attack = min(pre, len(out))
    out[:attack] *= np.linspace(0, 1, attack)
    return out


def centroid(s: np.ndarray) -> float:
    n = 4096
    mag = np.abs(np.fft.rfft(s * np.hanning(len(s)), n)) ** 2
    return float((np.fft.rfftfreq(n, 1 / RATE) * mag).sum() / (mag.sum() + 1e-12))


def rms30(s: np.ndarray) -> float:
    """Loudness as heard: ignores low end that laptop speakers can't play anyway."""
    head = band(s[: int(0.03 * RATE)], 250.0)
    return float(np.sqrt(np.mean(head**2))) + 1e-9


def pick_typical(items: list[np.ndarray], count: int) -> list[np.ndarray]:
    """The sounds nearest the middle in tone and loudness: outliers tend to be mistakes."""
    if len(items) <= count:
        return items
    tone = np.log([centroid(s) for s in items])
    loud = np.log([rms30(s) for s in items])
    length = np.array([len(s) for s in items], float)
    score = (np.abs(tone - np.median(tone)) / (np.std(tone) + 1e-9)
             + 0.6 * np.abs(loud - np.median(loud)) / (np.std(loud) + 1e-9)
             - 0.5 * length / length.max())
    ranked = np.argsort(score)[: count * 2]
    # Keep variety: evenly across the good ones, rather than eight near-identical takes.
    return [items[int(i)] for i in sorted(ranked, key=lambda k: tone[k])[:: 2][: count]]


def classify(presses: list[np.ndarray]) -> dict[str, list[np.ndarray]]:
    tone = np.array([centroid(s) for s in presses])
    loud = np.array([rms30(s) for s in presses])
    order = np.argsort(tone)
    count = len(presses)
    dark = order[: max(4, count // 8)]
    next_dark = order[max(4, count // 8) : max(10, count // 3)]
    quiet_cut = np.percentile(loud, 25)
    middle = order[count // 4 : count * 3 // 4]
    used: dict[str, list[np.ndarray]] = {
        "space": [presses[i] for i in dark if loud[i] >= np.median(loud) * 0.7] or [presses[i] for i in dark],
        "return": [presses[i] for i in next_dark[::2]],
        "backspace": [presses[i] for i in next_dark[1::2]],
        "modifier": [presses[i] for i in order if loud[i] <= quiet_cut],
        "alpha": [presses[i] for i in middle],
    }
    return {name: items or [presses[i] for i in middle] for name, items in used.items()}


def level(groups: dict[str, list[np.ndarray]], gain: float, classes_extra: dict[str, float]) -> dict[str, list[np.ndarray]]:
    out = {}
    for name, items in groups.items():
        leveled = []
        for s in items:
            g = gain * classes_extra.get(name, 1.0) / rms30(s)
            t = s * g
            peak = np.max(np.abs(t))
            leveled.append(t * (0.94 / peak) if peak > 0.94 else t)
        out[name] = leveled
    return out


def mouse_clicks() -> tuple[list[np.ndarray], list[np.ndarray]]:
    """Clicks from the mouse recording: a press, then a release 70-150 ms later.

    Both must sit in the level range of a normal click. Much louder hits in this
    recording clip, and are the mouse being handled. Quieter ones are it being moved.
    """
    x = band(decode(next(RAW.glob("514861__*"))), 120.0)
    hop = int(0.0005 * RATE)
    env = envelope_db(band(x, 1000.0), hop, int(0.001 * RATE))
    look = 12
    baseline = np.array([env[max(0, i - look) : i + 1].min() for i in range(len(env))])
    hits: list[tuple[int, float]] = []
    i = look
    while i < len(env):
        if env[i] - baseline[i] > 12 and env[i] > -45:
            hits.append((i * hop, float(env[i : i + 20].max())))
            i += 40
        else:
            i += 1

    def take(start: int, end: int) -> np.ndarray:
        begin = start - int(0.001 * RATE)
        out = x[begin : min(end - int(0.002 * RATE), begin + int(0.05 * RATE))].copy()
        fade = len(out) // 2
        out[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
        out[: int(0.001 * RATE)] *= np.linspace(0, 1, int(0.001 * RATE))
        return out

    normal = (-32.0, -18.0)
    presses, releases = [], []
    for k in range(1, len(hits) - 2):
        (a, la), (b, lb) = hits[k], hits[k + 1]
        gap = (b - a) / RATE
        clear_before = (a - hits[k - 1][0]) / RATE > 0.05
        clear_after = (hits[k + 2][0] - b) / RATE > 0.03
        if (0.07 <= gap <= 0.15 and clear_before and clear_after
                and normal[0] <= la <= normal[1] and normal[0] <= lb <= normal[1]):
            presses.append(take(a, b))
            releases.append(take(b, hits[k + 2][0]))
    # A real mouse press and release are about as loud as each other, so level them together.
    gain = 0.075 / float(np.median([rms30(s) for s in presses]))
    gain = min(gain, 0.8 / max(float(np.max(np.abs(s))) for s in presses + releases))
    print(f"mouse: {len(presses)} clean clicks")
    return [s * gain for s in presses], [s * gain for s in releases]


def find_bell(x: np.ndarray) -> np.ndarray | None:
    """The line-end bell of the manual typewriter: the one sustained, pure tone in it."""
    n, hop = 4096, 1024
    window = np.hanning(n)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    in_band = (freqs > 1000) & (freqs < 9000)
    best: tuple[int, int] | None = None
    last, run_start, run = 0.0, 0, 0
    for i in range((len(x) - n) // hop):
        power = np.abs(np.fft.rfft(x[i * hop : i * hop + n] * window)) ** 2
        b = power[in_band]
        k = int(np.argmax(b))
        tonal = b[max(0, k - 2) : k + 3].sum() / (b.sum() + 1e-15)
        hz = float(freqs[in_band][k])
        if tonal > 0.35 and abs(hz - last) < 30:
            run += 1
        else:
            run, run_start, last = 0, i, hz
        if run >= 8 and (best is None or run > best[1]):
            best = (run_start, run)
    if best is None:
        return None
    start = max(0, best[0] * hop - int(0.015 * RATE))
    # The carriage starts to move about 300 ms in, so the bell has to end before that.
    out = band(x[start : min(len(x), start + int(0.285 * RATE))], 1500.0, 9000.0)
    fade = int(0.12 * RATE)
    out[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    return out * (0.4 / np.max(np.abs(out)))


def main() -> None:
    entries: dict[tuple[int, int, int, int], np.ndarray] = {}
    bell = None
    print(f"{'switch':10} {'dur s':>6} {'noise':>7} {'hits':>5} {'press':>6} {'release':>8} {'clean dn':>8} {'clean up':>8}")
    for p, source in enumerate(SOURCES):
        path = next(RAW.glob(source.prefix + "__*"))
        x = decode(path)
        x = band(x, source.highpass)
        peak = np.max(np.abs(x))
        x = x / peak * 0.95 if peak > 0 else x
        sounds, floor = find_transients(x, source)
        hits = len(sounds)
        sounds = keep_real_strikes(sounds)

        downs_all = [s for s in sounds if not s.is_up]
        ups_all = [s for s in sounds if s.is_up]
        downs = [c for s in downs_all if (c := cut(x, s, floor, source)) is not None]
        ups = [c for s in ups_all if (c := cut(x, s, floor, source)) is not None]
        print(f"{source.label:10} {len(x) / RATE:6.0f} {floor:7.1f} {hits:5} {len(downs_all):6} "
              f"{len(ups_all):8} {len(downs):8} {len(ups):8}")
        if len(downs) < VARIATIONS:
            raise SystemExit(f"{source.label}: only {len(downs)} clean presses")

        groups = classify(downs)
        # Keep each key type's natural loudness relative to letters, within reason.
        base = float(np.median([rms30(s) for s in groups["alpha"]]))
        relative = {name: float(np.clip(np.median([rms30(s) for s in items]) / base, 0.7, 1.25))
                    for name, items in groups.items()}
        presses = level({n: pick_typical(i, VARIATIONS) for n, i in groups.items()}, TARGET_RMS, relative)

        release_ratio = float(np.clip(np.median([rms30(s) for s in ups]) / base, 0.18, 0.7)) if ups else 0.35
        releases = ups if len(ups) >= 4 else downs  # some recordings are too fast to separate
        chosen_up = level({"alpha": pick_typical(releases, VARIATIONS)}, TARGET_RMS * release_ratio, {})["alpha"]

        for c, name in enumerate(CLASSES):
            for v in range(VARIATIONS):
                items = presses[name]
                entries[(p, c, 0, v)] = items[v % len(items)]
                entries[(p, c, 1, v)] = chosen_up[(v + c) % len(chosen_up)]
        if source.prefix == "123344":
            bell = find_bell(x)

    bank = len(SOURCES)
    presses, releases = mouse_clicks()
    if len(presses) < 3:
        raise SystemExit("too few clean mouse clicks")
    for v in range(VARIATIONS):
        entries[(bank, 0, 0, v)] = presses[v % len(presses)]
        entries[(bank, 0, 1, v)] = releases[v % len(releases)]
    if bell is None:
        raise SystemExit("no bell found in the typewriter recording")
    entries[(bank, 1, 0, 0)] = bell

    write_pack(entries, len(SOURCES) + 1)


def write_pack(entries: dict[tuple[int, int, int, int], np.ndarray], profiles: int) -> None:
    table = bytearray()
    samples: list[np.ndarray] = []
    offsets: dict[int, int] = {}  # the same take used in several slots is stored once
    cursor = 0
    for p in range(profiles):
        for c in range(len(CLASSES)):
            for up in (0, 1):
                for v in range(VARIATIONS):
                    s = entries.get((p, c, up, v))
                    if s is None:
                        table += struct.pack("<II", 0, 0)
                        continue
                    key = id(s)
                    if key not in offsets:
                        offsets[key] = cursor
                        samples.append(s.astype("<f4"))
                        cursor += len(s)
                    table += struct.pack("<II", offsets[key], len(s))
    header = 24
    data = header + len(table)
    data += (4 - data % 4) % 4
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("wb") as f:
        f.write(struct.pack("<4sIIIII", b"KCPK", 1, RATE, profiles, VARIATIONS, data))
        f.write(table)
        f.write(b"\0" * (data - header - len(table)))
        for s in samples:
            f.write(s.tobytes())
    print(f"{OUT.name}: {OUT.stat().st_size / 1e6:.2f} MB, {cursor / RATE:.1f} s, {len(samples)} sounds")


if __name__ == "__main__":
    main()
