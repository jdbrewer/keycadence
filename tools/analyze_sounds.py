#!/usr/bin/env python3
"""Prints spectral and loudness figures for each switch, and draws their waveforms."""
import struct
import sys
from pathlib import Path

import numpy as np

path = Path(__file__).resolve().parent.parent / "App" / "Resources" / "sounds.kcpack"
d = path.read_bytes()
_, _, rate, prof, var, off = struct.unpack("<4sIIIII", d[:24])
tab = np.frombuffer(d, "<u4", offset=24, count=prof * 5 * 2 * var * 2).reshape(prof, 5, 2, var, 2)
pcm = np.frombuffer(d, "<f4", offset=off)
names = "Portable Office Terminal Spring Clicky Linear Dome Hobby Gasket".split()


def spectrum(s):
    m = np.abs(np.fft.rfft(s * np.hanning(len(s)), 8192)) ** 2
    f = np.fft.rfftfreq(8192, 1 / rate)
    return (f * m).sum() / m.sum(), m[f < 300].sum() / m.sum() * 100


print(f"{'switch':10} {'dn ms':>6} {'up ms':>6} {'peak':>5} {'centroid':>8} {'space':>6} {'<300Hz%':>8} {'up/dn dB':>8} {'crest':>6} {'t60-ish':>7}")
for p, n in enumerate(names):
    down = [pcm[o : o + l] for o, l in tab[p, 0, 0]]
    up = [pcm[o : o + l] for o, l in tab[p, 0, 1]]
    space = [pcm[o : o + l] for o, l in tab[p, 1, 0]]
    r = np.mean([np.sqrt((s[:1440] ** 2).mean()) for s in down])
    ru = np.mean([np.sqrt((s[:1440] ** 2).mean()) for s in up])
    crest = np.mean([np.abs(s).max() / np.sqrt((s**2).mean()) for s in down])
    decay = []
    for s in down:
        e = np.abs(s)
        i = np.argmax(e)
        below = np.nonzero(e[i:] < e[i] * 0.03)[0]
        decay.append((below[0] if len(below) else len(s) - i) / rate * 1000)
    print(f"{n:10} {np.mean([len(s) for s in down]) / rate * 1000:6.0f} {np.mean([len(s) for s in up]) / rate * 1000:6.0f} "
          f"{max(abs(s).max() for s in down):5.2f} {np.mean([spectrum(s)[0] for s in down]):8.0f} "
          f"{np.mean([spectrum(s)[0] for s in space]):6.0f} {np.mean([spectrum(s)[1] for s in down]):8.1f} "
          f"{20 * np.log10(ru / r):8.1f} {crest:6.1f} {np.median(decay):7.1f}")

if len(sys.argv) > 1:
    # One row per switch, eight columns of alpha presses, as a simple PGM image.
    cols, rows, w, h = var, len(names), 150, 60
    img = np.full((h * rows, w * cols), 255, dtype=np.uint8)
    for p in range(rows):
        for v in range(cols):
            o, l = tab[p, 0, 0, v]
            s = pcm[o : o + l]
            scale = 0.2 * rate / w  # 200 ms across
            for x in range(min(w, int(l / scale))):
                seg = s[int(x * scale) : int((x + 1) * scale) + 1]
                a = int(min(1.0, np.abs(seg).max()) * (h / 2 - 2))
                img[p * h + h // 2 - a : p * h + h // 2 + a + 1, v * w + x] = 40
            img[p * h, v * w : (v + 1) * w] = 200
            img[p * h : (p + 1) * h, v * w] = 200
    Path(sys.argv[1]).write_bytes(f"P5 {img.shape[1]} {img.shape[0]} 255\n".encode() + img.tobytes())
