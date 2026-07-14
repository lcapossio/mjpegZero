#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# gen_dct1d_vectors.py — stimulus + expected vectors for tb_dct1d.sv
# ============================================================================
# Rows: directed extremes (all +2047, all -2048, alternating extremes,
# impulses at each position, ramps) followed by uniform random rows.
# Expected outputs come from dct_model.py::dct1d_loeffler — the bit-exact
# contract for streamline/dct_1d.v.
#
# Usage: gen_dct1d_vectors.py <outdir> [n_random]
# ============================================================================

import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from dct_model import dct1d_loeffler


def main():
    outdir = sys.argv[1]
    n_random = int(sys.argv[2]) if len(sys.argv) > 2 else 2000

    rows = []
    rows.append([2047] * 8)
    rows.append([-2048] * 8)
    rows.append([2047, -2048] * 4)
    rows.append([-2048, 2047] * 4)
    for p in range(8):
        rows.append([2047 if i == p else 0 for i in range(8)])
        rows.append([-2048 if i == p else 0 for i in range(8)])
    rows.append(list(range(-2048, -2048 + 8 * 512, 512)))
    rows.append([0] * 8)

    rng = np.random.default_rng(7)
    for _ in range(n_random):
        rows.append(list(rng.integers(-2048, 2048, 8)))

    with open(os.path.join(outdir, 'dct1d_stim.hex'), 'w') as fs, \
         open(os.path.join(outdir, 'dct1d_exp.hex'), 'w') as fe:
        for row in rows:
            exp = dct1d_loeffler(row)
            for v in row:
                fs.write('%04x\n' % (int(v) & 0xFFFF))
            for v in exp:
                fe.write('%04x\n' % (int(v) & 0xFFFF))

    print(f'{len(rows)} rows written to {outdir}')


if __name__ == '__main__':
    sys.exit(main())
