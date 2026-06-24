#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# rtp_jpeg_view.py - live viewer for the FPGA's RTP/JPEG (RFC 2435) stream.
# Reassembles each frame by marker bit (immune to the constant-RTP-timestamp
# issue), decodes only the latest frame per GUI tick, and updates ONE persistent
# PhotoImage in place via .paste() (robust live-image pattern). Shows live
# counters and writes them to build/viewer_stats.txt.
#
# Usage: python rtp_jpeg_view.py [port]   (default 5004)

import io
import socket
import sys
import tkinter as tk
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtp_jpeg_recv import build_jfif   # noqa: E402
from PIL import Image, ImageTk          # noqa: E402

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5004
DISPW, DISPH = 960, 540                 # fixed display size (16:9), 1280x720 scaled
STATS = str(Path(__file__).resolve().parents[1] / "build" / "viewer_stats.txt")

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
sock.bind(("0.0.0.0", PORT))
sock.setblocking(False)

root = tk.Tk()
root.title("mjpegZero - RTP/JPEG over Ethernet (live)")
root.geometry("%dx%d+80+80" % (DISPW, DISPH + 28))
root.lift()
root.attributes("-topmost", True)
root.after(4000, lambda: root.attributes("-topmost", False))

# ONE persistent PhotoImage, set on the label once; updated in place via paste()
PHOTO = ImageTk.PhotoImage(Image.new("RGB", (DISPW, DISPH), "#303030"))
img_label = tk.Label(root, image=PHOTO)
img_label.pack()
status = tk.Label(root, text="listening on udp/%d ..." % PORT,
                  font=("Consolas", 11), anchor="w")
status.pack(fill="x")

S = {"frags": {}, "lqt": None, "cqt": None, "w": 0, "h": 0,
     "pkts": 0, "asm": 0, "shown": 0, "errs": 0, "last": "", "pending": None, "tick": 0}


def handle(pkt):
    if len(pkt) < 20 or (pkt[1] & 0x7F) != 26:
        return
    marker = (pkt[1] >> 7) & 1
    o = 12
    frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
    q = pkt[o + 5]
    wd, hd = pkt[o + 6] * 8, pkt[o + 7] * 8
    o += 8
    if frag == 0 and q >= 128:
        o += 4
        S["lqt"] = pkt[o:o + 64]
        S["cqt"] = pkt[o + 64:o + 128]
        o += 128
    S["frags"][frag] = pkt[o:]
    if marker:
        if S["lqt"] is not None and 0 in S["frags"]:
            scan = b"".join(S["frags"][k] for k in sorted(S["frags"]))
            S["pending"] = (build_jfif(wd, hd, S["lqt"], S["cqt"], scan), wd, hd)
            S["asm"] += 1
        S["frags"], S["lqt"], S["cqt"] = {}, None, None


def poll():
    S["tick"] += 1
    for _ in range(8000):
        try:
            pkt, _ = sock.recvfrom(2048)
        except BlockingIOError:
            break
        S["pkts"] += 1
        try:
            handle(pkt)
        except Exception as e:
            S["errs"] += 1
            S["last"] = "asm:%s" % e
            S["frags"], S["lqt"], S["cqt"] = {}, None, None
    if S["pending"] is not None:
        jpg, wd, hd = S["pending"]
        S["pending"] = None
        try:
            img = Image.open(io.BytesIO(jpg)).convert("RGB")
            img.load()
            PHOTO.paste(img.resize((DISPW, DISPH)))   # update displayed image in place
            S["shown"] += 1
            S["w"], S["h"] = img.width, img.height
        except Exception as e:
            S["errs"] += 1
            S["last"] = "dec:%s" % e
    line = ("pkts %d  asm %d  shown %d  errs %d  %dx%d  %s"
            % (S["pkts"], S["asm"], S["shown"], S["errs"], S["w"], S["h"], S["last"]))
    status.config(text=line)
    if S["tick"] % 20 == 0:
        try:
            open(STATS, "w").write(line + "\n")
        except Exception:
            pass
    root.after(20, poll)


root.protocol("WM_DELETE_WINDOW", root.destroy)
root.after(20, poll)
root.mainloop()
