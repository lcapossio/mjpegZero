#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# eth_trigger_loop.py - keep the FPGA streaming by sending UDP triggers
# continuously (one frame per trigger that lands while the packetizer is idle).
#
# Usage: python eth_trigger_loop.py [fpga_ip] [trigger_port] [seconds]
#   defaults: 192.168.237.50  9999  120

import socket
import sys
import time

ip   = sys.argv[1] if len(sys.argv) > 1 else "192.168.237.50"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9999
dur  = float(sys.argv[3]) if len(sys.argv) > 3 else 120.0

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((ip, port))
end = time.time() + dur
n = 0
while time.time() < end:
    s.send(b"GO")
    n += 1
    time.sleep(0.001)   # ~ a few hundred/s: plenty to keep it fed, not a flood
print("sent %d triggers over %.0fs" % (n, dur))
