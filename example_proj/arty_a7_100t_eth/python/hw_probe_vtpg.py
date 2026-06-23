#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_probe_vtpg.py - read the raw VTPG {C,Y} output captured at the 8 colorbar
# centers (line 0) via JTAG words 9..12, and compare to the known palette.
# Tells us whether vtpgZero emits compressed values on silicon (output bug) or
# the encoder samples correct values (downstream). FPGA must be streaming.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402

# expected {C, Y} at each bar center (C = Cb on even x), from the YUV palette
EXP = {
    0: ("white",   0x80, 0xFF), 1: ("yellow",  0x00, 0xE2),
    2: ("cyan",    0xAB, 0xB3), 3: ("green",   0x2B, 0x96),
    4: ("magenta", 0xD4, 0x69), 5: ("red",     0x54, 0x4C),
    6: ("blue",    0xFF, 0x1D), 7: ("black",   0x80, 0x00),
}


def main():
    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        hw._connect()
        w = [hw._axi.axi_read(0x02000024 + 4 * i) for i in range(4)]
    finally:
        hw.close()
    cy = [w[0] & 0xFFFF, w[0] >> 16, w[1] & 0xFFFF, w[1] >> 16,
          w[2] & 0xFFFF, w[2] >> 16, w[3] & 0xFFFF, w[3] >> 16]
    print("raw words:", " ".join("%08x" % x for x in w))
    print("\nbar  name      got C,Y     exp C,Y     verdict")
    nbad = 0
    for i in range(8):
        C = (cy[i] >> 8) & 0xFF
        Y = cy[i] & 0xFF
        nm, eC, eY = EXP[i]
        ok = (C == eC and Y == eY)
        nbad += 0 if ok else 1
        print("%d   %-8s  C=%02x Y=%02x   C=%02x Y=%02x   %s"
              % (i, nm, C, Y, eC, eY, "OK" if ok else "*** MISMATCH"))
    print("\n=> %s" % ("VTPG emits CORRECT pixels on silicon -> wash is DOWNSTREAM (encoder sampling)"
                       if nbad == 0 else
                       "VTPG emits WRONG pixels on silicon -> wash is in vtpgZero output (%d/8 bars off)" % nbad))


if __name__ == "__main__":
    main()
