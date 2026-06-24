#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# stream_view.py - live viewer for the FPGA RTP/JPEG stream with an on-video HUD
# that shows the compressed BITRATE (plus resolution, fps, frame size), so the
# operator can see the bitrate live while watching. ffplay can't compute the
# compressed bitrate, hence this small decoder/overlay.
#
#   python stream_view.py            # GUI window: video + bitrate HUD
#   python stream_view.py --console  # headless: prints a live bitrate line
#
# Sends 'start' on launch and 'stop' on exit (over the trigger port).

import io
import socket
import sys
import threading
import time
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtp_jpeg_recv import build_jfif  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

IP = "192.168.237.50"
RPORT = 5004
TPORT = 9999
CONSOLE = "--console" in sys.argv
DURATION = next((float(a) for a in sys.argv[1:] if a.replace(".", "", 1).isdigit()), None)

_state = {"img": None, "mbps": 0.0, "total": 0.0, "fps": 0.0, "kb": 0.0, "res": "----"}
_lock = threading.Lock()
_run = True


def _rx_loop():
    win = deque()   # (t, full_jpeg_bytes) per frame, ~1 s window
    wire = deque()  # (t, on-wire bytes) per packet, ~1 s window
    ETH_OVH = 42    # Eth(14)+IP(20)+UDP(8) header bytes per packet
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.sendto(b"G", (IP, TPORT))  # start streaming
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    rx.bind(("0.0.0.0", RPORT))
    rx.settimeout(1.0)
    frags, lqt, cqt, w, h = {}, None, None, 0, 0
    while _run:
        try:
            pkt, _ = rx.recvfrom(4096)
        except socket.timeout:
            continue
        if len(pkt) < 14 or (pkt[1] & 0x7F) != 26:
            continue
        now = time.time()
        wire.append((now, len(pkt) + ETH_OVH))
        while wire and now - wire[0][0] > 1.0:
            wire.popleft()
        o = 12
        frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
        q = pkt[o + 5]
        w, h = pkt[o + 6] * 8, pkt[o + 7] * 8
        b = o + 8
        if frag == 0 and q >= 128:
            lqt, cqt = pkt[b + 4:b + 68], pkt[b + 68:b + 132]
            b += 4 + 128
        frags[frag] = pkt[b:]
        if (pkt[1] >> 7) & 1:  # marker = end of frame
            if lqt is not None and 0 in frags:
                scan = b"".join(frags[k] for k in sorted(frags))
                full = build_jfif(w, h, lqt, cqt, scan)
                win.append((now, len(full)))
                while win and now - win[0][0] > 1.0:
                    win.popleft()
                span = max(now - win[0][0], 1e-3) if len(win) > 1 else 1.0
                mbps = sum(n for _, n in win) * 8 / span / 1e6
                fps = (len(win) - 1) / span if len(win) > 1 else 0.0
                wspan = max(now - wire[0][0], 1e-3) if len(wire) > 1 else 1.0
                total = sum(n for _, n in wire) * 8 / wspan / 1e6
                img = None
                if not CONSOLE:
                    try:
                        img = Image.open(io.BytesIO(full)).convert("RGB")
                    except Exception:
                        img = None
                with _lock:
                    _state.update(mbps=mbps, total=total, fps=fps,
                                  kb=len(full) / 1024.0, res=f"{w}x{h}")
                    if img is not None:
                        _state["img"] = img
            frags, lqt, cqt = {}, None, None
    socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"S", (IP, TPORT))


def _hud_text():
    with _lock:
        return (f"{_state['res']}   JPEG {_state['mbps']:.2f} Mbps   "
                f"total {_state['total']:.2f} Mbps   "
                f"{_state['fps']:.0f} fps   {_state['kb']:.1f} KB")


def main():
    global _run
    th = threading.Thread(target=_rx_loop, daemon=True)
    th.start()

    if CONSOLE:
        start = time.time()
        try:
            while DURATION is None or time.time() - start < DURATION:
                time.sleep(1.0)
                print("\r  " + _hud_text() + "        ", end="", flush=True)
        except KeyboardInterrupt:
            pass
        finally:
            _run = False
            th.join(timeout=2.0)
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"S", (IP, TPORT))
            print()
        return

    import tkinter as tk
    from PIL import ImageTk
    try:
        font = ImageFont.truetype("consola.ttf", 24)
    except Exception:
        try:
            font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 24)
        except Exception:
            font = ImageFont.load_default()

    root = tk.Tk()
    root.title("vtpgZero live - bitrate HUD")
    label = tk.Label(root)
    label.pack()

    def update():
        with _lock:
            img = _state["img"]
        if img is not None:
            d = img.copy()
            dr = ImageDraw.Draw(d)
            txt = _hud_text()
            try:
                box_w = dr.textbbox((10, 7), txt, font=font)[2] + 10
            except Exception:
                box_w = 820
            dr.rectangle([0, 0, box_w, 38], fill=(0, 0, 0))
            dr.text((10, 7), txt, fill=(255, 255, 0), font=font)
            ph = ImageTk.PhotoImage(d)
            label.configure(image=ph)
            label.image = ph
        root.after(40, update)

    def on_close():
        global _run
        _run = False
        root.after(200, root.destroy)

    root.protocol("WM_DELETE_WINDOW", on_close)
    update()
    root.mainloop()


if __name__ == "__main__":
    main()
