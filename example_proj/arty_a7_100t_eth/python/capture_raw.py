#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Inspect raw RTP/JPEG packets off the FPGA: per-packet RTP/JPEG header fields,
# fragment-offset contiguity, and the in-band quant tables (compared to the
# encoder's known-correct tables from the sim JFIF).
import socket
import sys
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5004

# encoder's correct quant tables (from sim full JFIF DQT segments)
ref = Path("build/sim_vtpg/sim_vtpg.bin").read_bytes()
s = ref.find(b"\xff\xd8")
LQT_REF = ref[s + 25:s + 25 + 64]
CQT_REF = ref[s + 94:s + 94 + 64]

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
sock.bind(("0.0.0.0", PORT))
print("capturing one frame of RTP/JPEG packets on udp/%d ..." % PORT)

pkts = []
started = False
while True:
    pkt, _ = sock.recvfrom(2048)
    if len(pkt) < 20 or (pkt[1] & 0x7F) != 26:
        continue
    o = 12
    frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
    marker = (pkt[1] >> 7) & 1
    if not started:
        if frag != 0:
            continue   # wait for the start of a frame
        started = True
    pkts.append(pkt)
    if marker and len(pkts) > 1:
        break
sock.close()

print("captured %d packets in one frame\n" % len(pkts))
print(" idx  marker  frag_off  type   q   w   h   payload  expected_off  OK")
exp = 0
total_scan = 0
for i, pkt in enumerate(pkts):
    o = 12
    marker = (pkt[1] >> 7) & 1
    frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
    typ = pkt[o]
    q = pkt[o + 5]
    w, h = pkt[o + 6] * 8, pkt[o + 7] * 8
    body = o + 8
    qtlen = 0
    if frag == 0 and q >= 128:
        precision = pkt[body + 1]
        qtlen_field = (pkt[body + 2] << 8) | pkt[body + 3]
        qt = pkt[body + 4:body + 4 + qtlen_field]
        qtlen = 4 + qtlen_field
        lqt = qt[0:64]
        cqt = qt[64:128]
        print("   (frag0 QT: precision=%d len=%d  lqt_match=%s cqt_match=%s)"
              % (precision, qtlen_field, lqt == LQT_REF, cqt == CQT_REF))
        if lqt != LQT_REF:
            print("     lqt got :", list(lqt[:16]))
            print("     lqt ref :", list(LQT_REF[:16]))
    payload = len(pkt) - body - qtlen
    ok = (frag == exp)
    print(" %3d    %d    %7d   %3d  %3d %4d %3d  %7d   %7d     %s"
          % (i, marker, frag, typ, q, w, h, payload, exp, "OK" if ok else "*** MISMATCH"))
    exp = frag + payload
    total_scan = frag + payload
print("\ntotal scan bytes (last frag_off+payload):", total_scan)
