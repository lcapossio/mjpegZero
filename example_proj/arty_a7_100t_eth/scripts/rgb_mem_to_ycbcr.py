#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# Convert a 6-hex RGB888 image .mem (vtpgZero image format, R in the MSBs) to
# studio-range BT.601 {Y,Cb,Cr} (Y in the MSBs). vtpgz_core OUTPUT_MODE=2 (YUV)
# reads the image/box-image triple directly as {Y,Cb,Cr} with no colour-space
# conversion, so the source .mem must already be YCbCr for the eth demo.
#
#   python rgb_mem_to_ycbcr.py <in_rgb.mem> <out_ycbcr.mem>

import sys
from pathlib import Path


def rgb_to_ycbcr(r, g, b):
    y = 16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255.0
    cb = 128 + (-37.797 * r - 74.203 * g + 112.000 * b) / 255.0
    cr = 128 + (112.000 * r - 93.786 * g - 18.214 * b) / 255.0
    cl = lambda v: max(0, min(255, int(round(v))))
    return cl(y), cl(cb), cl(cr)


def main(src, dst):
    out = []
    for tok in Path(src).read_text().split():
        v = int(tok, 16)
        y, cb, cr = rgb_to_ycbcr((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        out.append(f"{y:02x}{cb:02x}{cr:02x}")
    Path(dst).write_text("\n".join(out) + "\n")
    print(f"{src} -> {dst}  ({len(out)} px)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
