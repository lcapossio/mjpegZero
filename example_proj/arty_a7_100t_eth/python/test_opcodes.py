#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# test_opcodes.py - verify the trigger-opcode stream control end-to-end:
#   start  -> continuous frames flow
#   stop   -> frames stop (at most one trailing in-flight frame)
#   single -> exactly one frame
#
# Counts RTP frames by the marker bit (set on the last packet of each frame).
# Usage: python test_opcodes.py [fpga_ip] [trigger_port] [rtp_port]

import socket
import sys
import time

ip   = sys.argv[1] if len(sys.argv) > 1 else "192.168.237.50"
tport = int(sys.argv[2]) if len(sys.argv) > 2 else 9999
rport = int(sys.argv[3]) if len(sys.argv) > 3 else 5004

rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
rx.bind(("0.0.0.0", rport))
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def send(opcode):
    tx.sendto(opcode, (ip, tport))


def count_frames(window_s):
    """Count RTP frames (marker-bit packets) arriving over window_s seconds."""
    rx.settimeout(0.3)
    end = time.time() + window_s
    frames = 0
    while time.time() < end:
        try:
            pkt, _ = rx.recvfrom(2048)
        except socket.timeout:
            continue
        if len(pkt) >= 2 and (pkt[1] & 0x7F) == 26 and (pkt[1] >> 7) & 1:
            frames += 1
    return frames


def drain(window_s):
    rx.settimeout(0.2)
    end = time.time() + window_s
    while time.time() < end:
        try:
            rx.recvfrom(2048)
        except socket.timeout:
            pass


print("== opcode stream-control test (fpga %s) ==" % ip)

# make sure we start from a known (stopped) state
send(b"S"); time.sleep(0.5); drain(0.8)

# 1) START -> continuous
send(b"G")
n = count_frames(2.0)
print("  start  -> %3d frames in 2.0s  %s" % (n, "PASS" if n >= 20 else "FAIL (expected many)"))

# 2) STOP -> frames cease (allow <=1 trailing in-flight frame, then expect 0)
send(b"S")
drain(1.0)                      # let the in-flight frame finish
n = count_frames(2.0)
print("  stop   -> %3d frames in 2.0s  %s" % (n, "PASS" if n == 0 else "FAIL (still streaming)"))

# 3) SINGLE -> exactly one frame
send(b"1")
n = count_frames(2.0)
print("  single -> %3d frames in 2.0s  %s" % (n, "PASS" if n == 1 else "FAIL (expected exactly 1)"))

# leave it stopped
send(b"S")
rx.close(); tx.close()
