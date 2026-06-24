#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# measure_bitrate.py - measure the bitrate of the compressed JPEG stream coming
# out of the FPGA (RTP/JPEG over UDP). Starts the stream, samples for a window,
# stops, and reports frames/s, average JPEG size, the compressed encoder bitrate,
# and the on-wire (Ethernet) bitrate.
#
# Usage: python measure_bitrate.py [seconds] [fpga_ip] [rtp_port] [trigger_port]
#   defaults: 5  192.168.237.50  5004  9999

import socket
import sys
import time

WINDOW = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
IP = sys.argv[2] if len(sys.argv) > 2 else "192.168.237.50"
RPORT = int(sys.argv[3]) if len(sys.argv) > 3 else 5004
TPORT = int(sys.argv[4]) if len(sys.argv) > 4 else 9999

JFIF_HDR = 623   # fixed JFIF header the FPGA does NOT send (host reconstructs it)
EOI = 2          # FPGA scan excludes the 2-byte EOI
ETH_OVH = 42     # Ethernet(14) + IP(20) + UDP(8) per packet (FCS/preamble extra)

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
rx.bind(("0.0.0.0", RPORT))

tx.sendto(b"G", (IP, TPORT))            # start streaming
rx.settimeout(3.0)

t0 = None
deadline = time.time() + 10.0           # give the stream time to come up
wire = pkts = frames = jpeg = scan = 0
try:
    while time.time() < deadline:
        try:
            pkt, _ = rx.recvfrom(4096)
        except socket.timeout:
            break
        if len(pkt) < 14 or (pkt[1] & 0x7F) != 26:    # RTP payload type 26 = JPEG
            continue
        if t0 is None:                  # start the window on the first JPEG packet
            t0 = time.time()
            deadline = t0 + WINDOW
        wire += len(pkt)
        pkts += 1
        o = 12
        frag = (pkt[o + 1] << 16) | (pkt[o + 2] << 8) | pkt[o + 3]
        q = pkt[o + 5]
        b = o + 8
        if frag == 0 and q >= 128:      # main JPEG header has the in-band quant tables
            b += 4 + 128
        scan += len(pkt) - b
        if (pkt[1] >> 7) & 1:           # RTP marker bit = last packet of a frame
            frames += 1
            jpeg += JFIF_HDR + scan + EOI
            scan = 0
finally:
    tx.sendto(b"S", (IP, TPORT))        # stop streaming

el = (time.time() - t0) if t0 else 0.0
if frames == 0 or el <= 0:
    print("No frames received - is the board programmed/streaming and the NIC at 192.168.237.1?")
    sys.exit(1)

fps = frames / el
avg_kb = jpeg / frames / 1024.0
comp_mbps = jpeg * 8 / el / 1e6
wire_mbps = (wire + ETH_OVH * pkts) * 8 / el / 1e6

print(f"window           : {el:.2f} s   ({frames} frames, {pkts} packets)")
print(f"frame rate       : {fps:.1f} fps")
print(f"avg JPEG frame   : {avg_kb:.1f} KB  ({jpeg // frames} bytes)")
print(f"compressed stream: {comp_mbps:.2f} Mbps   (encoder JPEG output)")
print(f"on-wire          : {wire_mbps:.2f} Mbps   (RTP/UDP/IP/Eth, ~{pkts/el:.0f} pkt/s)")
