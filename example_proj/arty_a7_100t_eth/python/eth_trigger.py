#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# eth_trigger.py - tell the FPGA where to stream the RTP/JPEG frame.
#
# Sends a small UDP packet to the FPGA's trigger port. The FPGA captures this
# packet's source MAC/IP (via net_rx) and streams the JPEG currently in its
# buffer back as RTP/JPEG to <this host>:<RTP_PORT>. Run your player first
# (e.g. ffplay stream.sdp listening on 5004), then run this.
#
# Usage: python eth_trigger.py [fpga_ip] [trigger_port]
#   defaults: 192.168.237.50  9999

import socket
import sys

fpga_ip      = sys.argv[1] if len(sys.argv) > 1 else "192.168.237.50"
trigger_port = int(sys.argv[2]) if len(sys.argv) > 2 else 9999

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# at least one payload byte is required (net_rx asserts udp_valid on payload only)
s.sendto(b"GO", (fpga_ip, trigger_port))
s.close()
print("sent trigger to %s:%d" % (fpga_ip, trigger_port))
