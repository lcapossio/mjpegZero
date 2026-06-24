#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# eth_control.py - control the FPGA RTP/JPEG stream via a one-byte opcode in the
# UDP trigger packet (port 9999). The opcode is the FIRST payload byte; the same
# packet also (re)latches this host as the RTP destination, so you no longer need
# to spam triggers to keep the stream alive.
#
#   start   ('G') -> stream continuously (default; "GO" from eth_trigger.py also works)
#   stop    ('S') -> stop after the current frame finishes
#   single  ('1') -> stream exactly one frame
#
# Usage: python eth_control.py [start|stop|single] [fpga_ip] [trigger_port]
#   defaults: start  192.168.237.50  9999

import socket
import sys

OPCODES = {"start": b"G", "stop": b"S", "single": b"1"}

cmd  = sys.argv[1] if len(sys.argv) > 1 else "start"
ip   = sys.argv[2] if len(sys.argv) > 2 else "192.168.237.50"
port = int(sys.argv[3]) if len(sys.argv) > 3 else 9999

if cmd not in OPCODES:
    print("usage: eth_control.py [start|stop|single] [fpga_ip] [trigger_port]")
    sys.exit(1)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(OPCODES[cmd], (ip, port))
s.close()
print("sent %-6s opcode %r to %s:%d" % (cmd, OPCODES[cmd], ip, port))
