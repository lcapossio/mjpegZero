#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_probe_dct.py - read DCT-output and quantizer-output DC extremes (most
# negative = black block, most positive = white block) captured on silicon via
# JTAG words 13/14. Tells us whether the color-wash is in the DCT (negative DC
# lost there) or downstream in the quantizer. FPGA must be streaming.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402


def s16(v):
    return v - 65536 if v >= 32768 else v


def main():
    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        hw._connect()
        w13 = hw._axi.axi_read(0x02000034)
        w14 = hw._axi.axi_read(0x02000038)
        w15 = hw._axi.axi_read(0x0200003C)
    finally:
        hw.close()
    dct_min, dct_max = s16(w13 & 0xFFFF), s16(w13 >> 16)
    q_min, q_max = s16(w14 & 0xFFFF), s16(w14 >> 16)
    ql_min, ql_max = s16(w15 & 0xFFFF), s16(w15 >> 16)
    print("raw: w13=%08x w14=%08x w15=%08x" % (w13, w14, w15))
    print("LUMA-only quant DC: min(black)=%6d  max(white)=%6d   (correct: min~-128 max~+127)"
          % (ql_min, ql_max))
    print("  => %s" % ("LUMA min washed -> encoder washes black luma on silicon"
                       if abs(ql_min) < 0.7 * abs(ql_max) or ql_min > -90 else
                       "LUMA min ~ -128 -> encoder luma CORRECT on silicon; wash is downstream"))
    print("\nDCT DC   : min(black)=%6d  max(white)=%6d   |min|/max=%.3f"
          % (dct_min, dct_max, abs(dct_min) / max(1, dct_max)))
    print("quant DC : min(black)=%6d  max(white)=%6d   |min|/max=%.3f"
          % (q_min, q_max, abs(q_min) / max(1, q_max)))
    print("  (correct ~ symmetric: DCT min~-1024 max~+1016; quant min~-64 max~+63)")

    dct_sym = abs(dct_min) > 0.7 * abs(dct_max) and dct_max > 100
    q_sym = abs(q_min) > 0.7 * abs(q_max) and q_max > 5
    print()
    if not dct_sym:
        print("=> DCT DC for black is LOST/small while white is fine -> bug is in the DCT (#1: signed multiply).")
    elif not q_sym:
        print("=> DCT is symmetric (black DC correct) but QUANTIZER output is asymmetric -> bug is in the quantizer (#2: sign/abs).")
    else:
        print("=> Both DCT and quantizer DC are symmetric -> bug is DOWNSTREAM (zigzag/Huffman DC coding).")


if __name__ == "__main__":
    main()
