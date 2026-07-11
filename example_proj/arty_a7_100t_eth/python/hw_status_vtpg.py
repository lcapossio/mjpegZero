#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_status_vtpg.py - read & decode demo_top_vtpg_eth debug status over JTAG.
# FPGA must already be programmed with arty_a7_vtpg_demo.bit.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402

VSTATE = {
    0: "IDLE",
    1: "QWRITE",
    2: "QWAIT",
    3: "KICK",
    4: "KWAIT",
    5: "ENC",
    6: "STREAM",
    7: "WAIT",
}

def main():
    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        hw._connect()
        st  = hw._axi.axi_read(0x02000000)
        sz  = hw._axi.axi_read(0x02000004) & 0x7FFFF
        fc  = hw._axi.axi_read(0x02000008)
        dip = hw._axi.axi_read(0x0200000C)
        dml = hw._axi.axi_read(0x02000010)
        dmh = hw._axi.axi_read(0x02000014) & 0xFFFF
        dpt = hw._axi.axi_read(0x02000018) & 0xFFFF
        nfr = hw._axi.axi_read(0x0200001C) & 0xFFFF
        pk  = hw._axi.axi_read(0x02000020)
    finally:
        hw.close()
    print("raw status   = 0x%08x" % st)
    print("  vstate      = %s" % VSTATE.get(st & 0xF, st & 0xF))
    print("  cap_done    = %d" % ((st >> 4) & 1))
    print("  loop_en     = %d" % ((st >> 5) & 1))
    print("  overflow    = %d" % ((st >> 6) & 1))
    print("  dbg_udp     = %d  (net_rx saw a UDP packet)" % ((st >> 7) & 1))
    print("  dbg_trg     = %d  (trigger fired)" % ((st >> 8) & 1))
    print("  dbg_mactx   = %d  (MAC TX active)" % ((st >> 9) & 1))
    print("  dbg_arp     = %d  (ARP reply sent)" % ((st >> 10) & 1))
    print("  dbg_macbp   = %d  (MAC TX backpressure seen)" % ((st >> 11) & 1))
    print("  rtp_busy    = %d  (jpeg_rtp_tx streaming)" % ((st >> 12) & 1))
    print("  rc_dropped  = %d" % ((st >> 13) & 0xFF))
    print("  rc_quality  = %d" % ((st >> 21) & 0x7F))
    print("cur frame size = %d bytes" % sz)
    print("frames streamed= %d" % fc)
    print("rtp_tx packets = %d  (jpeg_rtp_tx produced)" % ((pk >> 16) & 0xFFFF))
    print("frame-buf pkts = %d  (frame buffer emitted)" % (pk & 0xFFFF))
    print("MAC frames sent= %d  (arbiter -> MAC)" % nfr)
    print("captured dst   = %012x  %d.%d.%d.%d : %d"
          % ((dmh << 32) | dml,
             (dip >> 24) & 255, (dip >> 16) & 255, (dip >> 8) & 255, dip & 255, dpt))

if __name__ == "__main__":
    main()
