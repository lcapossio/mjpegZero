#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Analyze already-captured build/frames/f*.png: classify good vs blank,
# report jpg sizes, and track box motion among the good frames.
import sys
from pathlib import Path
import numpy as np
from PIL import Image

d = Path(__file__).resolve().parents[1] / "build" / "frames"
pngs = sorted(d.glob("f*.png"))
arrs = []
print("idx   jpgbytes    std    mean   class")
for p in pngs:
    jpg = p.with_suffix(".jpg")
    sz = jpg.stat().st_size if jpg.exists() else 0
    a = np.asarray(Image.open(p).convert("RGB")).astype(int)
    arrs.append((int(p.stem[1:]), a))
    std = a.std()
    cls = "blank" if std < 30 else "good"
    print("%3d  %9d  %6.1f %6.1f  %s" % (int(p.stem[1:]), sz, std, a.mean(), cls))

good = [(i, a) for i, a in arrs if a.std() >= 30]
print("\n%d good frames, %d blank" % (len(good), len(arrs) - len(good)))
for j in range(1, len(good)):
    i0, a0 = good[j - 1]
    i1, a1 = good[j]
    dd = np.abs(a0 - a1).sum(axis=2)
    m = dd > 60
    n = int(m.sum())
    if n > 50:
        ys, xs = np.nonzero(m)
        print("  good f%03d->f%03d: changed=%6d  centroid=(%4d,%4d)"
              % (i0, i1, n, int(xs.mean()), int(ys.mean())))
    else:
        print("  good f%03d->f%03d: IDENTICAL (%d px)" % (i0, i1, n))
