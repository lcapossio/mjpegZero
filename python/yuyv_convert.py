# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Shared YUYV conversion: PNG/RGB -> binary YUYV + hex for sim.

Both RTL simulation and hardware tests import this module to guarantee
bit-exact identical input data.
"""

import os
import sys
import struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_encoder import rgb_to_ycbcr, subsample_422


def rgb_array_to_yuyv_words(img_rgb):
    """Convert RGB uint8 array (H,W,3) to list of 16-bit YUYV words.

    Uses the same BT.601 conversion and chroma averaging as jpeg_encoder.py.
    Word format: [15:8]=Cb/Cr, [7:0]=Y
      Even pixel: {Cb, Y}
      Odd pixel:  {Cr, Y}

    Returns: (words, height, width)
        words: list of int, each 0..65535
    """
    ycbcr = rgb_to_ycbcr(img_rgb)
    Y, Cb, Cr = subsample_422(ycbcr)
    h, w = Y.shape

    words = []
    for row in range(h):
        for col in range(w):
            y_val = int(np.clip(np.round(Y[row, col]), 0, 255))
            chroma_col = col // 2
            if col % 2 == 0:
                cb_val = int(np.clip(np.round(Cb[row, chroma_col]), 0, 255))
                word = (cb_val << 8) | y_val
            else:
                cr_val = int(np.clip(np.round(Cr[row, chroma_col]), 0, 255))
                word = (cr_val << 8) | y_val
            words.append(word)
    return words, h, w


def write_yuyv_binary(words, out_path):
    """Write YUYV words as little-endian 16-bit binary file.

    This is the .yuyv format consumed by example_proj/common/python/demo.py.
    Each 16-bit word is stored as 2 bytes: byte0=Y ([7:0]), byte1=C ([15:8]).
    """
    data = bytearray(len(words) * 2)
    for i, w in enumerate(words):
        struct.pack_into('<H', data, i * 2, w)
    with open(out_path, 'wb') as f:
        f.write(data)
    return len(data)


def write_yuyv_hex(words, out_path):
    """Write YUYV words as 16-bit hex file for $readmemh."""
    with open(out_path, 'w') as f:
        for w in words:
            f.write(f"{w & 0xFFFF:04X}\n")


def png_to_yuyv(png_path, bin_path=None, hex_path=None):
    """Convert PNG image to YUYV, writing binary and/or hex output.

    Returns: (words, height, width)
    """
    from PIL import Image
    img_rgb = np.array(Image.open(png_path).convert('RGB'))
    words, h, w = rgb_array_to_yuyv_words(img_rgb)

    if bin_path:
        nbytes = write_yuyv_binary(words, bin_path)
        print(f"  Wrote {bin_path} ({nbytes} bytes, {w}x{h})")
    if hex_path:
        write_yuyv_hex(words, hex_path)
        print(f"  Wrote {hex_path} ({len(words)} words, {w}x{h})")

    return words, h, w
