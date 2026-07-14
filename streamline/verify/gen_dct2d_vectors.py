#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# gen_dct2d_vectors.py — stimulus + expected vectors for tb_dct2d.sv
# ============================================================================
# Blocks: directed extremes (flat max/min, checkerboards, single-pixel
# impulses, ramps) then uniform random. Expected outputs come from
# dct2d_psnr.py::dct2d over dct_model.py::dct1d_loeffler — the bit-exact
# contract for streamline/dct_2d.v (including the 12-bit inter-pass
# saturation).
#
# Usage: gen_dct2d_vectors.py <outdir> [n_random]
# ============================================================================

import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from dct_model import dct1d_loeffler
from dct2d_psnr import dct2d


def main():
    outdir = sys.argv[1]
    n_random = int(sys.argv[2]) if len(sys.argv) > 2 else 400

    blocks = []
    blocks.append(np.full((8, 8), 2047))
    blocks.append(np.full((8, 8), -2048))
    cb = np.fromfunction(lambda r, c: ((r + c) % 2) * 4095 - 2048, (8, 8))
    blocks.append(cb.astype(int))
    blocks.append(np.clip(-cb, -2048, 2047).astype(int))
    for p in (0, 7, 56, 63, 27):
        b = np.zeros((8, 8), dtype=int)
        b[p // 8][p % 8] = 2047
        blocks.append(b)
    blocks.append(np.tile(np.arange(-2048, -2048 + 8 * 512, 512), (8, 1)))
    blocks.append(np.zeros((8, 8), dtype=int))

    rng = np.random.default_rng(11)
    for _ in range(n_random):
        blocks.append(rng.integers(-2048, 2048, (8, 8)))

    with open(os.path.join(outdir, 'dct2d_stim.hex'), 'w') as fs, \
         open(os.path.join(outdir, 'dct2d_exp.hex'), 'w') as fe:
        for blk in blocks:
            exp = dct2d([[int(v) for v in row] for row in blk],
                        dct1d_loeffler)
            for row in blk:
                for v in row:
                    fs.write('%04x\n' % (int(v) & 0xFFFF))
            for row in exp:
                for v in row:
                    fe.write('%04x\n' % (int(v) & 0xFFFF))

    print(f'{len(blocks)} blocks written to {outdir}')


if __name__ == '__main__':
    sys.exit(main())
