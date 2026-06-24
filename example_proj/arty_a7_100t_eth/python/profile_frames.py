#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# profile_frames.py - split the per-frame period into "encode" vs "stream" by
# watching RTP packet arrival times. The control FSM is serial (encode a whole
# frame, THEN burst it over Ethernet), so:
#   burst width (first->last packet of a frame) ~= RTP/Ethernet transmit time
#   gap (last packet -> first packet of next frame) ~= generate+encode time
#
# Usage: python profile_frames.py [seconds]

import socket
import statistics as st
import sys
import time

SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 3.5
IP, RPORT, TPORT = "192.168.237.50", 5004, 9999

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
rx.bind(("0.0.0.0", RPORT))
rx.settimeout(2.0)
tx.sendto(b"G", (IP, TPORT))

events = []  # (t, marker, bytes)
end = time.perf_counter() + SECS + 1.0
t0 = None
try:
    while time.perf_counter() < end:
        try:
            pkt, _ = rx.recvfrom(4096)
        except socket.timeout:
            break
        if len(pkt) < 14 or (pkt[1] & 0x7F) != 26:
            continue
        t = time.perf_counter()
        if t0 is None:
            t0 = t
            end = t + SECS
        events.append((t, (pkt[1] >> 7) & 1, len(pkt)))
finally:
    tx.sendto(b"S", (IP, TPORT))

# group packets into frames on the marker bit
frames, cur = [], []
for e in events:
    cur.append(e)
    if e[1]:
        frames.append(cur)
        cur = []

bursts, gaps, npk, fbytes = [], [], [], []
for i, fr in enumerate(frames):
    if len(fr) < 2:
        continue
    bursts.append(fr[-1][0] - fr[0][0])
    npk.append(len(fr))
    fbytes.append(sum(p[2] for p in fr))
    if i + 1 < len(frames):
        gaps.append(frames[i + 1][0][0] - fr[-1][0])

if len(bursts) < 2 or not gaps:
    print("not enough frames captured")
    sys.exit(1)

burst, gap = st.mean(bursts), st.mean(gaps)
period = burst + gap
print(f"frames captured : {len(frames)}   (~{st.mean(npk):.0f} pkt/frame, "
      f"~{st.mean(fbytes)/1024:.1f} KB/frame)")
print(f"stream burst    : {burst*1e3:6.1f} ms avg   ({min(bursts)*1e3:.1f}-{max(bursts)*1e3:.1f} ms)")
print(f"encode gap      : {gap*1e3:6.1f} ms avg   ({min(gaps)*1e3:.1f}-{max(gaps)*1e3:.1f} ms)")
print(f"frame period    : {period*1e3:6.1f} ms  ->  {1/period:5.1f} fps")
print(f"split           : encode {gap/period*100:.0f}%   stream {burst/period*100:.0f}%")
