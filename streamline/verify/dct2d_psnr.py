#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# dct2d_psnr.py — 2-D DCT model + end-to-end quality gate
# ============================================================================
# Extends dct_model.py to the full 8x8 transform with rtl/dct_2d.v's exact
# dataflow: row pass -> saturate to 12 bits -> column pass. Runs the Phase 2
# quality gate: encode every block of the mandrill 720p image (level shift,
# 2-D DCT, quantize with the bit-exact quantizer arithmetic, dequantize,
# ideal inverse DCT), and compare decoded PSNR of the Loeffler pipeline
# against the matrix pipeline at several qualities.
#
# Gate (ENCODER-PLAN.md Phase 2): Loeffler PSNR >= matrix PSNR - 0.05 dB at every
# tested quality.
# ============================================================================

import sys
import os
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'python'))

from dct_model import dct1d_matrix, dct1d_loeffler
from jpeg_common import STD_QUANT_TABLE_LUMA, scale_quant_table


def sat12(v):
    return max(-2048, min(2047, int(v)))


def dct2d(block, dct1d):
    """rtl/dct_2d.v dataflow: rows, saturate 16->12, columns."""
    r = [dct1d(row) for row in block]                      # row pass
    out = [[0] * 8 for _ in range(8)]
    for k in range(8):                                     # column pass
        col = [sat12(r[i][k]) for i in range(8)]
        c = dct1d(col)
        for u in range(8):
            out[u][k] = c[u]
    return out


def quantize(coef, q):
    """Bit-exact streamline/rtl quantizer: sign * ((|v|*recip + 2^15) >> 16),
    recip = round(2^16/step) held to 16 bits at step 1."""
    recip = 65535 if q <= 1 else (65536 + q // 2) // q
    s = -1 if coef < 0 else 1
    return s * ((abs(int(coef)) * recip + 32768) >> 16)


def idct2d_float(F):
    """Ideal orthonormal inverse for reconstruction."""
    n = np.arange(8)
    C = np.array([[(np.sqrt(1/8) if k == 0 else 0.5)
                   * np.cos((2*i + 1) * k * np.pi / 16)
                   for i in n] for k in n])
    return C.T @ np.asarray(F, dtype=np.float64) @ C


def psnr_for(plane, dct1d, qtable):
    h, w = plane.shape
    err = 0.0
    cnt = 0
    for by in range(0, h, 8):
        for bx in range(0, w, 8):
            blk = plane[by:by+8, bx:bx+8].astype(np.int64) - 128
            F = dct2d(blk.tolist(), dct1d)
            Fq = [[quantize(F[u][v], qtable[u][v]) * qtable[u][v]
                   for v in range(8)] for u in range(8)]
            rec = np.clip(np.round(idct2d_float(Fq)) + 128, 0, 255)
            err += float(np.sum((rec - plane[by:by+8, bx:bx+8]) ** 2))
            cnt += 64
    mse = err / cnt
    return 10 * np.log10(255**2 / mse)


def main():
    img = Image.open(os.path.join(os.path.dirname(__file__),
                     'test_images',
                     'mandrill_720p.png')).convert('L')
    # Luma plane, cropped to a multiple of 8 and subsampled for runtime
    plane = np.asarray(img)[0:352, 0:448]

    worst = 0.0
    for q in (50, 75, 95, 100):
        qt = scale_quant_table(STD_QUANT_TABLE_LUMA, q)
        p_m = psnr_for(plane, dct1d_matrix, qt)
        p_l = psnr_for(plane, dct1d_loeffler, qt)
        delta = p_m - p_l
        worst = max(worst, delta)
        print(f'Q{q:3d}: matrix {p_m:.3f} dB   loeffler {p_l:.3f} dB   '
              f'delta {delta:+.4f} dB')

    ok = worst <= 0.05
    print(f'GATE {"PASS" if ok else "FAIL"}: worst delta {worst:.4f} dB '
          f'(limit 0.05)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
