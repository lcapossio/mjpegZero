#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# gen_aan_vectors.py — stimulus + expected vectors for the AAN DCT pair
# ============================================================================
# dct_1d vectors exercise the full 12-bit port range; dct_2d vectors stay in
# the matched set's contract domain (-128..127, the encoder's level-shifted
# pixels). Expected values come from dct_aan_model.py.
# Usage: gen_aan_vectors.py <outdir>
# ============================================================================

import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from dct_aan_model import aan1d_int, dct2d_aan


def main():
    outdir = sys.argv[1]
    rng = np.random.default_rng(31)

    rows = [[2047] * 8, [-2048] * 8, [2047, -2048] * 4, [0] * 8]
    for p in range(8):
        rows.append([2047 if i == p else 0 for i in range(8)])
    for _ in range(1500):
        rows.append(list(rng.integers(-2048, 2048, 8)))
    with open(os.path.join(outdir, 'dct1d_stim.hex'), 'w') as fs, \
         open(os.path.join(outdir, 'dct1d_exp.hex'), 'w') as fe:
        for row in rows:
            exp = aan1d_int(row)
            for v in row:
                fs.write('%04x\n' % (int(v) & 0xFFFF))
            for v in exp:
                fe.write('%04x\n' % (int(v) & 0xFFFF))

    blocks = [np.full((8, 8), 127), np.full((8, 8), -128)]
    cb = np.fromfunction(lambda r, c: ((r + c) % 2) * 255 - 128, (8, 8))
    blocks.append(cb.astype(int))
    # (1,1)-aligned full-swing pattern: the tight range bound's worst case
    import math
    w11 = [[127 if math.cos((2*i+1)*math.pi/16)*math.cos((2*j+1)*math.pi/16) > 0
            else -128 for j in range(8)] for i in range(8)]
    blocks.append(np.array(w11))
    for _ in range(300):
        blocks.append(rng.integers(-128, 128, (8, 8)))
    with open(os.path.join(outdir, 'dct2d_stim.hex'), 'w') as fs, \
         open(os.path.join(outdir, 'dct2d_exp.hex'), 'w') as fe:
        for blk in blocks:
            exp = dct2d_aan([[int(v) for v in row] for row in blk], 0, 16)
            for row in blk:
                for v in row:
                    fs.write('%04x\n' % (int(v) & 0xFFFF))
            for row in exp:
                for v in row:
                    fe.write('%04x\n' % (int(v) & 0xFFFF))
    print(f'{len(rows)} rows, {len(blocks)} blocks written to {outdir}')


if __name__ == '__main__':
    sys.exit(main())
