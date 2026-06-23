#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Capture the streamed frames from frame 0 (bind, then trigger) and report the
# black-bar luma per frame. Flat-washed across frames => byte-path bug;
# clean(frame0)->washed progression => encoder drift over frames.
import io
import socket
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtp_jpeg_recv import build_jfif   # noqa: E402
import numpy as np                     # noqa: E402
from PIL import Image                  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 12
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
sock.bind(("0.0.0.0", 5004))
# trigger AFTER binding so we catch frame 0
t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
t.sendto(b"GO", ("192.168.237.50", 9999))
t.close()
sock.settimeout(6)

frames, frags, lqt, cqt, w, h = [], {}, None, None, 0, 0
while len(frames) < N:
    try:
        pkt, _ = sock.recvfrom(2048)
    except socket.timeout:
        break
    if len(pkt) < 20 or (pkt[1] & 0x7F) != 26:
        continue
    o = 12
    frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
    q = pkt[o + 5]
    w, h = pkt[o + 6] * 8, pkt[o + 7] * 8
    b = o + 8
    if frag == 0 and q >= 128:
        b += 4
        lqt, cqt = pkt[b:b + 64], pkt[b + 64:b + 128]
        b += 128
    frags[frag] = pkt[b:]
    if (pkt[1] >> 7) & 1:
        if lqt is not None and 0 in frags:
            scan = b"".join(frags[k] for k in sorted(frags))
            frames.append(build_jfif(w, h, lqt, cqt, scan))
        frags, lqt, cqt = {}, None, None
sock.close()

print("frame  black_bar_Y (x=1200,y=360)   expected 0")
for i, jpg in enumerate(frames):
    try:
        a = np.asarray(Image.open(io.BytesIO(jpg)).convert("YCbCr")).astype(int)
        print("  %2d        %3d" % (i, a[360, 1200, 0]))
    except Exception as e:
        print("  %2d   decode err %s" % (i, e))
