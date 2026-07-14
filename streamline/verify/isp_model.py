#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# isp_model.py — bit-exact golden models for the ISP arithmetic stages
# ============================================================================
# Contracts for streamline/rtl/isp/{blc,wb_gains,ccm}.v. All operate on DATA_W
# unsigned samples (default 12-bit). Bayer channel order for per-channel
# parameters is [R, Gr, Gb, B], selected by pixel parity relative to the
# frame's Bayer phase {py, px} exactly as in debayer_model.cfa_color.
# ============================================================================


def bayer_chan(y, x, py, px):
    """0=R 1=Gr 2=Gb 3=B at (y, x) for phase (py, px)."""
    return ((y + py) & 1) * 2 + ((x + px) & 1)


def blc_px(v, black, ped=0, data_w=12):
    """Black-level correction with shadow footroom: subtract the black
    level, add the pedestal, clamp. Values are then carried in the
    pedestal-offset domain until the CCM removes it, so noise below black
    survives spatial averaging instead of being rectified upward."""
    maxv = (1 << data_w) - 1
    return max(0, min(maxv, int(v) - int(black) + int(ped)))


def wb_px(v, gain, ped=0, data_w=12):
    """White-balance gain in U4.8 around the pedestal: the gain applies to
    the true value (v - ped), signed, and the pedestal is restored:
    out = clamp(((v - ped) * gain + 128) >> 8 + ped). Arithmetic shift
    (floor) on the signed product, as in hardware."""
    maxv = (1 << data_w) - 1
    r = ((int(v) - int(ped)) * int(gain) + 128) >> 8
    return max(0, min(maxv, r + int(ped)))


def ccm_px(rgb, m, ped=0, data_w=12):
    """3x3 color-correction matrix, coefficients S4.8. The pedestal is
    removed here — the last linear stage, after all spatial averaging:
    out_i = clamp((sum_j m[i][j] * (in_j - ped) + 128) >> 8)."""
    maxv = (1 << data_w) - 1
    out = []
    for i in range(3):
        acc = sum(int(m[i][j]) * (int(rgb[j]) - int(ped))
                  for j in range(3)) + 128
        out.append(max(0, min(maxv, acc >> 8)))
    return out


def blc_frame(cfa, py, px, blacks, ped=0):
    return [[blc_px(cfa[y][x], blacks[bayer_chan(y, x, py, px)], ped)
             for x in range(len(cfa[0]))] for y in range(len(cfa))]


def wb_frame(cfa, py, px, gains, ped=0, data_w=12):
    return [[wb_px(cfa[y][x], gains[bayer_chan(y, x, py, px)], ped, data_w)
             for x in range(len(cfa[0]))] for y in range(len(cfa))]
