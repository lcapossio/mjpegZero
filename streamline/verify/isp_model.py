#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# isp_model.py — bit-exact golden models for the ISP arithmetic stages
# ============================================================================
# Contracts for streamline/camera/rtl/isp/{blc,wb_gains,ccm}.v. All operate on DATA_W
# unsigned samples (default 12-bit). Bayer channel order for per-channel
# parameters is [R, Gr, Gb, B], selected by pixel parity relative to the
# frame's Bayer phase {py, px} exactly as in debayer_model.cfa_color.
# ============================================================================


def bayer_chan(y, x, py, px):
    """0=R 1=Gr 2=Gb 3=B at (y, x) for phase (py, px)."""
    return ((y + py) & 1) * 2 + ((x + px) & 1)


def blc_px(v, black):
    """Black-level correction: subtract, floor at zero."""
    return max(0, int(v) - int(black))


def wb_px(v, gain, data_w=12):
    """White-balance gain in U4.8: (v * gain + 128) >> 8, saturating."""
    maxv = (1 << data_w) - 1
    return min(maxv, (int(v) * int(gain) + 128) >> 8)


def ccm_px(rgb, m, data_w=12):
    """3x3 color-correction matrix, coefficients S4.8 (signed Q8):
    out_i = clamp((sum_j m[i][j] * in_j + 128) >> 8)."""
    maxv = (1 << data_w) - 1
    out = []
    for i in range(3):
        acc = sum(int(m[i][j]) * int(rgb[j]) for j in range(3)) + 128
        out.append(max(0, min(maxv, acc >> 8)))
    return out


def blc_frame(cfa, py, px, blacks):
    return [[blc_px(cfa[y][x], blacks[bayer_chan(y, x, py, px)])
             for x in range(len(cfa[0]))] for y in range(len(cfa))]


def wb_frame(cfa, py, px, gains, data_w=12):
    return [[wb_px(cfa[y][x], gains[bayer_chan(y, x, py, px)], data_w)
             for x in range(len(cfa[0]))] for y in range(len(cfa))]
