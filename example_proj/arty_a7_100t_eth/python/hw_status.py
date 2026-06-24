#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_status.py - read & decode DEMO_STATUS over JTAG, including the Ethernet
# island debug sticky flags ([10:5]). FPGA must already be programmed.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402

BITS = ["enc_done", "jpeg_overflow", "axi_error", "enc_running", "start_armed",
        "dbg_udp", "dbg_trg", "dbg_rtprun", "dbg_rtpdone", "dbg_mactx", "dbg_arp",
        "dbg_macbp"]

def main():
    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        hw._connect()
        st  = hw._axi.axi_read(0x02000000)
        sz  = hw._axi.axi_read(0x02000004) & 0x7FFFF
        dip = hw._axi.axi_read(0x0200000C)
        dml = hw._axi.axi_read(0x02000010)
        dmh = hw._axi.axi_read(0x02000014) & 0xFFFF
        dpt = hw._axi.axi_read(0x02000018) & 0xFFFF
        nfr = hw._axi.axi_read(0x0200001C) & 0xFFFF
    finally:
        hw.close()
    print("raw DEMO_STATUS = 0x%08x" % st)
    for i, n in enumerate(BITS):
        print("  bit%-2d %-12s = %d" % (i, n, (st >> i) & 1))
    print("jpeg_byte_cnt = %d" % sz)
    mac = (dmh << 32) | dml
    print("captured dst MAC  = %012x" % mac)
    print("captured dst IP   = %d.%d.%d.%d"
          % ((dip >> 24) & 255, (dip >> 16) & 255, (dip >> 8) & 255, dip & 255))
    print("captured dst port = %d" % dpt)
    print("MAC frames sent   = %d" % nfr)

if __name__ == "__main__":
    main()
