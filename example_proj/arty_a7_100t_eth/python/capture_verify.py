#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# capture_verify.py - capture N complete RTP/JPEG frames from the live stream,
# decode them, and VERIFY end-to-end without a GUI:
#   * frames are valid and the box MOVES (per-frame diff centroid),
#   * report the measured colorbar RGB so the color pipeline can be checked,
#   * save frames (png+jpg) and an animated motion.gif as evidence.
#
# Usage: python capture_verify.py [num_frames] [port]

import io
import socket
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtp_jpeg_recv import build_jfif   # noqa: E402
from PIL import Image                   # noqa: E402

try:
    import numpy as np
    HAVE_NP = True
except Exception:
    HAVE_NP = False

N = int(sys.argv[1]) if len(sys.argv) > 1 else 24
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5004
OUT = Path(__file__).resolve().parents[1] / "build" / "frames"
OUT.mkdir(parents=True, exist_ok=True)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
sock.bind(("0.0.0.0", PORT))
sock.settimeout(6)

frames, frags, lqt, cqt, wd, hd = [], {}, None, None, 0, 0
print("capturing %d frames on udp/%d ..." % (N, PORT))
while len(frames) < N:
    try:
        pkt, _ = sock.recvfrom(2048)
    except socket.timeout:
        print("TIMEOUT (got %d frames) - is the FPGA streaming?" % len(frames))
        break
    if len(pkt) < 20 or (pkt[1] & 0x7F) != 26:
        continue
    marker = (pkt[1] >> 7) & 1
    o = 12
    frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
    q = pkt[o + 5]
    wd, hd = pkt[o + 6] * 8, pkt[o + 7] * 8
    o += 8
    if frag == 0 and q >= 128:
        o += 4
        lqt, cqt = pkt[o:o + 64], pkt[o + 64:o + 128]
        o += 128
    frags[frag] = pkt[o:]
    if marker:
        if lqt is not None and 0 in frags:
            scan = b"".join(frags[k] for k in sorted(frags))
            frames.append(build_jfif(wd, hd, lqt, cqt, scan))
        frags, lqt, cqt = {}, None, None
sock.close()

imgs = []
for i, jpg in enumerate(frames):
    try:
        img = Image.open(io.BytesIO(jpg)).convert("RGB")
        img.load()
    except Exception as e:
        print("  frame %d decode FAILED: %s" % (i, e))
        continue
    imgs.append(img)
    img.save(OUT / ("f%03d.png" % i))
    (OUT / ("f%03d.jpg" % i)).write_bytes(jpg)
print("decoded %d/%d frames, %dx%d -> %s" % (len(imgs), len(frames), wd, hd, OUT))

if HAVE_NP and len(imgs) >= 2:
    print("\nMOTION (changed pixels + centroid of the change, vs previous frame):")
    cxs = []
    for i in range(1, len(imgs)):
        a = np.asarray(imgs[i - 1]).astype(int)
        b = np.asarray(imgs[i]).astype(int)
        d = np.abs(a - b).sum(axis=2)
        m = d > 60
        n = int(m.sum())
        if n > 50:
            ys, xs = np.nonzero(m)
            cx, cy = int(xs.mean()), int(ys.mean())
            cxs.append(cx)
            print("  f%03d->f%03d: changed=%6d px  centroid=(%4d,%4d)  meandiff=%.2f"
                  % (i - 1, i, n, cx, cy, d.mean()))
        else:
            print("  f%03d->f%03d: ~no change (%d px)" % (i - 1, i, n))
    if len(cxs) >= 2:
        span = max(cxs) - min(cxs)
        print("  => box horizontal travel across capture: %d px  (motion %s)"
              % (span, "CONFIRMED" if span > 20 else "NOT seen"))

if HAVE_NP and imgs:
    print("\nCOLOR (vertical strip sampled near top, 8 bars, expected SMPTE):")
    exp = ["white", "yellow", "cyan", "green", "magenta", "red", "blue", "black"]
    arr = np.asarray(imgs[0])
    y = max(2, hd // 10)
    for k in range(8):
        x = int((k + 0.5) * wd / 8)
        r, g, b = (int(v) for v in arr[y, x])
        print("  bar %d @x=%4d  RGB=(%3d,%3d,%3d)   expected ~%s" % (k, x, r, g, b, exp[k]))

if len(imgs) >= 2:
    gif = OUT / "motion.gif"
    sm = [im.resize((wd // 2, hd // 2)) for im in imgs]
    sm[0].save(gif, save_all=True, append_images=sm[1:], duration=120, loop=0)
    print("\nmotion evidence GIF: %s" % gif)
