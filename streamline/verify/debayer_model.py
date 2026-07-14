#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# debayer_model.py — bit-exact golden model for the MHC 5x5 demosaic
# ============================================================================
# Malvar-He-Cutler gradient-corrected linear demosaic (ICASSP 2004) in exact
# integer arithmetic — the contract for streamline/rtl/isp/debayer.v:
#
#   - all eight MHC kernels normalized to a common /16 scale so every
#     interpolated sample is (acc + 8) >> 4, clamped to [0, 2^DATA_W - 1]
#   - mirror-2 boundary policy: index -1 -> 1, -2 -> 2, W -> W-2, W+1 -> W-3
#   - runtime Bayer phase (py, px): the color at pixel (0,0) is
#     (0,0)=R  (0,1)=Gr  (1,0)=Gb  (1,1)=B   for phase (0,0) = RGGB
#
# Run as a script to cross-check against the independent floating-point
# reference (colour_demosaicing.demosaicing_CFA_Bayer_Malvar2004) on the
# mandrill image, per DEBAYER-PLAN.md verification step 2.
# ============================================================================

import numpy as np

# MHC kernels over 16 (paper kernels over 8, doubled; the two "half"
# coefficients become integers). Layout: 5x5, applied centered.
K_G_AT_RB = np.array([          # green at a red or blue site
    [0,  0, -2,  0,  0],
    [0,  0,  4,  0,  0],
    [-2, 4,  8,  4, -2],
    [0,  0,  4,  0,  0],
    [0,  0, -2,  0,  0]])

K_RB_ROW = np.array([           # red at green in red row / blue at green in blue row
    [0,  0,  1,  0,  0],
    [0, -2,  0, -2,  0],
    [-2, 8, 10,  8, -2],
    [0, -2,  0, -2,  0],
    [0,  0,  1,  0,  0]])

K_RB_COL = K_RB_ROW.T           # same chroma in the orthogonal orientation

K_RB_DIAG = np.array([          # red at blue site / blue at red site
    [0,  0, -3,  0,  0],
    [0,  4,  0,  4,  0],
    [-3, 0, 12,  0, -3],
    [0,  4,  0,  4,  0],
    [0,  0, -3,  0,  0]])


def mirror2(i, n):
    """Mirror-2 (reflect-without-repeat) index for a size-n axis."""
    if i < 0:
        return -i
    if i >= n:
        return 2 * n - 2 - i
    return i


def cfa_color(y, x, py, px):
    """Bayer color at (y, x) for phase (py, px): 'R', 'G', or 'B'."""
    r = (y + py) & 1
    c = (x + px) & 1
    if r == 0:
        return 'R' if c == 0 else 'G'
    return 'G' if c == 0 else 'B'


def _conv(cfa, y, x, kernel, maxv):
    h, w = cfa.shape
    acc = 0
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            k = int(kernel[dy + 2][dx + 2])
            if k:
                acc += k * int(cfa[mirror2(y + dy, h)][mirror2(x + dx, w)])
    v = (acc + 8) >> 4
    return max(0, min(maxv, v))


def demosaic_mhc(cfa, py, px, data_w=12):
    """Bit-exact MHC demosaic of a Bayer mosaic. Returns (R, G, B) planes."""
    cfa = np.asarray(cfa, dtype=np.int64)
    h, w = cfa.shape
    maxv = (1 << data_w) - 1
    R = np.zeros((h, w), dtype=np.int64)
    G = np.zeros((h, w), dtype=np.int64)
    B = np.zeros((h, w), dtype=np.int64)
    for y in range(h):
        for x in range(w):
            c = cfa_color(y, x, py, px)
            if c == 'R':
                R[y][x] = cfa[y][x]
                G[y][x] = _conv(cfa, y, x, K_G_AT_RB, maxv)
                B[y][x] = _conv(cfa, y, x, K_RB_DIAG, maxv)
            elif c == 'B':
                B[y][x] = cfa[y][x]
                G[y][x] = _conv(cfa, y, x, K_G_AT_RB, maxv)
                R[y][x] = _conv(cfa, y, x, K_RB_DIAG, maxv)
            else:
                G[y][x] = cfa[y][x]
                # In a red row, red is horizontal and blue vertical; in a
                # blue row the reverse.
                red_row = cfa_color(y, mirror2(x - 1, w), py, px) == 'R' or \
                          cfa_color(y, mirror2(x + 1, w), py, px) == 'R'
                if red_row:
                    R[y][x] = _conv(cfa, y, x, K_RB_ROW, maxv)
                    B[y][x] = _conv(cfa, y, x, K_RB_COL, maxv)
                else:
                    R[y][x] = _conv(cfa, y, x, K_RB_COL, maxv)
                    B[y][x] = _conv(cfa, y, x, K_RB_ROW, maxv)
    return R, G, B


def rgb_to_cfa(rgb, py, px):
    """Sample an RGB image into a Bayer mosaic (test stimulus only)."""
    h, w, _ = rgb.shape
    cfa = np.zeros((h, w), dtype=np.int64)
    for y in range(h):
        for x in range(w):
            c = cfa_color(y, x, py, px)
            cfa[y][x] = rgb[y][x][{'R': 0, 'G': 1, 'B': 2}[c]]
    return cfa


def main():
    import os
    from PIL import Image
    from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

    img = Image.open(os.path.join(os.path.dirname(__file__),                                   'test_images',
                                  'mandrill_720p.png')).convert('RGB')
    rgb = np.asarray(img)[100:228, 200:392].astype(np.int64)  # 128x192 crop
    h, w, _ = rgb.shape

    patterns = {(0, 0): 'RGGB', (0, 1): 'GRBG', (1, 0): 'GBRG', (1, 1): 'BGGR'}
    worst_interior = 0.0
    for (py, px), name in patterns.items():
        cfa = rgb_to_cfa(rgb, py, px)
        R, G, B = demosaic_mhc(cfa, py, px, data_w=8)
        ours = np.stack([R, G, B], axis=-1).astype(np.float64)

        ref = demosaicing_CFA_Bayer_Malvar2004(cfa.astype(np.float64) / 255.0,
                                               pattern=name) * 255.0
        ref = np.clip(ref, 0.0, 255.0)   # the hardware range; ours clamps too
        # Compare away from borders: the reference pads differently than
        # mirror-2, which is our specified (and RTL-matching) policy.
        oi = ours[4:h-4, 4:w-4]
        ri = ref[4:h-4, 4:w-4]
        max_d = float(np.max(np.abs(oi - ri)))
        worst_interior = max(worst_interior, max_d)

        mse = float(np.mean((ours[2:h-2, 2:w-2] - rgb[2:h-2, 2:w-2]) ** 2))
        psnr = 10 * np.log10(255**2 / mse)
        print(f'{name}: interior max |ours - reference| = {max_d:.3f} LSB, '
              f'PSNR vs source = {psnr:.2f} dB')

    # Integer rounding differs from the float reference by < 1 LSB; anything
    # more indicates a kernel or phase error.
    ok = worst_interior < 1.0
    print(f'CROSS-CHECK {"PASS" if ok else "FAIL"} '
          f'(worst interior delta {worst_interior:.3f}, limit 1.0)')
    return 0 if ok else 1


if __name__ == '__main__':
    import sys
    sys.exit(main())
